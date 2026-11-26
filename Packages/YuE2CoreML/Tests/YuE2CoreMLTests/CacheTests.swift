import CoreML
import Foundation
import Testing
@testable import YuE2CoreML

@Test func copiesTwoGuidanceHistoriesIntoLargerCache() throws {
    let original = try tensor([2, 2, 2, 3, 4], filled: 91)
    let expanded = try tensor([2, 2, 2, 6, 4])
    try copyCache(original, to: expanded, lengths: [3, 1])
    #expect(expanded[[1, 0, 1, 2, 3] as [NSNumber]].intValue == 91)
    #expect(expanded[[1, 1, 1, 0, 3] as [NSNumber]].intValue == 91)
    #expect(expanded[[1, 1, 1, 1, 3] as [NSNumber]].intValue == 0)
}

@Test func samplerResumesFromCheckpointAndMasksEarlyEnding() throws {
    var original = RandomStream(state: 42)
    let logits: (Int, Int) -> Float = { _, index in index <= 2 ? Float(3 - index) : -.infinity }
    _ = try Sampler.choose(logits, history: [], allowEnding: false, guidanceScale: 1.01, random: &original)
    var restored = RandomStream(state: original.state)
    let a = try Sampler.choose(logits, history: [], allowEnding: false, guidanceScale: 1.01, random: &original)
    let b = try Sampler.choose(logits, history: [], allowEnding: false, guidanceScale: 1.01, random: &restored)
    #expect(a != TensorSpec.musicEnd)
    #expect(a == b)
    #expect(original.state == restored.state)
}

@Test func strongerTextGuidanceChangesTheTokenChoice() throws {
    func logits(_ branch: Int, _ index: Int) -> Float {
        switch index {
        case 1: branch == 0 ? 9 : 20
        case 2: branch == 0 ? 4 : -25
        default: -.infinity
        }
    }
    var baseline = RandomStream(state: 42)
    var stronger = baseline
    let original = try Sampler.choose(logits, history: [], allowEnding: false, guidanceScale: 1.01, random: &baseline)
    let guided = try Sampler.choose(logits, history: [], allowEnding: false, guidanceScale: 1.2, random: &stronger)
    #expect(original == TensorSpec.musicEnd + 1)
    #expect(guided == TensorSpec.musicEnd + 2)
}
