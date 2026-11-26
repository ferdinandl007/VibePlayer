import Foundation

/// The explicit PRNG state travels with the cache, keeping sampling continuous across processes.
struct RandomStream {
    var state: UInt64

    mutating func openUnit() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return (Double(value >> 12) + 0.5) * 0x1p-52
    }
}

struct Sampler {
    struct Entry {
        let token: Int
        let score: Float
    }

    static func choose(
        _ logit: (Int, Int) -> Float, history: [Int], allowEnding: Bool,
        random: inout RandomStream
    ) throws -> Int {
        // The sampler visits codec indices in order, so each recent token can use one bit.
        var repeated = [UInt64](repeating: 0, count: (TensorSpec.logits + 63) / 64)
        let tokenRange = TensorSpec.musicEnd..<(TensorSpec.musicEnd + TensorSpec.logits)
        for token in history.suffix(50) where tokenRange.contains(token) {
            let index = token - TensorSpec.musicEnd
            repeated[index / 64] |= UInt64(1) << (index % 64)
        }
        var top = [Entry]()
        top.reserveCapacity(101)
        for index in (allowEnding ? 0 : 1) ..< TensorSpec.logits {
            let positive = logit(0, index)
            let negative = logit(1, index)
            var score = negative + 1.01 * (positive - negative)
            guard score.isFinite else { continue }
            let token = TensorSpec.musicEnd + index
            if repeated[index / 64] & (UInt64(1) << (index % 64)) != 0 {
                score = score < 0 ? score * 1.2 : score / 1.2
            }
            if top.count == 100, let last = top.last, score <= last.score { continue }
            var low = 0
            var high = top.count
            while low < high {
                let mid = (low + high) / 2
                if score > top[mid].score { high = mid } else { low = mid + 1 }
            }
            top.insert(Entry(token: token, score: score), at: low)
            if top.count > 100 { top.removeLast() }
        }
        guard let first = top.first else { throw YuE2Failure.inference("Invalid token logits.") }
        let weights = top.map { exp(Double($0.score - first.score)) }
        let threshold = weights.reduce(0, +) * 0.95
        var included = 0
        var total = 0.0
        while included < weights.count, total < threshold {
            total += weights[included]
            included += 1
        }
        var draw = random.openUnit() * total
        for i in 0..<included {
            draw -= weights[i]
            if draw < 0 { return top[i].token }
        }
        return top[included - 1].token
    }
}
