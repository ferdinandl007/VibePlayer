import Foundation
import AVFoundation

@MainActor
private final class TestWriter: LyricsWriter {
    var failRewrite = false
    var lyricsRequest: MusicGenerationRequest?
    var revisedField: MusicPromptField?

    func rewriteIdea(_ idea: String, styles: String) async throws -> String? {
        if failRewrite { throw TestError.failed }
        return "A polished idea"
    }

    func writeLyrics(for request: MusicGenerationRequest) async throws -> String {
        lyricsRequest = request
        return "Original lyrics"
    }

    func reviseForMusicModel(_ text: String, field: MusicPromptField, targetTokens: Int) async throws -> String? {
        revisedField = field
        precondition(targetTokens < 80 && text.contains("jazz"))
        return "vocal music, mellow jazz"
    }
}

private enum TestError: LocalizedError {
    case failed
    var errorDescription: String? { "Test renderer failed" }
}

@MainActor
private final class TestRenderer: MusicGenerationBackend {
    var isAvailable = true
    var request: MusicGenerationRequest?
    var receivedPreview = false
    var needsRevision = false

    func promptUsage(for request: MusicGenerationRequest) async throws -> MusicPromptUsage? {
        guard needsRevision else { return nil }
        let revised = request.style == "vocal music, mellow jazz"
        return MusicPromptUsage(count: revised ? 249 : 318, limit: 264, styleTokens: revised ? 21 : 90, lyricTokens: 188)
    }

    func generate(_ request: MusicGenerationRequest, onPreview: (@Sendable (MusicAudioPreview) -> Void)?,
                  onProgress: @escaping @Sendable (MusicGenerationProgress) -> Void) async throws -> MusicGenerationOutput {
        self.request = request
        receivedPreview = onPreview != nil
        onProgress(.tokens(50, 512))
        try await Task.sleep(nanoseconds: 200_000_000)
        throw TestError.failed
    }
}

#if os(macOS)
@MainActor
private final class RadioTestRenderer: MusicGenerationBackend {
    let isAvailable = true
    let directory: URL
    private(set) var requests: [MusicGenerationRequest] = []
    var readyThrough = 2
    var canPrepareRadioPair = false

    init(directory: URL) { self.directory = directory }

    func generate(_ request: MusicGenerationRequest, onPreview: (@Sendable (MusicAudioPreview) -> Void)?,
                  onProgress: @escaping @Sendable (MusicGenerationProgress) -> Void) async throws -> MusicGenerationOutput {
        requests.append(request)
        let index = requests.count
        while index > readyThrough { try await Task.sleep(for: .milliseconds(10)) }
        let url = directory.appendingPathComponent("\(index).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8_000, channels: 1, interleaved: true)!
        let frames = AVAudioFrameCount((3 + index * 3) * 8_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.int16ChannelData![0].update(repeating: 0, count: Int(frames))
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatInt16, interleaved: true)
        try file.write(from: buffer)
        return MusicGenerationOutput(url: url, radioSuccessorSeed: request.radioSuccessorSeed)
    }
}
#endif

@main
struct CreateFlowChecks {
    @MainActor static func main() async throws {
        try checkPreviewFadesAndDoesNotSkipFrames()
        precondition(CreateAcoustics.resolve(preference: "", instrumental: false, supportsEarlyPlayback: true) == .reference)
        #if os(macOS)
        precondition(CreateAcoustics.resolve(preference: "", instrumental: true, supportsEarlyPlayback: true) == .reference)
        #else
        precondition(CreateAcoustics.resolve(preference: "", instrumental: true, supportsEarlyPlayback: true) == .streaming)
        #endif
        precondition(CreateAcoustics.resolve(preference: "streaming", instrumental: false, supportsEarlyPlayback: true) == .streaming)
        precondition(CreateAcoustics.resolve(preference: "reference", instrumental: true, supportsEarlyPlayback: true) == .reference)
        precondition(CreateAcoustics.resolve(preference: "streaming", instrumental: false, supportsEarlyPlayback: false) == .reference)
        precondition(CreateAcoustics.resolve(preference: "fastFullSong", instrumental: true, supportsEarlyPlayback: true) == .reference)
        precondition(CreateAcoustics.resolve(preference: "fastFullSong", instrumental: true, supportsEarlyPlayback: false,
                                             supportsFastFullSong: true) == .fastFullSong)
        let writer = TestWriter()
        let renderer = TestRenderer()
        let player = PlayerStore(generationBackend: renderer, lyricsWriter: writer)

        player.generateSong(idea: "rough idea", instrumental: false, createStyles: "jazz")
        try await Task.sleep(nanoseconds: 60_000_000)
        precondition(player.isCreating && player.creationStatus.contains("50"))
        precondition(writer.lyricsRequest?.style.contains("A polished idea") == true)
        precondition(renderer.request?.style.contains("A polished idea") == true)
        precondition(renderer.request?.lyrics == "Original lyrics")
        precondition(renderer.request?.createRenderer == .metal)
        precondition(renderer.receivedPreview && renderer.request?.createAcoustics == .reference)
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(!player.isCreating && player.errorMessage == "Test renderer failed")

        writer.failRewrite = true
        player.generateSong(idea: "original idea", instrumental: true, createStyles: "ambient", acoustics: .streaming)
        try await Task.sleep(nanoseconds: 60_000_000)
        precondition(renderer.request?.style.contains("original idea") == true)
        precondition(renderer.receivedPreview)
        precondition(player.creationNotice?.contains("original") == true)
        player.cancelGeneration()
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(!player.isCreating && player.errorMessage == nil)
        writer.failRewrite = false
        renderer.needsRevision = true
        player.generateSong(idea: "A long description", instrumental: false, preparedLyrics: "[Verse]\nKeep this line intact", createStyles: "jazz")
        try await Task.sleep(for: .milliseconds(80))
        precondition(writer.revisedField == .description)
        precondition(renderer.request?.style == "vocal music, mellow jazz")
        precondition(renderer.request?.lyrics == "[Verse]\nKeep this line intact")
        precondition(player.creationNotice?.contains("revised a copy") == true)
        player.cancelGeneration()

        renderer.needsRevision = false
        let codes = Array(repeating: 901, count: 100)
        let reference = MusicReference(title: "Existing take", tokens: codes, originalAudio: nil, openingFrames: 75)
        player.generateSong(idea: "Take the outro acoustic", instrumental: true, createStyles: "jazz",
                            acoustics: .streaming, reference: reference)
        try await Task.sleep(for: .milliseconds(80))
        precondition(renderer.request?.semanticPrefix == Array(codes.prefix(75)))
        precondition(renderer.request?.createAcoustics == .reference)
        player.cancelGeneration()

        renderer.isAvailable = false
        player.generateSong(idea: "A different song", instrumental: true, createStyles: "ambient")
        precondition(!player.isCreating && player.errorMessage == MusicGenerationError.metalUnavailable.errorDescription)
        player.errorMessage = nil
        player.generateSong()
        precondition(!player.isGenerating && player.errorMessage == MusicGenerationError.metalUnavailable.errorDescription)
        #if os(macOS)
        try await checkRadioKeepsPlayingAfterLateEdit()
        try await checkRadioUsesPreparedSuccessor()
        #endif
        print("Create flow checks passed")
    }

    #if os(macOS)
    @MainActor private static func checkRadioKeepsPlayingAfterLateEdit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = RadioTestRenderer(directory: directory)
        let player = PlayerStore(generationBackend: renderer, lyricsWriter: TestWriter())
        let savedBefore = player.savedSongs.map(\.id)
        defer { player.pause(); player.cancelRadioPreparation() }

        func waitFor(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(4))
            while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            if !condition() { throw TestError.failed }
        }

        player.play()
        try await waitFor { player.isPlaying && renderer.requests.count == 3 }
        precondition(player.duration == 6 && player.radioReadyCount == 1)

        let tempo = player.selected.tempo == 60 ? 80.0 : 60.0
        player.setTempo(tempo, commit: true)
        player.seek(player.duration - 1)
        try await waitFor { player.isPlaying && player.duration == 9 && renderer.requests.count == 4 }
        precondition(renderer.requests.last?.style.contains("\(Int(tempo)) BPM") == true)

        renderer.readyThrough = 4
        try await waitFor { player.isPlaying && player.duration == 15 }
        precondition(player.savedSongs.map(\.id) == savedBefore)
    }
    @MainActor private static func checkRadioUsesPreparedSuccessor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = RadioTestRenderer(directory: directory)
        renderer.canPrepareRadioPair = true
        let player = PlayerStore(generationBackend: renderer, lyricsWriter: TestWriter())
        player.vibes[player.selectedIndex].tags.removeAll { $0.category == .voice }
        player.vibes[player.selectedIndex].tags.append(SoundTag(name: "Instrumental", symbol: "music.note", category: .voice))
        defer { player.cancelRadioPreparation() }
        player.prepareRadio()

        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while player.radioReadyCount < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(player.radioReadyCount == 2 && renderer.requests.count == 2)
        let first = renderer.requests[0], second = renderer.requests[1]
        precondition(first.radioSuccessorSeed == second.seed && first.seed != second.seed)
        precondition(second.radioSuccessorSeed == nil)
    }
    #endif

    @MainActor private static func checkPreviewFadesAndDoesNotSkipFrames() throws {
        let fade = PreviewPCM.fade
        let first = PreviewPCM.reserve + 2 * fade
        let pcm = PreviewPCM(capacity: first * 2)
        let samples = [Int16](repeating: 8192, count: first * 2)
        try samples.withUnsafeBufferPointer { try pcm.append($0, at: 0) }
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let node = pcm.sourceNode(format: format)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: AVAudioFrameCount(2 * fade))
        try engine.start()
        defer { engine.stop() }
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(2 * fade))!
        pcm.wantsPlayback.store(true, ordering: .releasing)

        func render() throws -> [Float] {
            let status = try engine.renderOffline(AVAudioFrameCount(2 * fade), to: output)
            precondition(status == .success)
            return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        }

        let opening = try render()
        precondition(opening[0] < 0.01 && abs(opening.last! - 0.25) < 0.001)
        let ending = try render()
        precondition(ending[0] > 0.24 && ending.last == 0)
        let held = pcm.played.load(ordering: .acquiring)
        precondition(pcm.needsBuffer.load(ordering: .acquiring) && (3 * fade - 2...3 * fade + 2).contains(held))
        let silence = try render()
        precondition(silence.allSatisfy { $0 == 0 } && pcm.played.load(ordering: .acquiring) == held)
        try samples.withUnsafeBufferPointer { try pcm.append($0, at: first) }
        pcm.needsBuffer.store(false, ordering: .releasing)
        let restart = try render()
        precondition(restart[0] < 0.01 && abs(restart.last! - 0.25) < 0.001)
        precondition(pcm.played.load(ordering: .acquiring) == held + 2 * fade)
    }
}
