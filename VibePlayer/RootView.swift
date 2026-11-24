import SwiftUI
import UniformTypeIdentifiers
import AVKit

struct RootView: View {
    @Environment(PlayerStore.self) private var player
    @State private var tab = 0
    @State private var showPlayer = ProcessInfo.processInfo.arguments.contains("--preview-player")
    @State private var showImporter = false
    @State private var showNewStation = false
    @State private var newStationName = ""

    var body: some View {
        platformNavigation
        .tint(.white)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url): player.load(url: url, name: url.deletingPathExtension().lastPathComponent)
            case .failure: player.errorMessage = "Couldn't import this audio file. Please try again."
            }
        }
        .alert("New station", isPresented: $showNewStation) {
            TextField("Station name", text: $newStationName)
            Button("Create") { player.createStation(named: newStationName); newStationName = ""; showPlayer = true }
            Button("Cancel", role: .cancel) { newStationName = "" }
        } message: { Text("Start with the current sound, then adjust it to make it your own.") }
        .onAppear { if ProcessInfo.processInfo.arguments.contains("--preview-playing") { player.play() } }
        .alert("Vibe Player", isPresented: Binding(get: { player.errorMessage != nil }, set: { if !$0 { player.errorMessage = nil } })) {
            Button("OK", role: .cancel) { player.errorMessage = nil }
        } message: { Text(player.errorMessage ?? "") }
    }
    @ViewBuilder private var platformNavigation: some View {
        #if os(macOS)
        adaptiveNavigation
        #else
        TabView(selection: $tab) {
            NavigationStack { discover.safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer } }.tabItem { Label("Radio", systemImage: "dot.radiowaves.left.and.right") }.tag(0)
            NavigationStack { CreateSongView { showPlayer = true } }.tabItem { Label("Create", systemImage: "square.and.pencil") }.tag(2)
            NavigationStack { library.safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer } }.tabItem { Label("Library", systemImage: "square.stack.3d.up") }.tag(1)
        }.fullScreenCover(isPresented: $showPlayer) { PlayerView() }
        #endif
    }
    #if os(macOS)
    private var adaptiveNavigation: some View {
        NavigationSplitView {
            List(selection: Binding<Int?>(
                get: { tab },
                set: { selection in
                    guard let selection else { return }
                    tab = selection
                    showPlayer = false
                }
            )) {
                Label("Radio", systemImage: "dot.radiowaves.left.and.right").tag(0)
                Label("Create", systemImage: "square.and.pencil").tag(2)
                Label("Library", systemImage: "square.stack.3d.up").tag(1)
            }
            .listStyle(.sidebar)
            .navigationTitle("Vibe Player")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            if showPlayer {
                PlayerView(close: { showPlayer = false })
            } else {
                NavigationStack {
                    switch tab {
                    case 2: CreateSongView { showPlayer = true }
                    case 1: library.safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
                    default: discover.safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
                    }
                }
            }
        }
    }
    #endif

    private var miniPlayer: some View {
        MiniPlayer { showPlayer = true }.padding(.horizontal, 12).padding(.bottom, 6)
    }
    private var discover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("VIBE PLAYER").font(.system(size: 12, weight: .bold, design: .rounded)).tracking(2.4).foregroundStyle(.white.opacity(0.6))
                        Text("Radio").font(.system(size: 32, weight: .bold, design: .rounded))
                    }
                    Spacer()
                    Image(systemName: "waveform").font(.system(size: 19, weight: .semibold)).frame(width: 46, height: 46).background(.white.opacity(0.1), in: Circle())
                }
                .padding(.top, 12)

                Button { if !player.radioMode { player.select(player.selected) }; showPlayer = true } label: {
                    ZStack(alignment: .bottomLeading) {
                        VibeArtwork(palette: player.selected.palette, variant: .hero)
                        LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("YOUR STATION").font(.caption2.weight(.bold)).tracking(1.6).foregroundStyle(.white.opacity(0.75))
                            Text(player.selected.name).font(.system(size: 30, weight: .bold, design: .rounded))
                            Text("Tune in and shape the sound").font(.subheadline).foregroundStyle(.white.opacity(0.75))
                            HStack(spacing: 7) { Text("Open player"); Image(systemName: "arrow.up.right") }.font(.subheadline.weight(.semibold)).padding(.top, 8)
                        }.padding(24)
                    }.frame(height: 265).clipShape(RoundedRectangle(cornerRadius: 25))
                }.buttonStyle(.plain).accessibilityIdentifier("open-current-station")

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Pick a station").font(.title2.bold())
                        Spacer()
                        Button { showNewStation = true } label: { Label("New station", systemImage: "plus") }
                            .font(.subheadline.weight(.semibold))
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 17) {
                            ForEach(player.vibes) { vibe in
                                Button { player.select(vibe); showPlayer = true } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        VibeArtwork(palette: vibe.palette, variant: .disc).frame(width: 148, height: 148)
                                        Text(vibe.name).font(.headline).lineLimit(1)
                                        Text(vibe.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    }.frame(width: 148, alignment: .leading)
                                }.buttonStyle(.plain).accessibilityIdentifier("station-\(vibe.name)")
                            }
                        }
                    }
                }
                Button { showImporter = true } label: {
                    HStack(spacing: 15) {
                        Image(systemName: "waveform.badge.plus").font(.title2).frame(width: 48, height: 48).background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 4) { Text("Bring your own audio").font(.headline); Text("Play a file from your device").font(.subheadline).foregroundStyle(.secondary) }
                        Spacer(); Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
                    }.padding(16).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
                }.buttonStyle(.plain)
            }.padding(.horizontal, 22).padding(.bottom, 24).frame(maxWidth: 1050).frame(maxWidth: .infinity)
        }.background(Color(red: 0.045, green: 0.045, blue: 0.055)).vibeHideNavigationBar()
    }
    private var library: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Library").font(.largeTitle.bold()).padding(.top, 12)
                VStack(alignment: .leading, spacing: 14) {
                    Text("Songs").font(.title2.bold())
                    if player.savedSongs.isEmpty {
                        Text("Songs you create or like will appear here.").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        ForEach(player.savedSongs) { song in
                            HStack(spacing: 14) {
                                Button { player.playSavedSong(song); showPlayer = true } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: "play.fill").frame(width: 54, height: 54).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(song.title).font(.headline).lineLimit(1)
                                            Text(song.style).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Menu { Button("Delete song", role: .destructive) { player.deleteSavedSong(song) } } label: {
                                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                                }.accessibilityLabel("Song options")
                            }
                        }
                    }
                }
                Text("Your vibes").font(.title2.bold())
                ForEach(player.vibes) { vibe in
                    Button { player.select(vibe); showPlayer = true } label: {
                        HStack(spacing: 16) {
                            VibeArtwork(palette: vibe.palette, variant: .disc).frame(width: 72, height: 72)
                            VStack(alignment: .leading, spacing: 5) { Text(vibe.name).font(.headline); Text(vibe.subtitle).font(.subheadline).foregroundStyle(.secondary) }
                            Spacer()
                            if player.savedIDs.contains(vibe.id) { Image(systemName: "bookmark.fill").foregroundStyle(.white.opacity(0.7)) }
                            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Song ideas").font(.title2.bold())
                    if player.songIdeas.isEmpty {
                        Text("Your saved song ideas will appear here.").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        ForEach(player.songIdeas) { idea in
                            NavigationLink { SongIdeaDetail(idea: idea) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "music.note").font(.title3).frame(width: 54, height: 54).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
                                    VStack(alignment: .leading, spacing: 4) { Text(idea.title).font(.headline); Text(idea.prompt).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                                    Spacer(); Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(.top, 8)
                Button { showImporter = true } label: { Label("Import audio", systemImage: "plus.circle.fill").font(.headline).frame(maxWidth: .infinity).padding().background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16)) }
                    .buttonStyle(.plain).padding(.top, 12)
            }.padding(.horizontal, 22).frame(maxWidth: 1050).frame(maxWidth: .infinity)
        }.background(Color(red: 0.045, green: 0.045, blue: 0.055)).vibeHideNavigationBar()
    }
}

struct MiniPlayer: View {
    @Environment(PlayerStore.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var open: () -> Void

    private var fill: Double {
        if player.isWaitingForRadio { return max(0.03, min(1, player.generationProgress)) }
        guard player.duration > 0 else { return 0 }
        return min(1, max(0, player.elapsed / player.duration))
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    if player.radioMode { VibeArtwork(palette: player.selected.palette, variant: .disc).frame(width: 45, height: 45) }
                    else { TrackArtwork(image: player.trackArtwork, palette: player.selected.palette).frame(width: 45, height: 45) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(player.radioMode ? player.selected.name : player.trackName).font(.subheadline.bold()).lineLimit(1)
                        if player.isWaitingForRadio, let message = player.radioLoadingMessage {
                            let stage = player.isGenerating ? player.radioRenderStage.title : message
                            Text(stage).font(.caption).foregroundStyle(.white.opacity(0.76)).lineLimit(1)
                        } else {
                            Text(player.radioMode ? player.trackName : (player.trackArtist ?? (player.isGenerated ? "Your song" : "Audio from your device"))).font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { player.togglePlayback() } label: { Image(systemName: player.wantsPlayback ? "pause.fill" : "play.fill").font(.title3).frame(width: 44, height: 44) }
                .accessibilityLabel(player.wantsPlayback ? "Pause" : "Play")
        }.foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 8)
            .buttonStyle(.plain)
            .background {
                let shape = RoundedRectangle(cornerRadius: 18)
                shape.fill(.ultraThinMaterial)
                    .overlay {
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(.linearGradient(colors: [Color.indigo.opacity(0.47), Color(red: 0.63, green: 0.52, blue: 0.88).opacity(0.30)],
                                                      startPoint: .leading, endPoint: .trailing))
                                .overlay(alignment: .trailing) {
                                    Rectangle().fill(.white.opacity(0.12)).frame(width: 1)
                                }
                                .frame(width: geometry.size.width * fill)
                                .opacity(fill > 0 ? 1 : 0)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.clipShape(shape)
                    }
                    .animation(reduceMotion ? nil : .linear(duration: 0.18), value: fill)
                    .accessibilityHidden(true)
            }
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.1)))
    }
}

struct VibeArtwork: View {
    enum Variant { case disc, hero }
    var palette: Int
    var variant: Variant
    private var colors: [Color] {
        switch palette % 3 {
        case 1: [.init(red: 0.84, green: 0.48, blue: 0.64), .init(red: 0.42, green: 0.37, blue: 0.75), .init(red: 0.90, green: 0.68, blue: 0.44)]
        case 2: [.init(red: 0.18, green: 0.58, blue: 0.51), .init(red: 0.20, green: 0.32, blue: 0.56), .init(red: 0.54, green: 0.65, blue: 0.48)]
        default: [.init(red: 0.31, green: 0.50, blue: 0.72), .init(red: 0.54, green: 0.37, blue: 0.65), .init(red: 0.73, green: 0.55, blue: 0.34)]
        }
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                AngularGradient(colors: colors + [colors[0]], center: .center).blur(radius: variant == .disc ? 10 : 35)
                if variant == .disc {
                    Circle().stroke(.white.opacity(0.25), lineWidth: 1)
                    Circle().stroke(.white.opacity(0.14), lineWidth: geometry.size.width * 0.12).padding(geometry.size.width * 0.13).blur(radius: 5)
                    Circle().fill(.black.opacity(0.88)).frame(width: geometry.size.width * 0.35)
                    Image(systemName: "waveform").font(.system(size: geometry.size.width * 0.12, weight: .bold)).foregroundStyle(.white)
                } else {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 1).frame(width: geometry.size.width * 0.6).offset(x: geometry.size.width * 0.23, y: -20)
                    Circle().stroke(.white.opacity(0.1), lineWidth: 35).frame(width: geometry.size.width * 0.43).offset(x: geometry.size.width * 0.23, y: -20)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
                .clipShape(RoundedRectangle(cornerRadius: variant == .disc ? geometry.size.width / 2 : 0))
        }
    }
}
