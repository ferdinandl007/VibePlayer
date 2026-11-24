import CoreML
import Foundation

enum CacheComponent: String, CaseIterable {
    case keys, values
}

enum DecoderCache {
    case stateful(MLState, frames: Int)
    case growable(GrowableCache)
    case metal(MetalDecoder)

    var frames: Int {
        switch self {
        case .stateful(_, let frames): frames
        case .growable(let cache): cache.frames
        case .metal(let decoder): decoder.frames
        }
    }

    func reserve(for positions: [Int]) throws -> Bool {
        guard case .growable(let cache) = self else { return false }
        return try cache.reserve(for: positions)
    }

    func withArray(_ component: CacheComponent, _ body: (MLMultiArray) throws -> Void) throws {
        switch self {
        case .stateful(let state, _):
            try state.withMultiArray(for: component.rawValue, body)
        case .growable(let cache):
            try body(cache[component])
        case .metal(let decoder):
            try decoder.withArray(component, body)
        }
    }

    func predict(
        _ model: MLModel?, embedding: MLMultiArray, sine: MLMultiArray, cosine: MLMultiArray,
        mask: MLMultiArray, positions: [Int]
    ) async throws -> any MLFeatureProvider {
        var inputs = ["embedding": embedding, "sine": sine, "cosine": cosine, "mask": mask]
        switch self {
        case .stateful(let state, _):
            guard let model else { throw YuE2Failure.inference("Missing stateful decoder graph.") }
            inputs["positions"] = try intTensor(positions)
            return try await model.prediction(from: provider(inputs), using: state)
        case .growable(let cache):
            guard let model else { throw YuE2Failure.inference("Missing growable decoder graph.") }
            for component in CacheComponent.allCases {
                inputs[component.rawValue] = cache[component]
            }
            let result = try await model.prediction(from: provider(inputs))
            for component in CacheComponent.allCases {
                let frame = try requireTensor(result, "current_\(component.rawValue)",
                                              shape: TensorSpec.cache(batch: 2, frames: 1))
                cache.store(frame, at: positions, component: component)
            }
            return result
        case .metal(let decoder):
            return try autoreleasepool {
                try decoder.predict(embedding: embedding, sine: sine, cosine: cosine, positions: positions)
            }
        }
    }
}

final class GrowableCache {
    private let ceiling: Int
    private var keys: MLMultiArray
    private var values: MLMultiArray
    private(set) var frames: Int

    init(ceiling: Int, filled: Int) throws {
        self.ceiling = ceiling
        frames = try Self.capacity(for: filled, ceiling: ceiling)
        let shape = TensorSpec.cache(batch: 2, frames: frames)
        keys = try tensor(shape)
        values = try tensor(shape)
    }

    subscript(_ component: CacheComponent) -> MLMultiArray {
        switch component {
        case .keys: keys
        case .values: values
        }
    }

    func reserve(for positions: [Int]) throws -> Bool {
        let required = (positions.max() ?? 0) + 1
        guard required > frames else { return false }
        let capacity = try Self.capacity(for: required, ceiling: ceiling)
        let shape = TensorSpec.cache(batch: 2, frames: capacity)
        // Replace each buffer after packing its active rows to limit the growth peak.
        do {
            let expanded = try tensor(shape)
            try copyCache(keys, to: expanded, lengths: positions)
            keys = expanded
        }
        do {
            let expanded = try tensor(shape)
            try copyCache(values, to: expanded, lengths: positions)
            values = expanded
        }
        frames = capacity
        return true
    }

    private static func capacity(for required: Int, ceiling: Int) throws -> Int {
        guard required > 0, required <= ceiling else {
            throw YuE2Failure.inference("The decoder cache capacity was exceeded.")
        }
        let block = 128
        return min(ceiling, (required + block - 1) / block * block)
    }

    func store(_ frame: MLMultiArray, at positions: [Int], component: CacheComponent) {
        let read = frame.strides.map(\.intValue)
        self[component].withUnsafeMutableBufferPointer(ofType: Float16.self) { dest, write in
            frame.withUnsafeBufferPointer(ofType: Float16.self) { source in
                for layer in 0..<TensorSpec.layers {
                    for batch in positions.indices {
                        for head in 0..<TensorSpec.heads {
                            let from = layer * read[0] + batch * read[1] + head * read[2]
                            let to = layer * write[0] + batch * write[1] + head * write[2]
                                + positions[batch] * write[3]
                            if read[4] == 1, write[4] == 1,
                               let src = source.baseAddress, let dst = dest.baseAddress {
                                (dst + to).update(from: src + from, count: TensorSpec.headSize)
                            } else {
                                for channel in 0..<TensorSpec.headSize {
                                    dest[to + channel * write[4]] = source[from + channel * read[4]]
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
