import Foundation
import YuE2CoreML
#if DEBUG
import AVFoundation
#endif

/// Loads the indexed Metal bundle from the app or Application Support.
@MainActor
final class YuE2GenerationBackend: MusicGenerationBackend {
    private struct InstalledModel {
        let renderer: YuE2Renderer
        let directory: URL
    }
    private let metalModel: InstalledModel?
    private var pairedRenderer: YuE2Renderer?
    private var rendering = false
    var isAvailable: Bool { metalModel != nil }
    var canUsePairedMetal: Bool {
        guard let directory = metalModel?.directory else { return false }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("MetalPaired/manifest.json").path)
            && FileManager.default.fileExists(atPath: directory.appendingPathComponent("MetalPaired/weights.bin").path)
    }
    var canStreamAcoustics: Bool { metalModel?.renderer.supportsStreamingAcoustics == true }
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
        guard let model = metalModel else { throw MusicGenerationError.metalUnavailable }
        while rendering {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try Task.checkCancellation()
        rendering = true
        defer { rendering = false }
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
        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("VibePlayerSongs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let output = outputDirectory.appendingPathComponent("\(UUID().uuidString).wav")
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
        do {
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
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }
}

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
