import AVFoundation
import Foundation
import YuE2Kit

@main
enum Benchmark {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 4 else {
            print("Usage: yue2-bench LIBRARY WEIGHTS LYRICS OUTPUT [--spec FILE] [--style TEXT] [--seed N] [--guidance-scale N] [--play|--mute] [--full FRAMES|--preview] [--steps N]")
            return
        }
        let clock = ContinuousClock()
        let loadStart = clock.now
        let library = URL(fileURLWithPath: args[0])
        let weights = URL(fileURLWithPath: args[1], isDirectory: true)
        let lyrics = try String(contentsOfFile: args[2], encoding: .utf8)
        let output = URL(fileURLWithPath: args[3])
        let spec = try argument("--spec", in: args).map { URL(fileURLWithPath: $0) }
        let full = try argument("--full", in: args)
        let preview = args.contains("--preview")
        let steps = try argument("--steps", in: args) ?? (preview ? "4" : "8")
        let style = try argument("--style", in: args) ??
            "English, 126 BPM euphoric electro house, tight four-on-the-floor kick, clean punchy sub bass, crisp drums, bright arpeggiated synth, clear confident sung lead vocal, layered chorus harmonies, vocals enter early"
        let seed = try argument("--seed", in: args) ?? "20261122"
        let guidance = try argument("--guidance-scale", in: args) ?? "1.01"
        guard !(preview && full != nil), let stepCount = Int(steps),
              let frames = Int(full ?? "5000"), let seed = UInt64(seed),
              let guidanceScale = Float(guidance), guidanceScale.isFinite, guidanceScale >= 1 else {
            throw YuE2Error.invalidRequest
        }
        let engine = try await YuE2Engine.load(library: library, weights: weights, modelSpec: spec,
                                               mode: preview ? .streamingPreview : .fullSong)
        report("load", duration: loadStart.duration(to: clock.now))
        let prompt = YuE2Prompt(lyrics: lyrics, style: style, seed: seed, guidanceScale: guidanceScale)
        let sink = try AudioSink(output: output, playback: args.contains("--play") || args.contains("--mute"),
                                 muted: args.contains("--mute"))
        if preview {
            let cold = clock.now
            _ = try await engine.render(prompt, frames: 100, steps: stepCount)
            report("first render after load", duration: cold.duration(to: clock.now))
            try await engine.renderProgressively(prompt, steps: stepCount) { chunk in
                try await sink.receive(chunk)
            }
        } else {
            let start = clock.now
            let song = try await engine.render(prompt, frames: frames, steps: stepCount)
            try sink.receive(song)
            report("full render incl WAV (\(String(format: "%.3f", song.duration))s audio)",
                   duration: start.duration(to: clock.now))
        }
        try await sink.finishPlayback()
    }

    static func argument(_ name: String, in args: [String]) throws -> String? {
        guard let index = args.firstIndex(of: name) else { return nil }
        guard index + 1 < args.endIndex else { throw YuE2Error.invalidRequest }
        return args[index + 1]
    }

    static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    static func report(_ label: String, duration: Duration) {
        print(String(format: "%@: %.3fs", label, seconds(duration)))
    }
}

@MainActor
private final class AudioSink {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let file: AVAudioFile
    let clock = ContinuousClock()
    let start = ContinuousClock.now
    let playback: Bool
    let completions = AsyncStream<Void>.makeStream()
    var first: ContinuousClock.Instant?
    var queued = 0.0
    var buffersScheduled = 0

    init(output: URL, playback: Bool, muted: Bool) throws {
        self.playback = playback
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
        ]
        file = try AVAudioFile(forWriting: output, settings: settings)
        if playback {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
            player.volume = muted ? 0 : 1
            try engine.start()
        }
    }

    func receive(_ chunk: YuE2Audio) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(chunk.frameCount)),
              let channels = buffer.floatChannelData else { throw YuE2Error.invalidAudio }
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<chunk.frameCount {
            channels[0][frame] = chunk.samples[frame * 2]
            channels[1][frame] = chunk.samples[frame * 2 + 1]
        }
        try file.write(from: buffer)
        if playback {
            let continuation = completions.continuation
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                continuation.yield(())
            }
            buffersScheduled += 1
        }

        let now = clock.now
        if let first {
            let remaining = queued - Benchmark.seconds(first.duration(to: now))
            print(String(format: "next %.3fs at %.3fs, playback lead %.3fs", chunk.duration,
                         Benchmark.seconds(start.duration(to: now)), remaining))
        } else {
            first = now
            if playback { player.play() }
            print(String(format: "first %.3fs at %.3fs", chunk.duration, Benchmark.seconds(start.duration(to: now))))
        }
        queued += chunk.duration
    }

    func finishPlayback() async throws {
        guard playback else { return }
        defer {
            player.stop()
            engine.stop()
            completions.continuation.finish()
        }
        var completion = completions.stream.makeAsyncIterator()
        for _ in 0..<buffersScheduled {
            guard await completion.next() != nil else { break }
        }
        try Task.checkCancellation()
        print("Played all \(buffersScheduled) buffers.")
    }
}
