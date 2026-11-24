import SwiftUI

/// Picker sections are presentation groups. Their stored category stays compatible
/// with the current music-profile format while the renderer is being developed.
private enum SoundSection: String, CaseIterable, Identifiable, Codable {
    case genres = "Genres", moods = "Moods", instruments = "Instruments", voice = "Voice"
    case rhythms = "Rhythms", textures = "Textures", production = "Production", themes = "Themes", lyrics = "Lyrics", vocalStyle = "Vocal style"
    var id: String { rawValue }
    var storedCategory: TagCategory {
        switch self {
        case .genres, .rhythms, .production: .genre
        case .moods, .textures, .themes, .lyrics, .vocalStyle: .mood
        case .instruments: .instrument
        case .voice: .voice
        }
    }
    var symbol: String {
        switch self {
        case .genres: "music.note.list"
        case .moods: "sparkles"
        case .instruments: "pianokeys"
        case .voice: "mic"
        case .rhythms: "metronome"
        case .textures: "waveform.path"
        case .production: "slider.horizontal.3"
        case .themes: "text.bubble"
        case .lyrics: "text.quote"
        case .vocalStyle: "mic"
        }
    }
}

private struct PickerSound: Identifiable, Codable {
    var section: SoundSection
    var tag: SoundTag
    var id: String { "\(section.rawValue):\(tag.name.lowercased())" }
}

private let extraPickerSounds: [PickerSound] = {
    func options(_ section: SoundSection, _ values: [(String, String)]) -> [PickerSound] {
        values.map { PickerSound(section: section, tag: SoundTag(name: $0.0, symbol: $0.1, category: section.storedCategory)) }
    }
    return options(.genres, [("Rock", "guitars"), ("Folk", "leaf"), ("R&B", "heart"), ("Classical", "building.columns"), ("Blues", "drop"), ("Disco", "sparkles"), ("Afrobeats", "globe"), ("Latin", "sun.max"), ("Country", "mountain.2"), ("Reggae", "sun.max.fill"), ("Punk", "hand.raised"), ("Metal", "bolt")])
    + options(.moods, [("Hopeful", "sun.horizon"), ("Calm", "cloud"), ("Playful", "face.smiling"), ("Romantic", "heart"), ("Dark", "moon.stars"), ("Nostalgic", "clock.arrow.circlepath"), ("Dramatic", "theatermasks"), ("Peaceful", "leaf")])
    + options(.instruments, [("Strings", "music.note"), ("Saxophone", "music.note"), ("Flute", "wind"), ("Electric piano", "pianokeys"), ("Acoustic guitar", "guitars"), ("Brass", "music.note"), ("Organ", "pianokeys"), ("Percussion", "metronome")])
    + options(.rhythms, [("Four on the floor", "metronome"), ("Breakbeat", "waveform"), ("Syncopated", "metronome"), ("Half-time", "speedometer"), ("Swing", "metronome"), ("Shuffle", "shuffle"), ("Steady pulse", "waveform.path")])
    + options(.textures, [("Airy", "wind"), ("Warm", "sun.haze"), ("Ethereal", "cloud"), ("Gritty", "waveform.path"), ("Lush", "leaf"), ("Minimal", "circle"), ("Spacious", "circle.dotted"), ("Intimate", "heart")])
    + options(.production, [("Vinyl crackle", "opticaldisc"), ("Tape saturation", "waveform"), ("Reverb", "waveform.path"), ("Dry", "circle"), ("Analog", "slider.horizontal.3"), ("Crisp", "sparkle"), ("Distorted", "waveform.path"), ("Live room", "speaker.wave.2")])
    + options(.themes, [("Late night", "moon.stars"), ("New beginnings", "sunrise"), ("Road trip", "car"), ("Rainy day", "cloud.rain"), ("Summer", "sun.max"), ("Heartbreak", "heart.slash"), ("Celebration", "sparkles"), ("Dreams", "cloud.moon")])
    + options(.lyrics, [("Storytelling", "text.book.closed"), ("Poetic", "text.quote"), ("Conversational", "bubble.left.and.bubble.right"), ("Uplifting lyrics", "sunrise"), ("Reflective lyrics", "cloud.moon"), ("Simple chorus", "repeat")])
    + options(.vocalStyle, [("Breathy vocals", "wind"), ("Choir", "person.3"), ("Harmonies", "waveform"), ("Spoken word", "quote.bubble"), ("Falsetto", "mic"), ("Soft vocals", "speaker.wave.1")])
}()

struct TagEditor: View {
    @Environment(PlayerStore.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var section: SoundSection = .genres
    @State private var search = ""
    @State private var selection: [SoundTag] = []
    @State private var customSounds: [PickerSound] = []
    @FocusState private var searchFocused: Bool
    private let customKey = "vibe-player-custom-sounds-v1"

    private var baseSounds: [PickerSound] {
        tagOptions.map { tag in
            let group: SoundSection
            switch tag.category {
            case .genre: group = .genres
            case .mood: group = .moods
            case .instrument: group = .instruments
            case .voice: group = .voice
            }
            return PickerSound(section: group, tag: tag)
        } + extraPickerSounds
    }
    private var allSounds: [PickerSound] { baseSounds + customSounds }
    private var options: [PickerSound] {
        allSounds.filter { $0.section == section && (search.isEmpty || $0.tag.name.localizedCaseInsensitiveContains(search)) }
    }
    private var trimmedSearch: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matchingSound: PickerSound? {
        allSounds.first { $0.tag.name.localizedCaseInsensitiveCompare(trimmedSearch) == .orderedSame }
    }
    private var canAddCustom: Bool {
        !trimmedSearch.isEmpty && trimmedSearch.count <= 24 && section != .voice && matchingSound == nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 20) {
                            ForEach(SoundSection.allCases) { item in
                                Button(item.rawValue) { section = item; search = "" }
                                    .font(.headline).foregroundStyle(section == item ? .white : .white.opacity(0.48))
                                    .accessibilityAddTraits(section == item ? .isSelected : [])
                            }
                        }
                    }.accessibilityIdentifier("sound-sections")
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search or add", text: $search)
                            .focused($searchFocused).autocorrectionDisabled().submitLabel(.done)
                            .accessibilityIdentifier("sound-search")
                    }.padding(14).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))

                    if section == .voice {
                        Text("Choose vocals or instrumental. You can change this anytime.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    FlowLayout(spacing: 10) {
                        ForEach(options) { option in
                            let selected = selection.contains { $0.name.localizedCaseInsensitiveCompare(option.tag.name) == .orderedSame }
                            Button { toggle(option.tag) } label: {
                                Label(option.tag.name, systemImage: option.tag.symbol)
                                    .font(.subheadline.weight(.semibold)).padding(.horizontal, 16).frame(height: 44)
                                    .background(selected ? Color.white : Color.white.opacity(0.09), in: Capsule())
                                    .foregroundStyle(selected ? .black : .white)
                            }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                    if canAddCustom {
                        Button {
                            let tag = SoundTag(name: trimmedSearch, symbol: section.symbol, category: section.storedCategory)
                            customSounds.append(PickerSound(section: section, tag: tag))
                            selection.append(tag)
                            search = ""; searchFocused = false
                        } label: {
                            Label("Add \"\(trimmedSearch)\"", systemImage: "plus.circle.fill")
                                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                                .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain).accessibilityIdentifier("add-custom-sound")
                    } else if !trimmedSearch.isEmpty, let match = matchingSound, match.section != section {
                        Text("\(match.tag.name) is in \(match.section.rawValue).")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else if options.isEmpty {
                        Text(section == .voice ? "Choose vocals or instrumental." : "No sounds found.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding()
                    }
                    if trimmedSearch.count > 24 {
                        Text("Keep a custom sound to 24 characters or fewer.").font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding(22)
            }
            .background(Color(white: 0.12))
            .navigationTitle("Shape your sound").vibeInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        player.updateSelected { $0.tags = selection }
                        if let data = try? JSONEncoder().encode(customSounds) { UserDefaults.standard.set(data, forKey: customKey) }
                        dismiss()
                    }.bold()
                }
            }
        }
        .onAppear {
            selection = player.selected.tags
            if let data = UserDefaults.standard.data(forKey: customKey), let saved = try? JSONDecoder().decode([PickerSound].self, from: data) { customSounds = saved }
        }
        .vibePickerPresentation()
    }
    private func toggle(_ tag: SoundTag) {
        if selection.contains(where: { $0.name.localizedCaseInsensitiveCompare(tag.name) == .orderedSame }) {
            selection.removeAll { $0.name.localizedCaseInsensitiveCompare(tag.name) == .orderedSame }
        } else {
            if tag.category == .voice { selection.removeAll { $0.category == .voice } }
            selection.append(tag)
        }
    }
}
