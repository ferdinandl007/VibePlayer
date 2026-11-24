import Foundation
import Testing
@testable import YuE2CoreML

@Test func renderedAudioAvoidsClippingAndStartsAndEndsAtSilence() {
    let waveform = Array(repeating: [Float(1.4), Float(-1.2)], count: 48_000).flatMap { $0 }
    let pcm = makePCM(waveform, naturalEnding: false)
    #expect(pcm.count == waveform.count)
    #expect(pcm.prefix(2).allSatisfy { $0 == 0 })
    #expect(pcm.suffix(2).allSatisfy { $0 == 0 })
    #expect(pcm.max() == 29_491)
    #expect(pcm[94_000] < pcm[48_000])
}

@Test func existingManifestsKeepTwoConditioningBranches() throws {
    let json = """
    {"version":1,"promptCapacity":264,"decoderFrames":[512],"acousticFrames":[512]}
    """
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))
    #expect(manifest.batch == 2)
    #expect(manifest.metalFrames == nil)
}

@Test func fastAcousticsRequiresOptInAndKeepsFullContext() throws {
    let json = """
    {"version":3,"promptCapacity":264,"decoderFrames":[1104,3152,5200],"acousticFrames":[512,4213,5200]}
    """
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))
    #expect(manifest.acousticCapacity(for: 3152, profile: nil, hasFastGraph: true) == 4213)
    #expect(manifest.acousticCapacity(for: 3152, profile: .fast, hasFastGraph: false) == 4213)
    #expect(manifest.acousticCapacity(for: 3328, profile: .fast, hasFastGraph: true) == 3328)
    #expect(manifest.acousticCapacity(for: 3329, profile: .fast, hasFastGraph: true) == 4213)
    #expect(manifest.acousticCapacity(for: 512, profile: .fast, hasFastGraph: true) == 512)
}

@Test func earlyPCMMatchesSavedAudioEvenWhenLaterSamplesAreLouder() {
    let frames = 48_000
    var waveform = [Float](repeating: 0.8, count: frames * 2)
    waveform[frames] = 2
    let opening = pcmSamples(waveform.prefix(frames), totalFrames: frames, naturalEnding: true, gain: 1, streaming: true)
    let saved = makePCM(waveform, naturalEnding: true, streaming: true)
    #expect(opening.elementsEqual(saved.prefix(opening.count)))
    #expect(saved.max()! <= 29_491)
}

@Test func streamedRangesMatchTheSavedFileAtTheJoinAndEnding() throws {
    var joined = [Float](repeating: 0.4, count: 2_000 * 2)
    let prefix = pcmSamples(joined.prefix(1_980 * 2), totalFrames: 4_000, naturalEnding: true, gain: 1, streaming: true)
    let secondWindow = [Float](repeating: -0.8, count: 2_050 * 2)
    try joinWindow(secondWindow, at: 1_950, into: &joined, appending: 2_000..<4_000, overlap: 20)
    let suffix = pcmSamples(joined[(1_980 * 2)...], totalFrames: 4_000, naturalEnding: true, gain: 1, streaming: true)
    #expect(prefix + suffix == makePCM(joined, naturalEnding: true, streaming: true))
    #expect(joined[1_979 * 2] == 0.4)
    #expect(joined[1_999 * 2] > -0.8)
    #expect(joined[2_000 * 2] == -0.8)
}

@Test func waveformStartUsesTheMeasuredDecodeRate() {
    #expect(canStartStreaming(buffered: 3.835, remaining: 120, elapsed: 0.7))
    #expect(!canStartStreaming(buffered: 3.835, remaining: 120, elapsed: 4))
}

@Test func finalAcousticWindowKeepsEnoughHistoryForTheVocoder() {
    let first = AcousticWindow.Plan(start: 0, end: 448, final: false)
    let second = AcousticWindow.Plan(start: first.outputEnd, end: 832, final: false)
    let final = AcousticWindow.Plan(start: second.outputEnd, end: 834, final: true)
    #expect(first.input == 0..<448 && first.outputEnd == 384)
    #expect(second.input == 320..<832 && second.outputEnd == 768)
    #expect(final.input == 704..<834 && final.outputEnd == 834)
}
