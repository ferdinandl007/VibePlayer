import CoreML
import Foundation

enum TensorSpec {
    static let layers = 28
    static let heads = 8
    static let headSize = 128
    static let hidden = 2048
    static let latent = 64
    static let vocabulary = 184704
    static let musicStart = 151851
    static let musicEnd = 151852
    static let codecOffset = 151853
    static let logits = 32769

    static func cache(batch: Int, frames: Int) -> [Int] {
        [layers, batch, heads, frames, headSize]
    }
}

func tensor(_ shape: [Int], filled value: Float16 = 0) throws -> MLMultiArray {
    let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float16)
    array.withUnsafeMutableBufferPointer(ofType: Float16.self) { data, _ in
        data.update(repeating: value)
    }
    return array
}

func intTensor(_ values: [Int]) throws -> MLMultiArray {
    let array = try MLMultiArray(shape: [NSNumber(value: values.count)], dataType: .int32)
    array.withUnsafeMutableBufferPointer(ofType: Int32.self) { data, _ in
        for (index, value) in values.enumerated() { data[index] = Int32(value) }
    }
    return array
}

func requireTensor(_ features: any MLFeatureProvider, _ key: String, shape: [Int]) throws -> MLMultiArray {
    guard let array = features.featureValue(for: key)?.multiArrayValue,
          array.shape.map(\.intValue) == shape, array.dataType == .float16 else {
        throw YuE2Failure.inference("Unexpected shape or precision for \(key).")
    }
    return array
}

func provider(_ inputs: [String: MLMultiArray]) throws -> MLDictionaryFeatureProvider {
    try MLDictionaryFeatureProvider(dictionary: inputs.mapValues { MLFeatureValue(multiArray: $0) })
}

func rope(_ positions: [[Int]]) throws -> (MLMultiArray, MLMultiArray) {
    let columns = positions[0].count
    let shape = [positions.count, 1, columns, 64]
    let frequencies = (0 ..< 64).map { powf(1_000_000, -Float($0) / 64) }
    let sine = try tensor(shape)
    let cosine = try tensor(shape)
    sine.withUnsafeMutableBufferPointer(ofType: Float16.self) { s, ss in
        cosine.withUnsafeMutableBufferPointer(ofType: Float16.self) { c, cs in
            for (b, row) in positions.enumerated() {
                for (t, pos) in row.enumerated() {
                    for i in 0 ..< 64 {
                        let phase = Float(pos) * frequencies[i]
                        s[b * ss[0] + t * ss[2] + i * ss[3]] = Float16(sinf(phase))
                        c[b * cs[0] + t * cs[2] + i * cs[3]] = Float16(cosf(phase))
                    }
                }
            }
        }
    }
    return (sine, cosine)
}

struct Embeddings {
    let bytes: Data

    init(_ url: URL) throws { bytes = try Data(contentsOf: url, options: .alwaysMapped) }

    func fill(_ array: MLMultiArray, with rows: [[Int]]) throws {
        guard rows.flatMap({ $0 }).allSatisfy({ (0..<TensorSpec.vocabulary).contains($0) }) else {
            throw YuE2Failure.inference("A token is outside the embedding table.")
        }
        bytes.withUnsafeBytes { raw in
            array.withUnsafeMutableBufferPointer(ofType: Float16.self) { output, stride in
                for (b, row) in rows.enumerated() {
                    for (t, token) in row.enumerated() {
                        let offset = b * stride[0] + t * stride[1]
                        if stride[2] == 1, let src = raw.baseAddress, let dst = output.baseAddress {
                            memcpy(dst + offset, src + token * TensorSpec.hidden * 2, TensorSpec.hidden * 2)
                        } else {
                            for d in 0 ..< TensorSpec.hidden {
                                output[offset + d * stride[2]] = Float16(bitPattern:
                                    raw.loadUnaligned(fromByteOffset: (token * TensorSpec.hidden + d) * 2, as: UInt16.self))
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Copies active rows between FP16 cache views with independent strides and capacities.
func copyCache(_ source: MLMultiArray, to target: MLMultiArray, lengths: [Int],
               sourceStart: Int = 0, targetStart: Int = 0) throws {
    let srcShape = source.shape.map(\.intValue)
    let dstShape = target.shape.map(\.intValue)
    let from = source.strides.map(\.intValue)
    guard srcShape.count == 5, dstShape.count == 5, from.count == 5, !lengths.isEmpty,
          source.dataType == .float16, target.dataType == .float16,
          srcShape[0] == dstShape[0], srcShape[2] == dstShape[2], srcShape[4] == dstShape[4],
          lengths.count <= min(srcShape[1], dstShape[1]), sourceStart >= 0, targetStart >= 0,
          lengths.allSatisfy({ $0 >= 0 && $0 <= min(srcShape[3] - sourceStart, dstShape[3] - targetStart) }) else {
        throw YuE2Failure.inference("Invalid active cache shape.")
    }
    source.withUnsafeBufferPointer(ofType: Float16.self) { src in
        target.withUnsafeMutableBufferPointer(ofType: Float16.self) { dst, to in
            for l in 0..<dstShape[0] {
                for b in lengths.indices where lengths[b] > 0 {
                    for h in 0..<dstShape[2] {
                        let s = l * from[0] + b * from[1] + h * from[2] + sourceStart * from[3]
                        let d = l * to[0] + b * to[1] + h * to[2] + targetStart * to[3]
                        if from[4] == 1, to[4] == 1, from[3] == srcShape[4], to[3] == dstShape[4],
                           let a = src.baseAddress, let z = dst.baseAddress {
                            (z + d).update(from: a + s, count: lengths[b] * dstShape[4])
                        } else {
                            for t in 0..<lengths[b] {
                                for i in 0..<dstShape[4] {
                                    dst[d + t * to[3] + i * to[4]] = src[s + t * from[3] + i * from[4]]
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

func readTensor(_ url: URL, shape: [Int]) throws -> MLMultiArray {
    let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
    guard bytes.count == shape.reduce(1, *) * 2 else {
        throw YuE2Failure.inference("Incomplete tensor checkpoint \(url.lastPathComponent).")
    }
    let array = try tensor(shape)
    array.withUnsafeMutableBufferPointer(ofType: Float16.self) { buffer, _ in
        _ = bytes.copyBytes(to: UnsafeMutableRawBufferPointer(buffer))
    }
    return array
}

func writeTensor(_ array: MLMultiArray, to url: URL) throws {
    try array.withUnsafeBufferPointer(ofType: Float16.self) { buffer in
        try Data(UnsafeRawBufferPointer(buffer)).write(to: url, options: .atomic)
    }
}
