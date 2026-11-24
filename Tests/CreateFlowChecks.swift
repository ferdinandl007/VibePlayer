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
                  onProgress: @escaping @Sendable (MusicGenerationProgress) -> Void) async throws -> URL {
        self.request = request
        receivedPreview = onPreview != nil
        onProgress(.tokens(50, 512))
        try await Task.sleep(nanoseconds: 200_000_000)
        throw TestError.failed
    }
}

@main
struct CreateFlowChecks {
    @MainActor static func main() async throws {
        try checkPreviewFadesAndDoesNotSkipFrames()
        precondition(CreateAcoustics.resolve(preference: "", instrumental: false, supportsEarlyPlayback: true) == .reference)
        precondition(CreateAcoustics.resolve(preference: "", instrumental: true, supportsEarlyPlayback: true) == .streaming)
        precondition(CreateAcoustics.resolve(preference: "streaming", instrumental: false, supportsEarlyPlayback: true) == .streaming)
        precondition(CreateAcoustics.resolve(preference: "reference", instrumental: true, supportsEarlyPlayback: true) == .reference)
        precondition(CreateAcoustics.resolve(preference: "streaming", instrumental: false, supportsEarlyPlayback: false) == .reference)
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
        renderer.isAvailable = false
        player.generateSong(idea: "A different song", instrumental: true, createStyles: "ambient")
        precondition(!player.isCreating && player.errorMessage == MusicGenerationError.metalUnavailable.errorDescription)
        player.errorMessage = nil
        player.generateSong()
        precondition(!player.isGenerating && player.errorMessage == MusicGenerationError.metalUnavailable.errorDescription)
        print("Create flow checks passed")
    }

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
