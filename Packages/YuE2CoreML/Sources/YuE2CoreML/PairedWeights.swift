import CryptoKit
import Foundation

struct PairedWeights: Decodable {
    let version: Int
    let sourceSHA256: String
    let indexSHA256: String
    let packedSHA256: String

    // Validate once when the host opens its renderer. Stream the large files so
    // validation does not add an entire set of weights to the working set.
    static func verifiedFile(in directory: URL) throws -> URL {
        let sidecar = directory.appendingPathComponent("MetalPaired")
        let file = sidecar.appendingPathComponent("weights.bin")
        guard let manifest = try? readRecord(Self.self, at: sidecar.appendingPathComponent("manifest.json")),
              manifest.version == 1 else {
            throw YuE2Failure.assets("Prepare this bundle with Scripts/prepare_paired.py before using paired Metal.")
        }
        guard try digest(directory.appendingPathComponent("metal-decoder.json")) == manifest.indexSHA256,
              try digest(directory.appendingPathComponent("Autoregressive.mlmodelc/weights/weight.bin")) == manifest.sourceSHA256,
              try digest(file) == manifest.packedSHA256 else {
            throw YuE2Failure.assets("Paired Metal weights do not match this indexed model bundle.")
        }
        return file
    }

    private static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
