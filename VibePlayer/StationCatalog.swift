import Foundation

struct SoundTag: Identifiable, Codable, Equatable {
    var id: String { name }
    var name: String
    var symbol: String
    var category: TagCategory
    var intensity: Double = 0.7
}

enum TagCategory: String, CaseIterable, Codable, Identifiable {
    case genre = "Genres", mood = "Moods", instrument = "Instruments", voice = "Voice", language = "Language"
    var id: String { rawValue }
}

struct Vibe: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var subtitle: String
    var tags: [SoundTag]
    var tempo: Double
    var palette: Int
    var catalogID: String? = nil
    var soundDescription: String? = nil
    var musicProfile: MusicProfile {
        MusicProfile(name: name, traits: tags.map { tag in
            let category: MusicProfile.Category
            switch tag.category {
            case .genre: category = .genre
            case .mood: category = .mood
            case .instrument: category = .instrument
            case .voice: category = .voice
            case .language: category = .language
            }
            return .init(name: tag.name, category: category, intensity: tag.intensity)
        }, tempo: tempo, soundDescription: soundDescription)
    }
    var prompt: String { MusicPromptBuilder().makeRequest(profile: musicProfile, seed: 0).style }
}

let vocalLanguages = ["English", "German", "French", "Italian", "Spanish", "Portuguese", "Mandarin Chinese", "Japanese", "Korean"]

let tagOptions: [SoundTag] = [
    .init(name: "Boom bap", symbol: "headphones", category: .genre),
    .init(name: "Lo-fi", symbol: "waveform.path", category: .genre),
    .init(name: "Indie pop", symbol: "sparkles", category: .genre),
    .init(name: "Pop", symbol: "star.fill", category: .genre),
    .init(name: "Hip-hop", symbol: "headphones", category: .genre),
    .init(name: "Electronic", symbol: "waveform", category: .genre),
    .init(name: "Jazz", symbol: "music.note", category: .genre),
    .init(name: "Ambient", symbol: "cloud.fill", category: .genre),
    .init(name: "Cinematic", symbol: "film", category: .genre),
    .init(name: "Mellow", symbol: "sun.haze.fill", category: .mood),
    .init(name: "Euphoric", symbol: "sun.max.fill", category: .mood),
    .init(name: "Dreamy", symbol: "cloud.moon.fill", category: .mood),
    .init(name: "Focused", symbol: "scope", category: .mood),
    .init(name: "Melancholic", symbol: "cloud.rain.fill", category: .mood),
    .init(name: "Energetic", symbol: "bolt.fill", category: .mood),
    .init(name: "Piano", symbol: "pianokeys", category: .instrument),
    .init(name: "Synth", symbol: "waveform.path", category: .instrument),
    .init(name: "Guitar", symbol: "guitars", category: .instrument),
    .init(name: "Drums", symbol: "metronome.fill", category: .instrument),
    .init(name: "Bass", symbol: "waveform", category: .instrument),
    .init(name: "Handclaps", symbol: "hands.clap.fill", category: .instrument),
    .init(name: "Instrumental", symbol: "mic.slash.fill", category: .voice),
    .init(name: "Vocals", symbol: "mic.fill", category: .voice)
] + vocalLanguages.map { SoundTag(name: $0, symbol: "globe", category: .language) }

enum StationCategory: String, CaseIterable, Identifiable {
    case christmas = "Christmas"
    case workout = "Workout"
    case focus = "Focus"
    case chill = "Chill"
    case pop = "Pop"
    case nightlife = "Nightlife"
    case jazzAndSoul = "Jazz & Soul"
    case cinematic = "Cinematic"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .christmas: "snowflake"
        case .workout: "bolt.fill"
        case .focus: "scope"
        case .chill: "moon.stars"
        case .pop: "sparkles"
        case .nightlife: "moon.haze.fill"
        case .jazzAndSoul: "pianokeys"
        case .cinematic: "film"
        }
    }

    var palette: Int {
        switch self {
        case .christmas: 3
        case .workout: 4
        case .focus: 5
        case .chill: 6
        case .pop: 7
        case .nightlife: 8
        case .jazzAndSoul: 9
        case .cinematic: 10
        }
    }
}

struct StationPreset {
    let id: String
    let name: String
    let category: StationCategory
    let subtitle: String
    let symbol: String
    let tempo: Double
    let tags: [SoundTag]
    let description: String?
    let legacyPalette: Int?

    fileprivate init(_ id: String, _ name: String, _ category: StationCategory, _ subtitle: String,
                     _ symbol: String, _ tempo: Double, genres: [String], moods: [String],
                     instruments: [String] = [], vocals: Bool = false, description: String? = nil,
                     legacyPalette: Int? = nil) {
        self.id = id
        self.name = name
        self.category = category
        self.subtitle = subtitle
        self.symbol = symbol
        self.tempo = tempo
        self.description = description
        self.legacyPalette = legacyPalette
        func tags(_ names: [String], category: TagCategory, symbol: String) -> [SoundTag] {
            names.map { name in
                tagOptions.first { $0.name == name && $0.category == category }
                    ?? SoundTag(name: name, symbol: symbol, category: category)
            }
        }
        self.tags = tags(genres, category: .genre, symbol: "music.note")
            + tags(moods, category: .mood, symbol: "sparkles")
            + tags(instruments, category: .instrument, symbol: "waveform")
            + tags(vocals ? ["Vocals"] : ["Instrumental"], category: .voice, symbol: "mic")
    }

    var station: Vibe {
        Vibe(name: name, subtitle: subtitle, tags: tags, tempo: tempo, palette: legacyPalette ?? category.palette,
             catalogID: id, soundDescription: description)
    }
}

enum StationCatalog {
    static let presets: [StationPreset] = [
        .init("lofi-beats", "Lofi Beats", .chill, "Lo-fi · Mellow", "headphones", 78,
              genres: ["Lo-fi", "Boom bap"], moods: ["Mellow"], legacyPalette: 0),
        .init("joyful-pop", "Joyful Pop", .pop, "Pop · Euphoric", "sun.max.fill", 112,
              genres: ["Indie pop", "Pop"], moods: ["Euphoric"], instruments: ["Piano"], vocals: true, legacyPalette: 1),
        .init("christmas-morning", "Christmas Morning", .christmas, "Holiday pop · Sleigh bells", "gift.fill", 112,
              genres: ["Christmas pop"], moods: ["Joyful", "Nostalgic"], instruments: ["Sleigh bells", "Piano"], vocals: true,
              description: "Original holiday songs about waking up to Christmas, gathering with family, and winter traditions."),
        .init("power-hour", "Power Hour", .workout, "Electro house · Strength", "bolt.fill", 132,
              genres: ["Electro house"], moods: ["Powerful", "Energetic"], instruments: ["Synth", "Punchy kick"]),
        .init("deep-focus", "Deep Focus", .focus, "Ambient · Focused", "scope", 90,
              genres: ["Ambient"], moods: ["Focused"], instruments: ["Synth"], legacyPalette: 2),
        .init("after-hours", "After Hours", .nightlife, "Electronic · Dreamy", "moon.haze.fill", 105,
              genres: ["Electronic"], moods: ["Dreamy"], instruments: ["Synth", "Bass"], vocals: true, legacyPalette: 1),
        .init("golden-hour", "Golden Hour", .jazzAndSoul, "Jazz · Mellow", "sun.horizon.fill", 88,
              genres: ["Jazz"], moods: ["Mellow"], instruments: ["Piano"], legacyPalette: 0),
        .init("big-skies", "Big Skies", .cinematic, "Cinematic · Euphoric", "mountain.2.fill", 110,
              genres: ["Cinematic"], moods: ["Euphoric"], instruments: ["Drums"], legacyPalette: 2),

        .init("christmas-jazz", "Christmas Jazz", .christmas, "Swing trio · Fireside", "pianokeys", 98,
              genres: ["Christmas jazz", "Swing"], moods: ["Cozy"], instruments: ["Piano", "Upright bass", "Brush drums"]),
        .init("snowfall-piano", "Snowfall Piano", .christmas, "Solo piano · First snow", "snowflake", 63,
              genres: ["Holiday piano"], moods: ["Tender", "Peaceful"], instruments: ["Solo felt piano"]),
        .init("soulful-christmas", "Soulful Christmas", .christmas, "Soul · Gospel harmonies", "hands.clap.fill", 94,
              genres: ["Christmas soul", "Gospel"], moods: ["Warm", "Jubilant"], instruments: ["Organ", "Tambourine"], vocals: true,
              description: "Original Christmas lyrics about coming home and finding joy together, with call-and-response harmonies."),
        .init("winter-lodge", "Winter Lodge", .christmas, "Acoustic folk · Fireside", "flame.fill", 76,
              genres: ["Christmas folk"], moods: ["Warm", "Rustic"], instruments: ["Acoustic guitar", "Fiddle"], vocals: true,
              description: "Original winter holiday stories about a snowy cabin, evergreen trees, and old friends."),
        .init("candlelight-carols", "Candlelight Carols", .christmas, "Chamber choir · Carols", "candle.fill", 72,
              genres: ["Traditional Christmas carol", "Chamber choir"], moods: ["Reverent", "Serene"], instruments: ["Pipe organ"], vocals: true,
              description: "Original carol lyrics about candlelit windows and a quiet Christmas night, with four-part harmonies."),
        .init("tinsel-disco", "Tinsel Disco", .christmas, "Holiday disco · Dance party", "sparkles", 120,
              genres: ["Christmas disco"], moods: ["Playful", "Festive"], instruments: ["Funky bass", "Disco strings", "Sleigh bells"], vocals: true,
              description: "Original, playful lyrics about holiday lights and a Christmas dance party."),

        .init("runners-high", "Runner’s High", .workout, "Liquid drum & bass · Fast runs", "figure.run", 174,
              genres: ["Liquid drum and bass"], moods: ["Flowing", "Uplifting"], instruments: ["Breakbeats", "Sub bass"]),
        .init("heavy-reps", "Heavy Reps", .workout, "Trap · Lifting", "dumbbell.fill", 144,
              genres: ["Trap", "Workout hip-hop"], moods: ["Intense", "Swaggering"], instruments: ["808 bass", "Hi-hat rolls"]),
        .init("sprint-finish", "Sprint Finish", .workout, "Hard techno · Sprints", "timer", 150,
              genres: ["Hard techno"], moods: ["Relentless", "Urgent"], instruments: ["Distorted kick", "Acid synth"]),
        .init("spin-class", "Spin Class", .workout, "Progressive trance · Cycling", "bicycle", 138,
              genres: ["Progressive trance"], moods: ["Driving", "Euphoric"], instruments: ["Arpeggiated synth", "Four-on-the-floor drums"]),
        .init("boxing-rounds", "Boxing Rounds", .workout, "Breakbeat · Intervals", "figure.boxing", 126,
              genres: ["Breakbeat", "Funk"], moods: ["Punchy", "Focused"], instruments: ["Chopped drums", "Brass stabs"]),
        .init("cooldown", "Cooldown", .workout, "Organic downtempo · Recovery", "figure.cooldown", 82,
              genres: ["Organic downtempo"], moods: ["Grounded", "Restorative"], instruments: ["Handpan", "Soft shaker", "Warm pads"]),

        .init("study-hall", "Study Hall", .focus, "Chillhop · Reading", "book.fill", 78,
              genres: ["Chillhop"], moods: ["Steady", "Unhurried"], instruments: ["Rhodes", "Soft drums"]),
        .init("code-flow", "Code Flow", .focus, "Minimal electronica · Coding", "chevron.left.forwardslash.chevron.right", 106,
              genres: ["Minimal electronica"], moods: ["Precise", "Focused"], instruments: ["Analog sequencer", "Muted kick"]),
        .init("library-piano", "Library Piano", .focus, "Minimal piano · Writing", "pianokeys", 66,
              genres: ["Minimal classical"], moods: ["Reflective", "Quiet"], instruments: ["Felt piano"]),
        .init("still-water", "Still Water", .focus, "Deep ambient · Meditation", "water.waves", 50,
              genres: ["Ambient drone"], moods: ["Still", "Meditative"], instruments: ["Slow synth pads", "Bowed glass"]),
        .init("white-pages", "White Pages", .focus, "Ambient guitar · Reading", "text.alignleft", 72,
              genres: ["Ambient guitar"], moods: ["Spacious", "Gentle"], instruments: ["Clean guitar", "Tape delay"]),
        .init("quiet-hours", "Quiet Hours", .focus, "Drone · Deep work", "hourglass", 55,
              genres: ["Warm drone"], moods: ["Hypnotic", "Steady"], instruments: ["Slow organ", "Analog pads"]),

        .init("rainy-window", "Rainy Window", .chill, "Tape lo-fi · Slow afternoon", "cloud.rain.fill", 72,
              genres: ["Tape lo-fi"], moods: ["Rainy", "Melancholic"], instruments: ["Rhodes", "Dusty drums"]),
        .init("slow-mornings", "Slow Mornings", .chill, "Acoustic indie · Gentle", "cup.and.saucer.fill", 80,
              genres: ["Acoustic indie"], moods: ["Warm", "Intimate"], instruments: ["Fingerpicked guitar", "Brushed snare"], vocals: true),
        .init("coastline", "Coastline", .chill, "Balearic · Seaside", "sailboat.fill", 102,
              genres: ["Balearic chill"], moods: ["Sunlit", "Breezy"], instruments: ["Nylon guitar", "Congas"]),
        .init("dream-drift", "Dream Drift", .chill, "Dream pop · Soft vocals", "cloud.moon.fill", 84,
              genres: ["Dream pop"], moods: ["Hazy", "Bittersweet"], instruments: ["Shimmer guitar", "Synth pads"], vocals: true),
        .init("ocean-sleep", "Ocean Sleep", .chill, "Ambient · Sleep", "moon.zzz.fill", 54,
              genres: ["Sleep ambient"], moods: ["Calm", "Weightless"], instruments: ["Soft pads", "Distant wave textures"]),
        .init("porch-light", "Porch Light", .chill, "Americana · Evening", "guitars", 74,
              genres: ["Instrumental Americana"], moods: ["Nostalgic", "Easygoing"], instruments: ["Pedal steel", "Acoustic guitar"]),

        .init("indie-weekend", "Indie Weekend", .pop, "Indie rock · Road trip", "car.fill", 124,
              genres: ["Indie rock", "Power pop"], moods: ["Carefree", "Bright"], instruments: ["Jangly guitar", "Live drums"], vocals: true),
        .init("neon-kisses", "Neon Kisses", .pop, "Synth-pop · ’80s glow", "heart.fill", 118,
              genres: ["Eighties synth-pop"], moods: ["Romantic", "Nostalgic"], instruments: ["Analog synth", "Gated drums"], vocals: true),
        .init("sunshine-pop", "Sunshine Pop", .pop, "Tropical pop · Summer", "sun.haze.fill", 106,
              genres: ["Tropical pop"], moods: ["Sunny", "Playful"], instruments: ["Steel drums", "Handclaps"], vocals: true),
        .init("heart-on-sleeve", "Heart on Sleeve", .pop, "Piano pop · Ballads", "heart.text.square.fill", 68,
              genres: ["Piano ballad"], moods: ["Vulnerable", "Bittersweet"], instruments: ["Grand piano", "Strings"], vocals: true),
        .init("glow-up", "Glow Up", .pop, "Dance-pop · Big hooks", "star.fill", 126,
              genres: ["Dance-pop"], moods: ["Confident", "Celebratory"], instruments: ["Synth bass", "Handclaps"], vocals: true),

        .init("midnight-drive", "Midnight Drive", .nightlife, "Synthwave · Night drive", "road.lanes", 108,
              genres: ["Synthwave"], moods: ["Nocturnal", "Nostalgic"], instruments: ["Analog bass", "Retro drum machine"]),
        .init("warehouse", "Warehouse", .nightlife, "Deep techno · Late set", "speaker.wave.2.fill", 130,
              genres: ["Deep techno"], moods: ["Hypnotic", "Dark"], instruments: ["Rumbling kick", "Dub chords"]),
        .init("velvet-rope", "Velvet Rope", .nightlife, "Deep house · Warm bass", "record.circle", 122,
              genres: ["Deep house"], moods: ["Slinky", "Warm"], instruments: ["Rhodes", "Rounded bassline"]),
        .init("mirrorball", "Mirrorball", .nightlife, "Nu-disco · Dance floor", "circle.hexagongrid.fill", 117,
              genres: ["Nu-disco"], moods: ["Flirtatious", "Effervescent"], instruments: ["Funk guitar", "Disco strings"], vocals: true),
        .init("basement-garage", "Basement Garage", .nightlife, "UK garage · Two-step", "waveform", 134,
              genres: ["UK garage", "Two-step"], moods: ["Bouncy", "Lively"], instruments: ["Syncopated drums", "Sub bass", "Chopped vocal textures"]),

        .init("blue-note", "Blue Note", .jazzAndSoul, "Bebop · Small combo", "music.note", 148,
              genres: ["Bebop"], moods: ["Lively", "Improvisational"], instruments: ["Tenor saxophone", "Upright bass", "Ride cymbal"]),
        .init("sunday-soul", "Sunday Soul", .jazzAndSoul, "Classic soul · Warm brass", "sun.max.fill", 92,
              genres: ["Classic soul"], moods: ["Warm", "Hopeful"], instruments: ["Hammond organ", "Brass"], vocals: true),
        .init("bossa-balcony", "Bossa Balcony", .jazzAndSoul, "Bossa nova · Easy afternoon", "leaf.fill", 98,
              genres: ["Bossa nova"], moods: ["Relaxed", "Breezy"], instruments: ["Nylon guitar", "Upright bass", "Shaker"]),
        .init("velvet-rnb", "Velvet R&B", .jazzAndSoul, "Neo-soul · Late evening", "mic.fill", 82,
              genres: ["Neo-soul", "Contemporary R&B"], moods: ["Intimate", "Smooth"], instruments: ["Rhodes", "Pocket drums"], vocals: true),

        .init("first-light", "First Light", .cinematic, "Orchestral · Dawn", "sunrise.fill", 78,
              genres: ["Orchestral score"], moods: ["Hopeful", "Expansive"], instruments: ["Legato strings", "French horns", "Harp"]),
        .init("deep-space", "Deep Space", .cinematic, "Space ambient · Sci-fi", "sparkle", 58,
              genres: ["Science fiction score", "Space ambient"], moods: ["Mysterious", "Weightless"], instruments: ["Granular synth", "Low drones"]),
        .init("chase-scene", "Chase Scene", .cinematic, "Action score · Tension", "forward.end.fill", 142,
              genres: ["Hybrid action score"], moods: ["Tense", "Urgent"], instruments: ["Staccato strings", "Taiko drums", "Brass"]),
        .init("end-credits", "End Credits", .cinematic, "Chamber score · Reflection", "theatermasks.fill", 69,
              genres: ["Chamber film score"], moods: ["Wistful", "Resolute"], instruments: ["Piano", "Solo cello"])
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0) })

    static func preset(for station: Vibe) -> StationPreset? {
        station.catalogID.flatMap { byID[$0] }
    }

    static func merging(_ saved: [Vibe]) -> [Vibe] {
        var remaining = saved
        let builtIn = presets.map { preset -> Vibe in
            let index = remaining.firstIndex { $0.catalogID == preset.id }
                ?? remaining.firstIndex {
                    preset.legacyPalette != nil && $0.catalogID == nil
                        && $0.name == preset.name && $0.subtitle == preset.subtitle
                }
            guard let index else { return preset.station }
            var station = remaining.remove(at: index)
            station.catalogID = preset.id
            if preset.id == "lofi-beats", station.tempo == 78,
               station.tags.map(\.name) == ["Lo-fi", "Mellow", "Piano", "Instrumental"],
               station.tags.allSatisfy({ abs($0.intensity - 0.7) < 0.001 }) {
                station.tags = preset.tags
            }
            return station
        }
        return builtIn + remaining
    }

    static func matches(_ station: Vibe, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let fields = [station.name, station.subtitle, preset(for: station)?.category.rawValue ?? "",
                      station.soundDescription ?? ""] + station.tags.map(\.name)
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { word in
            fields.contains { $0.localizedStandardContains(String(word)) }
        }
    }
}
