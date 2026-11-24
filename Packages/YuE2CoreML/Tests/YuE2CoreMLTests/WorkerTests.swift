#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import YuE2CoreML

@Test func workerRetriesSignalAndPreservesExistingOutputOnFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = Manifest(version: 1, promptCapacity: 32, decoderFrames: [128], acousticFrames: [128], conditioningBatch: nil, metalFrames: nil)
    try writeRecord(manifest, to: root.appendingPathComponent("manifest.json"))
    for name in ["Prefill", "Decoder128", "Acoustic128", "Waveform"] {
        let path = root.appendingPathComponent("\(name).mlmodelc")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        try Data([0]).write(to: path.appendingPathComponent("coremldata.bin"))
    }
    try Data().write(to: root.appendingPathComponent("tokenizer.tiktoken"))
    let embeddings = root.appendingPathComponent("embeddings.f16")
    try Data().write(to: embeddings)
    let file = try FileHandle(forWritingTo: embeddings)
    try file.truncate(atOffset: UInt64(TensorSpec.vocabulary * TensorSpec.hidden * 2))
    try file.close()

    let worker = root.appendingPathComponent("crashing-worker")
    try Data("#!/bin/sh\nkill -TERM $$\n".utf8).write(to: worker)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
    let output = root.appendingPathComponent("keep.wav")
    let existing = Data("existing render".utf8)
    try existing.write(to: output)
    let renderer = try YuE2Renderer(assets: root, execution: .isolated(worker: worker))
    let events = Mutex<[SongProgress]>([])
    let request = SongRequest(lyrics: "Test", style: "Pop", seed: 3, minimumFrames: 128)

    await #expect(throws: YuE2Failure.self) {
        try await renderer.render(request, to: output) { value in
            events.withLock { $0.append(value) }
        }
    }
    #expect(events.withLock { $0 } == [.workerRetry(stage: 0, signal: 15)])
    #expect(try Data(contentsOf: output) == existing)
}
#endif
