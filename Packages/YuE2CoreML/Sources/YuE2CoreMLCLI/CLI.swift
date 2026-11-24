#if os(macOS)
import Foundation
import YuE2CoreML

@main
struct CLI {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.count == 4, args[0] == "_worker" {
                try await WorkerCommand.run(assets: file(args[1]), work: file(args[2]), input: file(args[3]))
                return
            }
            guard args.count >= 4 else {
                throw YuE2Failure.request("Usage: yue2-coreml ASSETS LYRICS.TXT STYLE.TXT OUTPUT.WAV [--seed N] [--frames N] [--minimum-frames N] [--fast-acoustic | --streaming-acoustic] [--embedded | --metal | --metal-paired | --worker PATH]")
            }
            var seed: UInt64 = 20261122
            var frames: Int?
            var minimum = 200
            var acousticProfile: AcousticProfile?
            guard let executable = Bundle.main.executableURL else {
                throw YuE2Failure.worker("The executable path is unavailable.")
            }
            var execution: Execution = .isolated(worker: executable)
            var rest = args.dropFirst(4)[...]
            while let arg = rest.popFirst() {
                if arg == "--embedded" {
                    execution = .embedded
                    continue
                }
                if arg == "--metal" {
                    execution = .metal
                    continue
                }
                if arg == "--metal-paired" {
                    execution = .metalPaired
                    continue
                }
                if arg == "--fast-acoustic" {
                    acousticProfile = .fast
                    continue
                }
                if arg == "--streaming-acoustic" {
                    acousticProfile = .streaming
                    continue
                }
                guard let value = rest.popFirst() else { throw YuE2Failure.request("Missing value for \(arg).") }
                switch arg {
                case "--seed":
                    guard let n = UInt64(value) else { throw YuE2Failure.request("Invalid seed.") }
                    seed = n
                case "--frames":
                    guard let n = Int(value) else { throw YuE2Failure.request("Invalid frame limit.") }
                    frames = n
                case "--minimum-frames":
                    guard let n = Int(value) else { throw YuE2Failure.request("Invalid minimum frame count.") }
                    minimum = n
                case "--worker":
                    execution = .isolated(worker: file(value))
                default:
                    throw YuE2Failure.request("Unknown option \(arg).")
                }
            }
            let renderer = try YuE2Renderer(assets: file(args[0]), execution: execution)
            if acousticProfile == .streaming && !renderer.supportsStreamingAcoustics {
                throw YuE2Failure.request("Streaming acoustics requires the Metal decoder and the 512-frame acoustic graph.")
            }
            let request = SongRequest(lyrics: try String(contentsOf: file(args[1]), encoding: .utf8),
                                      style: try String(contentsOf: file(args[2]), encoding: .utf8),
                                      seed: seed, maximumFrames: frames, minimumFrames: minimum,
                                      acousticProfile: acousticProfile)
            let preview: (@Sendable (SongAudioPreview) -> Void)?
            if acousticProfile == .streaming {
                let started = ContinuousClock.now
                preview = { chunk in log("Audio frames \(chunk.startFrame)..<\(chunk.startFrame + chunk.samples.count / 2) at \(started.duration(to: .now))") }
            } else { preview = nil }
            let song = try await renderer.render(request, to: file(args[3]), onPreview: preview) { progress in
                switch progress {
                case .tokens(let count, let limit): log("Tokens \(count)/\(limit)")
                case .synthesis(let step, let total): log("Acoustic step \(step)/\(total)")
                case .waveform: log("Decoding waveform")
                case .workerRetry(let stage, let signal): log("Retrying stage \(stage) after signal \(signal)")
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var data = try encoder.encode(song)
            data.append(10)
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch {
            log(error.localizedDescription)
            exit(1)
        }
    }

    private static func file(_ string: String) -> URL { URL(fileURLWithPath: string).standardizedFileURL }
    private static func log(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
    }
}
#else
@main
struct CLI {
    static func main() {}
}
#endif
