#if os(macOS)
import CAudioBridge
import Foundation

public struct YuE2Prompt: Sendable {
    public let lyrics: String
    public let style: String
    public let seed: UInt64

    public init(lyrics: String, style: String, seed: UInt64) {
        self.lyrics = lyrics
        self.style = style
        self.seed = seed
    }
}

public struct YuE2Audio: Sendable {
    /// Interleaved Float32 PCM.
    public let samples: [Float]
    public let sampleRate: Int
    public let channels: Int

    public var frameCount: Int { samples.count / channels }
    public var duration: Double { Double(frameCount) / Double(sampleRate) }
}

public enum YuE2Error: LocalizedError {
    case native(String)
    case invalidRequest
    case invalidAudio
    case invalidContinuation
    case busy

    public var errorDescription: String? {
        switch self {
        case .native(let detail): detail
        case .invalidRequest: "Provide a style, a valid seed, and increasing positive frame counts."
        case .invalidAudio: "YuE2 returned an unexpected audio format or duration."
        case .invalidContinuation: "YuE2 returned an invalid semantic token continuation."
        case .busy: "This YuE2 session is already generating audio."
        }
    }
}

/// Owns one loaded Metal session. Reuse it for the life of the generation UI.
public actor YuE2Engine {
    public enum SynthesisMode: Sendable {
        case fullSong
        case streamingPreview
    }

    /// Model outputs one semantic frame per 40 ms.
    public static let framesPerSecond = 25
    public static let previewCheckpoints = [75, 150, 275, 475, 775]
    public static let windowedPreviewCheckpoints = [100, 184, 352, 520, 772]

    private final class Session {
        let handle: OpaquePointer

        init(_ handle: OpaquePointer) { self.handle = handle }
        deinit { yu_close(handle) }
    }

    private struct Render {
        let audio: YuE2Audio
        let tokens: [Int]
    }

    private let session: Session
    private let mode: SynthesisMode
    private var generating = false

    @concurrent
    public static func load(library: URL, weights: URL, modelSpec: URL? = nil,
                            mode: SynthesisMode = .fullSong) async throws -> YuE2Engine {
        try Task.checkCancellation()
        return try YuE2Engine(library: library, weights: weights, modelSpec: modelSpec, mode: mode)
    }

    private init(library: URL, weights: URL, modelSpec: URL?, mode: SynthesisMode) throws {
        let preview: Int32 = mode == .streamingPreview ? 1 : 0
        let handle = library.path.withCString { libraryPath in
            weights.path.withCString { weightsPath in
                if let modelSpec {
                    return modelSpec.path.withCString { yu_open(libraryPath, weightsPath, $0, preview) }
                }
                return yu_open(libraryPath, weightsPath, nil, preview)
            }
        }
        guard let handle else { throw YuE2Error.native(String(cString: yu_error())) }
        session = Session(handle)
        self.mode = mode
    }

    /// Render a single take and let the model end it within the frame budget.
    public func render(_ prompt: YuE2Prompt, frames: Int, steps: Int = 8, minimumFrames: Int? = nil) throws -> YuE2Audio {
        guard !generating else { throw YuE2Error.busy }
        try validate(prompt, checkpoints: [frames], steps: steps)
        if let minimumFrames, !(25...frames).contains(minimumFrames) { throw YuE2Error.invalidRequest }
        let result = try render(prompt, frames: frames, steps: steps,
                                minimumFrames: mode == .streamingPreview ? frames : minimumFrames, prefix: [])
        guard result.tokens.count == frames else { return result.audio }
        return Self.fadeEnd(result.audio)
    }

    /// Delivers contiguous PCM as successive renders complete. Enqueue each chunk promptly.
    /// Stopping the task cancels before the next native render or delivery.
    public func renderProgressively(
        _ prompt: YuE2Prompt,
        checkpoints: [Int]? = nil,
        steps: Int = 4,
        minimumFrames: Int? = nil,
        onAudio: @Sendable (YuE2Audio) async throws -> Void
    ) async throws {
        guard !generating else { throw YuE2Error.busy }
        let windowed = mode == .streamingPreview
        let checkpoints = checkpoints ?? (windowed ? Self.windowedPreviewCheckpoints : Self.previewCheckpoints)
        try validate(prompt, checkpoints: checkpoints, steps: steps)
        if let minimumFrames, let last = checkpoints.last, !(25...last).contains(minimumFrames) {
            throw YuE2Error.invalidRequest
        }
        if windowed {
            let window = Int(YU_PREVIEW_WINDOW_FRAMES)
            let stride = window - Int(YU_PREVIEW_OVERLAP_FRAMES)
            guard checkpoints.allSatisfy({ $0 >= window && ($0 - window).isMultiple(of: stride) }) else {
                throw YuE2Error.invalidRequest
            }
        }
        generating = true
        defer { generating = false }

        var previous: Render?
        for (index, frames) in checkpoints.enumerated() {
            let minimum = minimumFrames.map { min(frames, max($0, (previous?.tokens.count ?? 0) + 25)) } ?? frames
            let current = try render(prompt, frames: frames, steps: steps,
                                     minimumFrames: minimum, prefix: previous?.tokens ?? [])
            let overlap = Int(Double(current.audio.sampleRate) * 0.22)
            // A future acoustic window changes the overlap at the end of the current render.
            let holdback = windowed ? current.audio.sampleRate : overlap
            let ended = current.tokens.count < frames
            let final = ended || index == checkpoints.count - 1
            let chunk = try Self.splice(previous: previous?.audio, current: current.audio,
                                       holdback: holdback, overlap: overlap, final: final)
            try Task.checkCancellation()
            try await onAudio(final && !ended ? Self.fadeEnd(chunk) : chunk)
            if final { return }
            previous = current
        }
    }

    private func validate(_ prompt: YuE2Prompt, checkpoints: [Int], steps: Int) throws {
        guard !prompt.style.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.seed <= UInt64(Int64.max),
              !checkpoints.isEmpty, checkpoints.allSatisfy({ (25...15_000).contains($0) }),
              zip(checkpoints, checkpoints.dropFirst()).allSatisfy({ $1 - $0 >= 25 }),
              (1...64).contains(steps) else { throw YuE2Error.invalidRequest }
    }

    private func render(_ prompt: YuE2Prompt, frames: Int, steps: Int,
                        minimumFrames: Int?, prefix: [Int]) throws -> Render {
        try Task.checkCancellation()
        let encoded = prefix.isEmpty ? nil : String(decoding: try JSONEncoder().encode(prefix), as: UTF8.self)
        let minimum = Int32(minimumFrames ?? 0)
        let result = prompt.lyrics.withCString { lyrics in
            prompt.style.withCString { style in
                if let encoded {
                    return encoded.withCString {
                        yu_render(session.handle, lyrics, style, prompt.seed, Int32(frames), Int32(steps), minimum, $0)
                    }
                }
                return yu_render(session.handle, lyrics, style, prompt.seed, Int32(frames), Int32(steps), minimum, nil)
            }
        }
        guard let result else { throw YuE2Error.native(String(cString: yu_error())) }
        defer { yu_result_close(result) }
        try Task.checkCancellation()

        let sampleRate = Int(yu_sample_rate(result))
        let channels = Int(yu_channels(result))
        let frameCount = yu_frames(result)
        guard sampleRate == 48_000, channels == 2, frameCount > 0,
              frameCount <= frames * 1_920, let samples = yu_samples(result) else {
            throw YuE2Error.invalidAudio
        }
        var size = 0
        guard let tokenJSON = yu_tokens(result, &size), size > 0,
              let tokens = try? JSONDecoder().decode([Int].self, from: Data(bytes: tokenJSON, count: size)),
              tokens.count >= (minimumFrames ?? 1), tokens.count <= frames,
              tokens.starts(with: prefix) else {
            throw YuE2Error.invalidContinuation
        }
        let audio = YuE2Audio(samples: Array(UnsafeBufferPointer(start: samples, count: frameCount * channels)),
                              sampleRate: sampleRate, channels: channels)
        return Render(audio: audio, tokens: tokens)
    }

    private static func fadeEnd(_ audio: YuE2Audio) -> YuE2Audio {
        let fadeFrames = min(audio.sampleRate * 3 / 2, audio.frameCount / 2)
        guard fadeFrames > 1 else { return audio }
        var samples = audio.samples
        let start = audio.frameCount - fadeFrames
        for frame in start..<audio.frameCount {
            let phase = Float(frame - start) / Float(fadeFrames - 1)
            let gain = 0.5 + 0.5 * cos(.pi * phase)
            for channel in 0..<audio.channels { samples[frame * audio.channels + channel] *= gain }
        }
        return YuE2Audio(samples: samples, sampleRate: audio.sampleRate, channels: audio.channels)
    }

    private static func splice(previous: YuE2Audio?, current: YuE2Audio, holdback: Int,
                               overlap: Int, final: Bool) throws -> YuE2Audio {
        let end = current.frameCount - (final ? 0 : holdback)
        let start = (previous?.frameCount ?? holdback) - holdback
        guard start >= 0, end > start, previous.map({ $0.frameCount <= end }) ?? true else {
            throw YuE2Error.invalidAudio
        }
        let channels = current.channels
        var pcm = Array(current.samples[(start * channels)..<(end * channels)])
        if let previous {
            for frame in 0..<overlap {
                let phase = Float(frame) / Float(overlap - 1)
                let fade = 0.5 - 0.5 * cos(.pi * phase)
                for channel in 0..<channels {
                    let index = frame * channels + channel
                    let prior = previous.samples[start * channels + index]
                    pcm[index] = prior + (pcm[index] - prior) * fade
                }
            }
        } else {
            // Short NAR renders can begin mid-waveform. Ramp from silence without shifting time.
            let fadeFrames = min(end, current.sampleRate / 40)
            for frame in 0..<fadeFrames {
                let phase = Float(frame) / Float(fadeFrames - 1)
                let gain = 0.5 - 0.5 * cos(.pi * phase)
                for channel in 0..<channels { pcm[frame * channels + channel] *= gain }
            }
        }
        return YuE2Audio(samples: pcm, sampleRate: current.sampleRate, channels: channels)
    }
}
#endif
