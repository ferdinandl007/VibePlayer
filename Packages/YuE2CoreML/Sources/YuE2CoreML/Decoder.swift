import CoreML
import Foundation

struct Decoder {
    let assets: ModelAssets
    var pairedWeights: URL? = nil

    func run(_ stage: Stage, in work: URL, onWindow: ((AcousticWindow) async throws -> Void)? = nil,
             progress: (SongProgress) -> Void) async throws {
        let promptCapacity = assets.manifest.promptCapacity
        let batch = assets.manifest.batch
        let useMetal = stage.useMetal == true
        guard stage.index >= 0, stage.index < assets.manifest.decoderFrames.count,
              stage.limit == (try assets.limits(for: stage.request, useMetal: useMetal)),
              assets.decoderCapacities(useMetal: useMetal).contains(stage.capacity) else {
            throw YuE2Failure.request("Invalid decoder stage.")
        }
        let capacity = promptCapacity + (onWindow == nil ? stage.capacity : stage.limit) + 1
        let growable = assets.manifest.version == 3
        let model = useMetal ? nil : try assets.load(growable ? "GrowableDecoder" : "Decoder\(stage.capacity)")
        let embeddings = try Embeddings(assets.url("embeddings.f16"))
        func makeCache(filled: Int) throws -> DecoderCache {
            if useMetal {
                return .metal(try MetalDecoder(assets: assets, capacity: capacity,
                                              weightFile: pairedWeights, paired: pairedWeights != nil))
            }
            if growable {
                let initialFrames = stage.referenceCache == true ? capacity : filled
                return .growable(try GrowableCache(ceiling: capacity, filled: initialFrames))
            }
            guard let model else { throw YuE2Failure.inference("Missing decoder graph.") }
            let shape = TensorSpec.cache(batch: batch, frames: capacity)
            for component in CacheComponent.allCases {
                let key = component.rawValue
                guard let contract = model.modelDescription.stateDescriptionsByName[key]?.stateConstraint,
                      contract.bufferShape == shape, contract.dataType == .float16 else {
                    throw YuE2Failure.assets("Decoder \(stage.capacity) has an incompatible \(key) state.")
                }
            }
            return .stateful(model.makeState(), frames: capacity)
        }
        let lengths: [Int]
        let cache: DecoderCache
        var history: [Int]
        var random: RandomStream
        var logits: MLMultiArray
        if stage.index == 0 {
            let prompts = Array(try Tokenizer(url: assets.url("tokenizer.tiktoken")).prompt(stage.request).prefix(batch))
            lengths = prompts.map(\.count)
            guard lengths.allSatisfy({ $0 <= promptCapacity }) else {
                throw YuE2Failure.request("The prompt has \(lengths.max() ?? 0) tokens. This bundle supports \(promptCapacity).")
            }
            history = []
            random = RandomStream(state: stage.request.seed)
            cache = try makeCache(filled: lengths.max() ?? 0)
            let result = try prefill(prompts, embeddings: embeddings)
            logits = try requireTensor(result, "logits", shape: [batch, 1, TensorSpec.logits])
            for component in CacheComponent.allCases {
                let prefix = try requireTensor(result, "prefix_\(component.rawValue)",
                                               shape: TensorSpec.cache(batch: batch, frames: promptCapacity))
                try cache.withArray(component) { try copyCache(prefix, to: $0, lengths: lengths) }
            }
        } else {
            let previous = work.appendingPathComponent("stage-\(stage.index - 1)", isDirectory: true)
            let checkpoint = try readRecord(Checkpoint.self, at: previous.appendingPathComponent("checkpoint.json"))
            guard !checkpoint.finished, checkpoint.lengths.count == batch,
                  checkpoint.lengths.allSatisfy({ (1...promptCapacity).contains($0) }),
                  checkpoint.tokens.count < min(stage.limit, stage.capacity),
                  checkpoint.storedFrames == (checkpoint.lengths.max() ?? 0) + checkpoint.tokens.count,
                  checkpoint.tokens.allSatisfy({ (TensorSpec.codecOffset..<TensorSpec.codecOffset + 32768).contains($0) }) else {
                throw YuE2Failure.inference("The previous cache checkpoint is invalid.")
            }
            lengths = checkpoint.lengths
            history = checkpoint.tokens
            random = RandomStream(state: checkpoint.randomState)
            logits = try readTensor(previous.appendingPathComponent("logits.f16"), shape: [batch, 1, TensorSpec.logits])
            cache = try makeCache(filled: checkpoint.storedFrames)
            for component in CacheComponent.allCases {
                let saved = try readTensor(previous.appendingPathComponent("\(component.rawValue).f16"),
                                           shape: TensorSpec.cache(batch: batch, frames: checkpoint.storedFrames))
                try cache.withArray(component) {
                    try copyCache(saved, to: $0, lengths: lengths.map { $0 + history.count })
                }
            }
        }

        func makeMask(positions: [Int]) throws -> MLMultiArray {
            let frames = cache.frames
            let mask = try tensor([batch, 1, 2, frames + 1], filled: -10000)
            mask.withUnsafeMutableBufferPointer(ofType: Float16.self) { data, stride in
                for b in 0..<batch {
                    for head in 0..<2 {
                        let offset = b * stride[0] + head * stride[2]
                        for t in 0..<positions[b] { data[offset + t * stride[3]] = 0 }
                        data[offset + frames * stride[3]] = 0
                    }
                }
            }
            return mask
        }
        var mask = try makeMask(positions: lengths.map { $0 + history.count })
        let embedding = try tensor([batch, 1, TensorSpec.hidden])
        let stop = min(stage.capacity, stage.limit)
        var ended = false
        var windowStart = 0
        progress(.tokens(count: history.count, limit: stage.limit))
        while history.count < stop || (history.count == stop && stop == stage.limit) {
            try Task.checkCancellation()
            let token: Int
            if history.count == stage.limit {
                token = TensorSpec.musicEnd
            } else {
                let stride = logits.strides.map(\.intValue)
                token = try logits.withUnsafeBufferPointer(ofType: Float16.self) { data in
                    try Sampler.choose(
                        { b, i in Float(data[(batch == 1 ? 0 : b) * stride[0] + i * stride[2]]) },
                        history: history, allowEnding: history.count >= stage.request.minimumFrames,
                        random: &random)
                }
            }
            let positions = lengths.map { $0 + history.count }
            if try cache.reserve(for: positions) {
                mask = try makeMask(positions: positions)
            }
            let (sine, cosine) = try rope(positions.map { [$0] })
            try embeddings.fill(embedding, with: Array(repeating: [token], count: batch))
            let result = try await cache.predict(model, embedding: embedding, sine: sine, cosine: cosine,
                                                 mask: mask, positions: positions)
            if token == TensorSpec.musicEnd {
                ended = true
                break
            }
            logits = try requireTensor(result, "logits", shape: [batch, 1, TensorSpec.logits])
            mask.withUnsafeMutableBufferPointer(ofType: Float16.self) { data, stride in
                for b in 0..<batch {
                    for h in 0..<2 {
                        data[b * stride[0] + h * stride[2] + positions[b] * stride[3]] = 0
                    }
                }
            }
            history.append(token)
            if history.count.isMultiple(of: 50) { progress(.tokens(count: history.count, limit: stage.limit)) }
            if let onWindow, history.count < stage.limit,
               history.count == windowStart + AcousticWindow.advance + AcousticWindow.context {
                let plan = AcousticWindow.Plan(start: windowStart, end: history.count, final: false)
                try await onWindow(AcousticWindow(plan: plan, promptLength: lengths[0], promptCapacity: promptCapacity,
                                                  cache: cache))
                windowStart = plan.outputEnd
            }
        }
        try Task.checkCancellation()
        if let onWindow {
            guard ended else { throw YuE2Failure.inference("The decoder did not finish the streaming song.") }
            let plan = AcousticWindow.Plan(start: windowStart, end: history.count, final: true)
            try await onWindow(AcousticWindow(plan: plan, promptLength: lengths[0], promptCapacity: promptCapacity,
                                              cache: cache, finalTokens: history, naturalEnding: history.count < stage.limit))
            progress(.tokens(count: history.count, limit: stage.limit))
            return
        }
        let folder = work.appendingPathComponent("stage-\(stage.index)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let valid = lengths.map { $0 + history.count + (ended ? 1 : 0) }
        let rows = ended ? [valid[0]] : valid
        let stored = valid.max() ?? 0
        if !ended {
            let compact = try tensor([batch, 1, TensorSpec.logits])
            logits.transfer(to: compact)
            try writeTensor(compact, to: folder.appendingPathComponent("logits.f16"))
        }
        for component in CacheComponent.allCases {
            let packed = try tensor(TensorSpec.cache(batch: rows.count, frames: stored))
            try cache.withArray(component) { try copyCache($0, to: packed, lengths: rows) }
            try writeTensor(packed, to: folder.appendingPathComponent("\(component.rawValue).f16"))
        }
        let checkpoint = Checkpoint(tokens: history, lengths: lengths, randomState: random.state,
                                    finished: ended, naturalEnding: ended && history.count < stage.limit,
                                    storedFrames: stored)
        try writeRecord(checkpoint, to: folder.appendingPathComponent("checkpoint.json"))
        if ended { try writeRecord(stage.index, to: work.appendingPathComponent("acoustic-input.json")) }
        progress(.tokens(count: history.count, limit: stage.limit))
    }

    private func prefill(_ prompts: [[Int]], embeddings: Embeddings) throws -> any MLFeatureProvider {
        let cap = assets.manifest.promptCapacity
        let batch = prompts.count
        let lengths = prompts.map(\.count)
        let model = try assets.load("Prefill")
        let embedding = try tensor([batch, cap, TensorSpec.hidden])
        try embeddings.fill(embedding, with: prompts.map {
            $0 + Array(repeating: TensorSpec.musicEnd, count: cap - $0.count)
        })
        let (sine, cosine) = try rope(Array(repeating: Array(0..<cap), count: batch))
        let mask = try tensor([batch, 1, 2 * cap, cap], filled: -10000)
        mask.withUnsafeMutableBufferPointer(ofType: Float16.self) { data, stride in
            for b in 0..<batch {
                for h in 0..<2 {
                    for t in 0..<cap {
                        let offset = b * stride[0] + (h * cap + t) * stride[2]
                        for j in 0..<min(t + 1, lengths[b]) { data[offset + j * stride[3]] = 0 }
                    }
                }
            }
        }
        let indices = try intTensor(lengths.enumerated().map { $0.offset * cap + $0.element - 1 })
        return try model.prediction(from: provider(["embedding": embedding, "sine": sine, "cosine": cosine,
                                                   "mask": mask, "last_indices": indices]))
    }
}
