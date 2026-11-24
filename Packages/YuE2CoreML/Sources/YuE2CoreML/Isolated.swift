#if os(macOS)
import Darwin
import Foundation

extension YuE2Renderer {
    func runIsolated(
        _ request: SongRequest, limit: Int, worker: URL, timeout: TimeInterval,
        work: URL, progress: @Sendable (SongProgress) -> Void
    ) async throws {
        guard worker.isFileURL, FileManager.default.isExecutableFile(atPath: worker.path),
              timeout.isFinite, (1...7200).contains(timeout) else {
            throw YuE2Failure.request("Provide an executable worker and a stage timeout between 1 and 7200 seconds.")
        }
        let capacities = Array(assets.manifest.decoderFrames.prefix(while: { $0 < limit }))
        guard let last = assets.manifest.decoderFrames.first(where: { $0 >= limit }) else {
            throw YuE2Failure.assets("The decoder ceiling is too small.")
        }
        let started = ContinuousClock.now
        for (index, capacity) in (capacities + [last]).enumerated() {
            let stage = Stage(request: request, limit: limit, capacity: capacity, index: index,
                              isAcoustic: false, referenceCache: assets.manifest.version == 3)
            try await invoke(stage, worker: worker, timeout: timeout, work: work, progress: progress)
            if FileManager.default.fileExists(atPath: work.appendingPathComponent("acoustic-input.json").path) {
                try writeRecord(WorkerTimings(tokenSeconds: started.duration(to: .now).seconds),
                                to: work.appendingPathComponent("timing.json"))
                let acoustic = Stage(request: request, limit: limit, capacity: capacity, index: index, isAcoustic: true)
                try await invoke(acoustic, worker: worker, timeout: timeout, work: work, progress: progress)
                return
            }
        }
        throw YuE2Failure.worker("The token stage did not produce a completed checkpoint.")
    }

    private func invoke(
        _ stage: Stage, worker: URL, timeout: TimeInterval, work: URL,
        progress: @Sendable (SongProgress) -> Void
    ) async throws {
        let file = work.appendingPathComponent("request.json")
        try writeRecord(stage, to: file)
        let meter = work.appendingPathComponent("progress.json")
        let log = work.appendingPathComponent("worker.log")
        for attempt in 0...1 {
            try Task.checkCancellation()
            try removeIfPresent(meter)
            if stage.isAcoustic {
                try removeIfPresent(work.appendingPathComponent("result.json"))
                try removeIfPresent(work.appendingPathComponent("song.wav"))
            } else {
                try removeIfPresent(work.appendingPathComponent("stage-\(stage.index)"))
                try removeIfPresent(work.appendingPathComponent("acoustic-input.json"))
            }
            try Data().write(to: log)
            let logFile = try FileHandle(forWritingTo: log)
            defer { try? logFile.close() }
            let process = Process()
            process.executableURL = worker
            process.arguments = ["_worker", assets.directory.path, work.path, file.path]
            process.standardOutput = logFile
            process.standardError = logFile
            do {
                try process.run()
            } catch {
                throw YuE2Failure.worker("Could not launch \(worker.lastPathComponent). \(error.localizedDescription)")
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
            var previous: SongProgress?
            do {
                while process.isRunning {
                    if let next = try? readRecord(SongProgress.self, at: meter), next != previous {
                        previous = next
                        progress(next)
                    }
                    if ContinuousClock.now >= deadline {
                        throw YuE2Failure.worker("Stage \(stage.index) exceeded its time limit.")
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch {
                if process.isRunning {
                    process.terminate()
                    for _ in 0..<10 where process.isRunning {
                        // The current task may already be cancelled.
                        _ = usleep(50_000)
                    }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    process.waitUntilExit()
                }
                throw error
            }
            if let next = try? readRecord(SongProgress.self, at: meter), next != previous { progress(next) }
            if process.terminationReason == .exit, process.terminationStatus == 0 {
                let expected = stage.isAcoustic ? "result.json" : "stage-\(stage.index)/checkpoint.json"
                guard FileManager.default.fileExists(atPath: work.appendingPathComponent(expected).path) else {
                    throw YuE2Failure.worker("Stage \(stage.index) exited without a checkpoint.")
                }
                return
            }
            if process.terminationReason == .uncaughtSignal, attempt == 0 {
                progress(.workerRetry(stage: stage.index, signal: process.terminationStatus))
                continue
            }
            let detail = (try? Data(contentsOf: log, options: .mappedIfSafe))
                .map { String(decoding: $0.suffix(4096), as: UTF8.self) } ?? ""
            let kind = stage.isAcoustic ? "Acoustic render" : "Decoder stage \(stage.index)"
            throw YuE2Failure.worker("\(kind) exited with status \(process.terminationStatus). \(detail)")
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

package enum WorkerCommand {
    package static func run(assets directory: URL, work: URL, input: URL) async throws {
        let assets = try ModelAssets(directory: directory)
        let stage = try readRecord(Stage.self, at: input)
        let meter = work.appendingPathComponent("progress.json")
        let progress: (SongProgress) -> Void = { value in try? writeRecord(value, to: meter) }
        if stage.isAcoustic {
            let result = try await Acoustic(assets: assets).render(stage.request, checkpointAt: work, progress: progress)
            try writeRecord(result, to: work.appendingPathComponent("result.json"))
        } else {
            try await Decoder(assets: assets).run(stage, in: work, progress: progress)
        }
    }
}
#endif
