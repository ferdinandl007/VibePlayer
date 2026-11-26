import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct VibePlayerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @NSApplicationDelegateAdaptor(VibePlayerMacDelegate.self) private var macDelegate
    #endif
    @State private var player: PlayerStore = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--fixture-renderer") {
            return PlayerStore(generationBackend: FixtureMusicGenerationBackend(), lyricsWriter: FixtureLyricsWriter())
        }
        #endif
        return PlayerStore(generationBackend: YuE2GenerationBackend())
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(player)
                .preferredColorScheme(.dark)
                .onChange(of: player.shouldKeepScreenAwake, initial: true) { updateIdleTimer() }
                .onChange(of: scenePhase, initial: true) {
                    updateIdleTimer()
                    #if os(iOS)
                    player.setRadioRenderingInForeground(scenePhase == .active)
                    #endif
                }
                #if os(macOS)
                .frame(minWidth: 720, minHeight: 540)
                .onAppear { macDelegate.player = player }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandMenu("Playback") {
                Button(player.wantsPlayback ? "Pause" : "Play") { player.togglePlayback() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Previous Song") { player.playPreviousRadioSong() }
                    .disabled(!player.canPlayPreviousRadioSong)
                Button("Back 15 Seconds") { player.seek(player.elapsed - 15) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                Button("Forward 15 Seconds") { player.seek(player.elapsed + 15) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
            }
        }
        #endif
    }

    private func updateIdleTimer() {
        // The GPU render can be suspended if the device goes to sleep mid-song.
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = scenePhase == .active && player.shouldKeepScreenAwake
        #endif
    }
}

#if os(macOS)
@MainActor
private final class VibePlayerMacDelegate: NSObject, NSApplicationDelegate {
    weak var player: PlayerStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let player else { return .terminateNow }
        Task { @MainActor in
            await player.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif

#if DEBUG
private struct FixtureLyricsWriter: LyricsWriter {
    func writeLyrics(for request: MusicGenerationRequest) async throws -> String {
        "[Verse]\nThe quiet evening settles in."
    }
}
#endif
