import SwiftUI

@main
struct VibePlayerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: PlayerStore = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--fixture-renderer") {
            return PlayerStore(generationBackend: FixtureMusicGenerationBackend())
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
                .onChange(of: scenePhase) { updateIdleTimer() }
                #if os(macOS)
                .frame(minWidth: 720, minHeight: 540)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandMenu("Playback") {
                Button(player.wantsPlayback ? "Pause" : "Play") { player.togglePlayback() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
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
