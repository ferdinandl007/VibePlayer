import Foundation
import YuE2CoreML
#if DEBUG || os(macOS)
import AVFoundation
#endif
#if os(macOS)
import YuE2Kit
#endif

/// Loads the indexed Metal bundle from the app or Application Support.
@MainActor
final class YuE2GenerationBackend: MusicGenerationBackend {
    private struct InstalledModel {
        let renderer: YuE2Renderer
        let directory: URL
    }
    private let metalModel: InstalledModel?
    #if os(macOS)
    private let native = MacYuE2Renderer()
    #endif
    private var pairedRenderer: YuE2Renderer?
    private var rendering = false
    var isAvailable: Bool {
        #if os(macOS)
        if native != nil { return true }
        #endif
        return metalModel != nil
    }
    var canUsePairedMetal: Bool {
        guard let directory = metalModel?.directory else { return false }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("MetalPaired/manifest.json").path)
            && FileManager.default.fileExists(atPath: directory.appendingPathComponent("MetalPaired/weights.bin").path)
    }
    var canStreamAcoustics: Bool {
        #if os(macOS)
        if native != nil { return true }
        #endif
        return metalModel?.renderer.supportsStreamingAcoustics == true
    }
    var canCreateExtended: Bool { (metalModel?.renderer.maximumFrames ?? 0) >= CreateLength.extended.maximumFrames }

    func promptUsage(for request: MusicGenerationRequest) async throws -> MusicPromptUsage? {
        guard let renderer = metalModel?.renderer else { return nil }
        let usage = try await renderer.promptUsage(style: request.style, lyrics: request.lyrics)
        return MusicPromptUsage(count: usage.count, limit: usage.limit,
                                styleTokens: usage.styleTokens, lyricTokens: usage.lyricTokens)
    }

    func waitForIdle() async throws {
        while rendering { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation()
    }

    func prepareEarlyPlayback() {
        #if os(macOS)
        if !rendering { native?.preparePreview() }
        #endif
    }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first

        for root in [Bundle.main.resourceURL, support].compactMap({ $0 }) {
            let directory = root.appendingPathComponent("YuE2MetalAssets", isDirectory: true)
            guard let renderer = try? YuE2Renderer(assets: directory, execution: .metal) else { continue }
            metalModel = InstalledModel(renderer: renderer, directory: directory)
            return
        }
        metalModel = nil
    }

    func generate(_ request: MusicGenerationRequest, onPreview: (@Sendable (MusicAudioPreview) -> Void)?,
                  onProgress: @escaping @Sendable (MusicGenerationProgress) -> Void) async throws -> URL {
        guard isAvailable else { throw MusicGenerationError.metalUnavailable }
        while rendering {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try Task.checkCancellation()
        rendering = true
        defer { rendering = false }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VibePlayerSongs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("\(UUID().uuidString).wav")
        do {
            #if os(macOS)
            await native?.finishPreparing()
            let usesNative = request.purpose == .radio || request.createAcoustics == .streaming || metalModel == nil
            if usesNative, let native, request.createRenderer != .metalPaired {
                try await native.render(request, to: output, onPreview: onPreview, onProgress: onProgress)
                return output
            }
            #endif
            try await renderCoreML(request, to: output, onPreview: onPreview, onProgress: onProgress)
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private func renderCoreML(_ request: MusicGenerationRequest, to output: URL,
                              onPreview: (@Sendable (MusicAudioPreview) -> Void)?,
                              onProgress: @escaping @Sendable (MusicGenerationProgress) -> Void) async throws {
        guard let model = metalModel else { throw MusicGenerationError.metalUnavailable }
        let renderer: YuE2Renderer
        if request.purpose == .createdSong, request.createRenderer == .metalPaired {
            if let pairedRenderer { renderer = pairedRenderer }
            else {
                let directory = model.directory
                // Validate the large sidecar away from the UI and only when the user selects it.
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try YuE2Renderer(assets: directory, execution: .metalPaired)
                }.value
                try Task.checkCancellation()
                pairedRenderer = prepared
                renderer = prepared
            }
        } else { renderer = model.renderer }
        #if os(iOS)
        // Use the full-context acoustic graph exercised on the phone. The larger GPU
        // graph can fail during heap allocation before Core ML returns an error.
        let maxFrames = min(request.maxSemanticFrames, renderer.maximumFrames, 4_200)
        #else
        let maxFrames = min(request.maxSemanticFrames, renderer.maximumFrames)
        #endif
        let radio = request.purpose == .radio
        guard radio || request.minimumSemanticFrames <= maxFrames else { throw MusicGenerationError.extendedUnavailable }
        let minimum = radio ? min(request.minimumSemanticFrames, maxFrames) : request.minimumSemanticFrames
        let profile: AcousticProfile = switch request.createAcoustics {
        case .streaming: .streaming
        case .reference: radio && renderer.supportsFastAcoustics ? .fast : .reference
        }
        let song = SongRequest(lyrics: request.lyrics, style: request.style, seed: request.seed,
                               maximumFrames: maxFrames, minimumFrames: minimum,
                               acousticProfile: profile)
        let preview: (@Sendable (SongAudioPreview) -> Void)?
        if let onPreview {
            preview = { audio in onPreview(MusicAudioPreview(samples: audio.samples, totalFrames: audio.totalFrames, startFrame: audio.startFrame)) }
        } else { preview = nil }
        _ = try await renderer.render(song, to: output, streamAudio: preview != nil, onPreview: preview) { progress in
            switch progress {
            case .tokens(let count, let limit): onProgress(.tokens(count, limit))
            case .synthesis(let step, let total): onProgress(.synthesis(step, total))
            case .waveform: onProgress(.waveform)
            case .workerRetry: break
            }
        }
    }
}

#if os(macOS)
@MainActor
private final class MacYuE2Renderer {
    private let library: URL
    private let weights: URL
    private let spec: URL
    private var resident: (mode: YuE2Engine.SynthesisMode, engine: YuE2Engine)?
    private var preparation: Task<YuE2Engine, Error>?

    init?() {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let root = support.appendingPathComponent("YuE2NativeAssets", isDirectory: true)
        library = root.appendingPathComponent("libaudiocpp.dylib")
        weights = root.appendingPathComponent("weights", isDirectory: true)
        spec = root.appendingPathComponent("yue2.json")
        let files = [library, spec] + ["yue2-3b-q4_0.gguf", "yue2-vae-f16.gguf", "sidecars/yue2-qwen.tiktoken",
            "sidecars/yue2-vae-config.json", "sidecars/yue2-model-config.json", "sidecars/yue2-generation-config.json"
        ].map { weights.appendingPathComponent($0) }
        guard files.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.path) }) else { return nil }
    }

    func preparePreview() {
        guard resident?.mode != .streamingPreview, preparation == nil else { return }
        resident = nil
        preparation = Task { [library, weights, spec] in
            let engine = try await YuE2Engine.load(library: library, weights: weights, modelSpec: spec, mode: .streamingPreview)
            let warmup = YuE2Prompt(lyrics: "", style: "instrumental, warm piano", seed: 1)
            _ = try await engine.render(warmup, frames: 100, steps: 4)
            return engine
        }
    }

    func finishPreparing() async {
        guard let preparation else { return }
        if let engine = try? await preparation.value { resident = (.streamingPreview, engine) }
        self.preparation = nil
    }

    func render(_ request: MusicGenerationRequest, to output: URL,
                onPreview: (@Sendable (MusicAudioPreview) -> Void)?,
                onProgress: @escaping @Sendable (MusicGenerationProgress) -> Void) async throws {
        try Task.checkCancellation()
        let preview = request.purpose == .createdSong && request.createAcoustics == .streaming
        let mode: YuE2Engine.SynthesisMode = preview ? .streamingPreview : .fullSong
        if resident?.mode != mode {
            resident = nil
            let engine = try await YuE2Engine.load(library: library, weights: weights, modelSpec: spec, mode: mode)
            resident = (mode, engine)
        }
        guard let engine = resident?.engine else { throw MusicGenerationError.metalUnavailable }
        let prompt = YuE2Prompt(lyrics: request.lyrics, style: request.style, seed: request.seed)
        let file = try NativeSongFile(url: output)
        if preview, let onPreview {
            let first = YuE2Engine.windowedPreviewCheckpoints[0]
            let stride = YuE2Engine.windowedPreviewCheckpoints[1] - first
            guard request.maxSemanticFrames >= first else { throw YuE2Error.invalidRequest }
            let end = first + (request.maxSemanticFrames - first) / stride * stride
            let checkpoints = (YuE2Engine.windowedPreviewCheckpoints + [1192, 1780, 2536, 3712]).filter { $0 < end } + [end]
            onProgress(.tokens(0, end))
            let minimum = min(end, max(request.minimumSemanticFrames, 1750))
            try await engine.renderProgressively(prompt, checkpoints: checkpoints, steps: 4, minimumFrames: minimum) { audio in
                let chunk = try await file.append(audio, totalFrames: end * 1_920)
                onPreview(chunk)
                onProgress(.tokens((chunk.startFrame + audio.frameCount) / 1_920, end))
            }
        } else {
            onProgress(.tokens(0, request.maxSemanticFrames))
            let audio = try await engine.render(prompt, frames: request.maxSemanticFrames,
                                                steps: preview ? 4 : request.synthesisSteps,
                                                minimumFrames: request.minimumSemanticFrames)
            _ = try await file.append(audio, totalFrames: audio.frameCount)
        }
        onProgress(.waveform)
    }
}

private actor NativeSongFile {
    private let file: AVAudioFile
    private var position = 0

    init(url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true) else {
            throw YuE2Error.invalidAudio
        }
        file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
    }

    func append(_ audio: YuE2Audio, totalFrames: Int) throws -> MusicAudioPreview {
        let frames = audio.frameCount
        guard audio.sampleRate == 48_000, audio.channels == 2, frames > 0,
              audio.samples.count == frames * 2, frames <= totalFrames - position,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)),
              let output = buffer.int16ChannelData?[0] else { throw YuE2Error.invalidAudio }
        buffer.frameLength = AVAudioFrameCount(frames)
        for (index, value) in audio.samples.enumerated() {
            guard value.isFinite else { throw YuE2Error.invalidAudio }
            output[index] = Int16(clamping: Int((min(1, max(-1, value)) * 32768).rounded()))
        }
        try file.write(from: buffer)
        let samples = Array(UnsafeBufferPointer(start: output, count: audio.samples.count))
        let chunk = MusicAudioPreview(samples: samples, totalFrames: totalFrames, startFrame: position, lowLatency: true)
        position += frames
        return chunk
    }
}
#endif

#if DEBUG
/// Supplies a short fixture for UI tests; it is never selected in normal launches.
@MainActor
final class FixtureMusicGenerationBackend: MusicGenerationBackend {
    let isAvailable = true
    let canStreamAcoustics = true
    func generate(_ request: MusicGenerationRequest, onPreview: (@Sendable (MusicAudioPreview) -> Void)?,
                  onProgress: @escaping @Sendable (MusicGenerationProgress) -> Void) async throws -> URL {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString).wav")
        let arguments = ProcessInfo.processInfo.arguments
        if request.purpose == .createdSong, request.createAcoustics == .reference,
           arguments.contains("--fixture-full-context-audio"), let onPreview {
            onProgress(.synthesis(1, 8))
            try await Task.sleep(for: .seconds(5))
            let samples = tone(frames: 48_000 * 18)
            onProgress(.waveform)
            onPreview(MusicAudioPreview(samples: Array(samples.prefix(48_000 * 9 * 2)), totalFrames: samples.count / 2))
            try await Task.sleep(for: .seconds(5))
            try writeFixture(samples, to: output)
            return output
        }
        if request.purpose == .createdSong, arguments.contains("--fixture-early-audio"), let onPreview {
            try await Task.sleep(for: .milliseconds(350))
            let samples = tone(frames: 48_000 * 40)
            onProgress(.waveform)
            let opening = 48_000 * 28
            let middle = 48_000 * 34
            onPreview(MusicAudioPreview(samples: Array(samples.prefix(opening * 2)), totalFrames: samples.count / 2))
            try await Task.sleep(for: .seconds(2))
            onPreview(MusicAudioPreview(samples: Array(samples[(opening * 2)..<(middle * 2)]),
                                        totalFrames: samples.count / 2, startFrame: opening))
            try await Task.sleep(for: .seconds(12))
            try writeFixture(samples, to: output)
            return output
        }
        if request.purpose == .radio, arguments.contains("--fixture-radio-gap") {
            onProgress(.tokens(40, 512))
            try await Task.sleep(for: .seconds(3))
            try writeFixture(tone(frames: 48_000 * 2), to: output)
            return output
        }
        try await Task.sleep(for: .milliseconds(500))
        guard let source = Bundle.main.url(forResource: "atmosphere", withExtension: "wav") else { throw MusicGenerationError.unavailable }
        try FileManager.default.copyItem(at: source, to: output)
        return output
    }

    private func tone(frames: Int) -> [Int16] {
        var samples = [Int16](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let gain = min(1, Double(frame) / 480, Double(frames - frame - 1) / 480)
            let sample = Int16(sin(2 * .pi * 220 * Double(frame) / 48_000) * 200 * gain)
            samples[frame * 2] = sample
            samples[frame * 2 + 1] = sample
        }
        return samples
    }

    private func writeFixture(_ samples: [Int16], to url: URL) throws {
        let frames = AVAudioFrameCount(samples.count / 2)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.int16ChannelData?[0] else { throw MusicGenerationError.unavailable }
        buffer.frameLength = frames
        for index in samples.indices { channel[index] = samples[index] }
        let fixture = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try fixture.write(from: buffer)
    }
}
#endif
