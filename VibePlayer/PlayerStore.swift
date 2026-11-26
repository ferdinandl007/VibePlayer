import SwiftUI
import AVFoundation
import MediaPlayer
import Synchronization
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

struct SoundTag: Identifiable, Codable, Equatable {
    var id: String { name }
    var name: String
    var symbol: String
    var category: TagCategory
    var intensity: Double = 0.7
}

enum TagCategory: String, CaseIterable, Codable, Identifiable {
    case genre = "Genres", mood = "Moods", instrument = "Instruments", voice = "Voice"
    var id: String { rawValue }
}

struct Vibe: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var subtitle: String
    var tags: [SoundTag]
    var tempo: Double
    var palette: Int
    var musicProfile: MusicProfile {
        MusicProfile(name: name, traits: tags.map { tag in
            let category: MusicProfile.Category
            switch tag.category {
            case .genre: category = .genre
            case .mood: category = .mood
            case .instrument: category = .instrument
            case .voice: category = .voice
            }
            return .init(name: tag.name, category: category, intensity: tag.intensity)
        }, tempo: tempo)
    }
    var prompt: String { MusicPromptBuilder().makeRequest(profile: musicProfile, seed: 0).style }
}

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
]

struct SongIdea: Identifiable, Codable {
    var id = UUID()
    var title: String
    var prompt: String
    var styles: String? = nil
    var lyrics: String? = nil
    var instrumental: Bool? = nil
    var createdAt = Date()
}

struct SavedSong: Identifiable, Codable {
    let id: UUID
    let title: String
    let filename: String
    let style: String
    let lyrics: String
    let createdAt: Date
    var semanticFilename: String?
}

private struct GeneratedTrack {
    let url: URL
    let request: MusicGenerationRequest
    var duration: TimeInterval = 0
    var semanticTokens: [Int] = []
    var continuesRadioSeed: UInt64?
}

struct CreationJob: Identifiable {
    let id = UUID()
    let idea: String
    let styles: String
    let lyrics: String?
    let instrumental: Bool
    let renderer: CreateRenderer
    let length: CreateLength
    let acoustics: CreateAcoustics
    let reference: MusicReference?
    var title: String { idea.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ") }
}

struct RadioQueueItem: Identifiable {
    let id: UInt64
    let station: String
    let duration: TimeInterval
}

enum RadioRenderStage {
    case preparing, lyrics, composing(frames: Int), rendering(step: Int, total: Int), finishing

    var title: String {
        switch self {
        case .preparing: "Preparing song"
        case .lyrics: "Writing lyrics"
        case .composing: "Composing"
        case .rendering: "Rendering audio"
        case .finishing: "Finishing audio"
        }
    }

    var detail: String? {
        switch self {
        case .composing(let frames):
            frames > 0 ? "\(frames / 25 / 60):\(String(format: "%02d", frames / 25 % 60)) composed" : nil
        case .rendering(let step, let total): "Step \(step) of \(total)"
        default: nil
        }
    }

    var phase: Int {
        switch self {
        case .preparing, .lyrics: 0
        case .composing: 1
        case .rendering: 2
        case .finishing: 3
        }
    }
}

// The producer writes PCM once, then publishes the end frame to the audio thread.
final class PreviewPCM: @unchecked Sendable {
    static let sampleRate = 48_000
    static let reserve = sampleRate * 3 / 4
    static let fade = sampleRate / 80

    private let samples: UnsafeMutablePointer<Int16>
    private let capacity: Int
    let written = Atomic<Int>(0)
    let played = Atomic<Int>(0)
    let complete = Atomic<Bool>(false)
    let wantsPlayback = Atomic<Bool>(false)
    let needsBuffer = Atomic<Bool>(false)

    // These variables belong to the engine's render thread.
    private var cursor = 0
    private var gain: Float = 0

    init(capacity: Int) {
        self.capacity = capacity
        samples = .allocate(capacity: capacity * 2)
    }

    deinit { samples.deallocate() }

    func sourceNode(format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { [self] silence, _, frames, output in
            let buffers = UnsafeMutableAudioBufferListPointer(output)
            guard buffers.count == 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return kAudio_ParamError }
            silence.pointee = ObjCBool(!render(Int(frames), left: left, right: right))
            return noErr
        }
    }

    @MainActor
    func append(_ input: UnsafeBufferPointer<Int16>, at start: Int) throws {
        let count = input.count / 2
        guard count > 0, input.count.isMultiple(of: 2), let address = input.baseAddress,
              start == written.load(ordering: .relaxed), count <= capacity - start else {
            throw MusicGenerationError.unavailable
        }
        (samples + start * 2).initialize(from: address, count: input.count)
        written.store(start + count, ordering: .releasing)
    }

    func render(_ count: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Bool {
        let finished = complete.load(ordering: .acquiring)
        let available = written.load(ordering: .acquiring)
        let requested = wantsPlayback.load(ordering: .acquiring)
        if requested, !finished, available - cursor <= Self.reserve {
            needsBuffer.store(true, ordering: .releasing)
        }
        let running = requested && !needsBuffer.load(ordering: .acquiring)
        let ramp = 1 / Float(Self.fade)
        var wroteAudio = false
        for frame in 0..<count {
            gain = running ? min(1, gain + ramp) : max(0, gain - ramp)
            if cursor < available, running || gain > 0 {
                let amplitude = gain / 32768
                left[frame] = Float(samples[cursor * 2]) * amplitude
                right[frame] = Float(samples[cursor * 2 + 1]) * amplitude
                cursor += 1
                wroteAudio = true
            } else {
                left[frame] = 0
                right[frame] = 0
            }
        }
        played.store(cursor, ordering: .releasing)
        return wroteAudio
    }
}

@MainActor @Observable
private final class PreviewPlayback {
    private let engine = AVAudioEngine()
    private let pcm: PreviewPCM
    private let acoustics: CreateAcoustics
    private let lowLatency: Bool
    private(set) var bufferedDuration: TimeInterval = 0
    private var lastChunk: ContinuousClock.Instant?
    private var renderRate = 1.0
    private var hasStarted = false
    private var endObservedAt: ContinuousClock.Instant?

    init(_ preview: MusicAudioPreview, acoustics: CreateAcoustics) throws {
        let rate = Double(PreviewPCM.sampleRate)
        guard (1...PreviewPCM.sampleRate * 300).contains(preview.totalFrames),
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            throw MusicGenerationError.unavailable
        }
        let pcm = PreviewPCM(capacity: preview.totalFrames)
        self.pcm = pcm
        self.acoustics = acoustics
        self.lowLatency = preview.lowLatency
        let node = pcm.sourceNode(format: format)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try append(preview)
    }

    func append(_ preview: MusicAudioPreview) throws {
        try preview.samples.withUnsafeBufferPointer { try pcm.append($0, at: preview.startFrame) }
        let now = ContinuousClock.now
        if let lastChunk, acoustics == .streaming || lowLatency {
            let audio = Double(preview.samples.count / 2) / Double(PreviewPCM.sampleRate)
            let delta = lastChunk.duration(to: now).components
            let measured = min(2.5, (Double(delta.seconds) + Double(delta.attoseconds) / 1e18) / audio)
            renderRate = 0.40 * renderRate + 0.60 * measured
        }
        lastChunk = now
        bufferedDuration = Double(pcm.written.load(ordering: .relaxed)) / Double(PreviewPCM.sampleRate)
    }

    var elapsed: TimeInterval {
        Double(pcm.played.load(ordering: .acquiring)) / Double(PreviewPCM.sampleRate)
    }

    var needsBuffer: Bool { pcm.needsBuffer.load(ordering: .acquiring) }

    var readyToPlay: Bool {
        if pcm.complete.load(ordering: .acquiring) { return true }
        let available = bufferedDuration - elapsed
        if hasStarted, !needsBuffer { return available >= 1.5 }
        if lowLatency {
            let reserve = hasStarted ? 5 + min(9, max(0, (renderRate - 1) * 12)) : 2.5
            return available >= reserve
        }
        // Whole-song synthesis is already complete when these PCM tiles arrive.
        if acoustics != .streaming { return available >= 7.5 }
        let minimum = hasStarted ? 28.0 : 24.0
        let additional = min(18, max(0, (renderRate - 1) * 60))
        return available >= minimum + additional
    }

    var hasEnded: Bool {
        guard pcm.complete.load(ordering: .acquiring), elapsed >= bufferedDuration else { return false }
        let now = ContinuousClock.now
        guard let endObservedAt else { self.endObservedAt = now; return false }
        return endObservedAt.duration(to: now) >= .seconds(max(0.15, engine.outputNode.presentationLatency))
    }

    func play() throws {
        if !engine.isRunning { try engine.start() }
        hasStarted = true
        pcm.needsBuffer.store(false, ordering: .releasing)
        pcm.wantsPlayback.store(true, ordering: .releasing)
    }

    func pause() { pcm.wantsPlayback.store(false, ordering: .releasing) }

    func stop() { pause(); engine.stop() }

    func appendRemainder(at url: URL) throws {
        let source = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let start = pcm.written.load(ordering: .relaxed)
        guard source.length >= start, source.processingFormat.channelCount == 2,
              source.processingFormat.sampleRate == Double(PreviewPCM.sampleRate),
              let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 16_384) else {
            throw MusicGenerationError.unavailable
        }
        source.framePosition = AVAudioFramePosition(start)
        while source.framePosition < source.length {
            let offset = Int(source.framePosition)
            try source.read(into: buffer)
            guard let samples = buffer.int16ChannelData?[0] else { throw MusicGenerationError.unavailable }
            try pcm.append(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength) * 2), at: offset)
        }
        bufferedDuration = Double(source.length) / Double(PreviewPCM.sampleRate)
        pcm.complete.store(true, ordering: .releasing)
    }
}

@MainActor @Observable
final class PlayerStore: NSObject, AVAudioPlayerDelegate {
    var vibes: [Vibe] = []
    var songIdeas: [SongIdea] = []
    private(set) var savedSongs: [SavedSong] = []
    private var currentTrack: GeneratedTrack?
    private var radioQueue: [GeneratedTrack] = []
    private var preparedRadioSeed: UInt64?
    private var radioReserve: GeneratedTrack?
    private let radioQueueCapacity = 2
    private var currentSavedID: UUID?
    private(set) var radioMode = true
    private var radioWantsPlayback = false
    private var radioPreloading = false
    private var replaceWhenReady = false
    private var isEditingRadio = false
    private var radioTrackEnded = false
    private var radioCanRetry = true
    private var radioContinuation: (seed: UInt64, prefix: [Int], minimumFrames: Int, lyrics: String)?
    var remixSource: MusicReference?
    private var fadingPlayer: AVAudioPlayer?
    private var fadeTask: Task<Void, Never>?
    var selectedID: UUID?
    var isPlaying = false
    var audioLevel: Double = 0
    var beatPulse = false
    private var smoothedLevel: Double = 0
    private var lastBeat = Date.distantPast
    var elapsed: TimeInterval = 0
    var duration: TimeInterval = 0
    var trackName = "A little atmosphere"
    private(set) var trackArtist: String?
    private(set) var trackArtwork: PlatformImage?
    private var artworkTask: Task<Void, Never>?
    private var artworkRequestID = UUID()
    var isSample = true
    private(set) var isGenerated = false
    private(set) var isGenerating = false
    private(set) var isWritingLyrics = false
    private(set) var isCreating = false
    private(set) var generationProgress = 0.0
    private(set) var radioRenderStage: RadioRenderStage = .preparing
    private(set) var creationStatus = ""
    private(set) var creationNotice: String?
    private(set) var activeCreation: CreationJob?
    private(set) var queuedCreations: [CreationJob] = []
    private(set) var lastCreatedSong: SavedSong?
    private var creationAutoplay = false
    private(set) var isBufferingPreview = false
    var canGenerate: Bool { generationBackend.isAvailable }
    var canUsePairedMetal: Bool { generationBackend.canUsePairedMetal }
    var canStreamAcoustics: Bool { generationBackend.canStreamAcoustics }
    var canFastFullSong: Bool { generationBackend.canFastFullSong }
    func prepareEarlyPlayback() { generationBackend.prepareEarlyPlayback() }
    var canCreateExtended: Bool { generationBackend.canCreateExtended }
    var radioReadyCount: Int { radioQueue.count }
    var radioReadyTracks: [RadioQueueItem] {
        radioQueue.map { RadioQueueItem(id: $0.request.seed, station: $0.request.stationName, duration: $0.duration) }
    }
    var isWaitingForRadio: Bool { radioMode && radioWantsPlayback && !isPlaying }
    var shouldKeepScreenAwake: Bool { isCreating || isWaitingForRadio || (radioPreloading && !isPlaying && isGenerating) }
    var radioLoadingMessage: String? {
        guard radioMode, canGenerate, !isCreating,
              isWaitingForRadio || isGenerating || isEditingRadio || automaticGenerationTask != nil else { return nil }
        if replaceWhenReady, isGenerated || isEditingRadio { return "Updating your sound…" }
        return isGenerated ? "Preparing the next song…" : "Preparing your station…"
    }
    var wantsPlayback: Bool { isPlaying || isWaitingForRadio }
    var errorMessage: String?
    var liked = false
    var disliked = false
    var sleepMinutes: Int?
    private var sleepTimer: Timer?
    var savedIDs: Set<UUID> = []
    private var audio: AVAudioPlayer?
    private var previewPlayer: PreviewPlayback?
    private var previewGenerationID: UUID?
    var canSeek: Bool { duration > 0 && previewGenerationID == nil }
    var isPlayingPreview: Bool { previewGenerationID != nil && isPlaying && !isBufferingPreview }
    var hasCreationPreview: Bool { previewGenerationID != nil }
    var creationBufferedDuration: TimeInterval { hasCreationPreview ? previewPlayer?.bufferedDuration ?? 0 : 0 }
    var isPlayingLastCreatedSong: Bool { lastCreatedSong?.id != nil && currentSavedID == lastCreatedSong?.id && isPlaying }
    private var timer: Timer?
    private let defaultsKey = "vibe-player-vibes-v1"
    private let generationBackend: any MusicGenerationBackend
    private let lyricsWriter: any LyricsWriter
    private var generationTask: Task<Void, Never>?
    private var automaticGenerationTask: Task<Void, Never>?
    private var generationID: UUID?

    var selectedIndex: Int { vibes.firstIndex(where: { $0.id == selectedID }) ?? 0 }
    var selected: Vibe { vibes[selectedIndex] }

    override convenience init() { self.init(generationBackend: UnavailableMusicGenerationBackend(), lyricsWriter: GeminiLyricsWriter()) }

    convenience init(generationBackend: any MusicGenerationBackend) {
        self.init(generationBackend: generationBackend, lyricsWriter: GeminiLyricsWriter())
    }

    init(generationBackend: any MusicGenerationBackend, lyricsWriter: any LyricsWriter) {
        self.generationBackend = generationBackend
        self.lyricsWriter = lyricsWriter
        super.init()
        // Unkept radio renders never need to survive a previous app session.
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("VibePlayerSongs", isDirectory: true))
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            for key in [defaultsKey, "vibe-player-song-ideas", "saved-vibes", "imported-audio-filename", "imported-audio-name",
                        "vibe-player-saved-songs", "vibe-create-acoustics"] { UserDefaults.standard.removeObject(forKey: key) }
        }
        if let data = UserDefaults.standard.data(forKey: defaultsKey), let saved = try? JSONDecoder().decode([Vibe].self, from: data), !saved.isEmpty {
            vibes = saved
        } else {
            func tags(_ names: [String]) -> [SoundTag] { names.compactMap { name in tagOptions.first { $0.name == name } } }
            vibes = [
                Vibe(name: "Lofi Beats", subtitle: "Lo-fi · Mellow", tags: tags(["Lo-fi", "Boom bap", "Instrumental", "Mellow"]), tempo: 78, palette: 0),
                Vibe(name: "Joyful Pop", subtitle: "Pop · Euphoric", tags: tags(["Indie pop", "Pop", "Euphoric", "Piano"]), tempo: 112, palette: 1),
                Vibe(name: "Deep Focus", subtitle: "Ambient · Focused", tags: tags(["Ambient", "Focused", "Synth", "Instrumental"]), tempo: 90, palette: 2)
            ]
        }
        // Upgrade the original unedited Lo-fi preset while preserving customized stations.
        if let index = vibes.firstIndex(where: { $0.name == "Lofi Beats" }),
           vibes[index].tags.map(\.name) == ["Lo-fi", "Mellow", "Piano", "Instrumental"],
           vibes[index].tags.allSatisfy({ abs($0.intensity - 0.7) < 0.001 }),
           vibes[index].tempo == 78 {
            let names = ["Lo-fi", "Boom bap", "Instrumental", "Mellow"]
            vibes[index].tags = names.compactMap { name in tagOptions.first { $0.name == name } }
        }
        // Keep existing station edits while adding new default stations on upgrade.
        func extraTags(_ names: [String]) -> [SoundTag] { names.compactMap { name in tagOptions.first { $0.name == name } } }
        let extraStations = [
            Vibe(name: "After Hours", subtitle: "Electronic · Dreamy", tags: extraTags(["Electronic", "Dreamy", "Synth", "Bass"]), tempo: 105, palette: 1),
            Vibe(name: "Golden Hour", subtitle: "Jazz · Mellow", tags: extraTags(["Jazz", "Mellow", "Piano", "Instrumental"]), tempo: 88, palette: 0),
            Vibe(name: "Big Skies", subtitle: "Cinematic · Euphoric", tags: extraTags(["Cinematic", "Euphoric", "Drums", "Instrumental"]), tempo: 110, palette: 2)
        ]
        for station in extraStations where !vibes.contains(where: { $0.name == station.name }) { vibes.append(station) }
        persist()
        if let data = UserDefaults.standard.data(forKey: "vibe-player-song-ideas"), let ideas = try? JSONDecoder().decode([SongIdea].self, from: data) { songIdeas = ideas }
        if let data = UserDefaults.standard.data(forKey: "vibe-player-saved-songs"),
           let songs = try? JSONDecoder().decode([SavedSong].self, from: data) { savedSongs = songs }
        selectedID = vibes.first?.id
        savedIDs = Set((UserDefaults.standard.stringArray(forKey: "saved-vibes") ?? []).compactMap(UUID.init(uuidString:)))
        if let filename = UserDefaults.standard.string(forKey: "imported-audio-filename"),
           let directory = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true),
           FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path) {
            load(url: directory.appendingPathComponent(filename), name: UserDefaults.standard.string(forKey: "imported-audio-name") ?? "Imported audio", sample: true)
            isSample = false
            loadTrackMetadata(from: directory.appendingPathComponent(filename))
        } else if let url = Bundle.main.url(forResource: "atmosphere", withExtension: "wav") {
            load(url: url, name: "A little atmosphere", sample: true)
            radioMode = true
        }
        setupRemoteCommands()
    }

    func createStation(named name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let source = selected
        let station = Vibe(name: clean, subtitle: "Custom station", tags: source.tags, tempo: source.tempo, palette: (source.palette + 1) % 3)
        vibes.append(station)
        persist()
        select(station)
    }
    func select(_ vibe: Vibe) {
        resetRadioQueue()
        selectedID = vibe.id
        isEditingRadio = false
        updateNowPlaying()
        if radioWantsPlayback { scheduleRadioUpdate() }
    }
    func updateSelected(_ update: (inout Vibe) -> Void) {
        guard !vibes.isEmpty else { return }
        let previous = selected.musicProfile
        update(&vibes[selectedIndex]); persist(); updateNowPlaying()
        if selected.musicProfile != previous {
            resetRadioQueue(continueCurrentSong: true)
            isEditingRadio = false
            scheduleRadioUpdate()
        }
    }
    func setIntensity(_ name: String, value: Double, commit: Bool = false) {
        guard let index = vibes[selectedIndex].tags.firstIndex(where: { $0.name == name }) else { return }
        let intensity = min(1, max(0, value))
        let changed = vibes[selectedIndex].tags[index].intensity != intensity
        vibes[selectedIndex].tags[index].intensity = intensity
        radioControlChanged(changed, commit: commit)
    }
    func setTempo(_ value: Double, commit: Bool = false) {
        let tempo = min(180, max(50, value.rounded()))
        let changed = vibes[selectedIndex].tempo != tempo
        vibes[selectedIndex].tempo = tempo
        radioControlChanged(changed, commit: commit)
    }
    private func radioControlChanged(_ changed: Bool, commit: Bool) {
        guard changed || (commit && isEditingRadio) else { return }
        if !isEditingRadio { resetRadioQueue(continueCurrentSong: true) }
        isEditingRadio = !commit
        if commit {
            persist()
            scheduleRadioUpdate()
        }
    }
    private func resetRadioQueue(continueCurrentSong: Bool = false) {
        if isCreating { creationAutoplay = false } else { cancelGeneration() }
        let keepReserve = continueCurrentSong && isPlaying && currentTrack?.request.purpose == .radio
        discardRadioQueue(keepingReserve: keepReserve)
        radioMode = true
        radioWantsPlayback = canGenerate && (isPlaying || radioWantsPlayback)
        replaceWhenReady = true
        radioCanRetry = true
        radioContinuation = nil
        if continueCurrentSong, let track = currentTrack, isPlaying, track.request.purpose == .radio {
            let count = min(track.semanticTokens.count - 250, max(50, Int(elapsed * 25)))
            if count >= 50 {
                radioContinuation = (track.request.seed, Array(track.semanticTokens.prefix(count)),
                                     track.semanticTokens.count, track.request.lyrics)
            }
        }
    }
    func persist() {
        if let data = try? JSONEncoder().encode(vibes) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }
    func saveIdea(title: String, prompt: String, styles: String? = nil, lyrics: String? = nil, instrumental: Bool? = nil) {
        songIdeas.insert(SongIdea(title: title, prompt: prompt, styles: styles, lyrics: lyrics, instrumental: instrumental), at: 0)
        if let data = try? JSONEncoder().encode(songIdeas) { UserDefaults.standard.set(data, forKey: "vibe-player-song-ideas") }
    }
    func deleteIdea(_ id: UUID) {
        songIdeas.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(songIdeas) { UserDefaults.standard.set(data, forKey: "vibe-player-song-ideas") }
    }
    func toggleSaved() {
        if savedIDs.contains(selected.id) { savedIDs.remove(selected.id) } else { savedIDs.insert(selected.id) }; UserDefaults.standard.set(savedIDs.map(\.uuidString), forKey: "saved-vibes")
    }
    func generateSong(
        idea: String = "", instrumental: Bool? = nil, preparedLyrics: String? = nil,
        createStyles: String? = nil, createRenderer: CreateRenderer = .metal, createLength: CreateLength = .automatic,
        acoustics: CreateAcoustics = .reference, reference: MusicReference? = nil
    ) {
        if let createStyles {
            guard canGenerate else { errorMessage = MusicGenerationError.metalUnavailable.errorDescription; return }
            queuedCreations.append(CreationJob(idea: idea, styles: createStyles, lyrics: preparedLyrics,
                                               instrumental: instrumental ?? false, renderer: createRenderer,
                                               length: createLength, acoustics: reference == nil ? acoustics : .reference,
                                               reference: reference))
            if !isCreating {
                cancelGeneration()
                errorMessage = nil
                startNextCreation(autoplay: true)
            }
            return
        }
        runGeneration(idea: idea, instrumental: instrumental, preparedLyrics: preparedLyrics)
    }

    func removeQueuedCreation(_ id: UUID) { queuedCreations.removeAll { $0.id == id } }

    func cancelCurrentCreation() {
        guard isCreating else { return }
        cancelGeneration()
        startNextCreation(autoplay: !isPlaying && !radioMode)
        fillRadioQueue()
    }

    private func startNextCreation(autoplay: Bool) {
        guard !isGenerating, !queuedCreations.isEmpty else { return }
        let job = queuedCreations.removeFirst()
        runGeneration(idea: job.idea, instrumental: job.instrumental, preparedLyrics: job.lyrics,
                      job: job, autoplay: autoplay)
    }

    private func runGeneration(idea: String, instrumental: Bool?, preparedLyrics: String?,
                               job: CreationJob? = nil, autoplay: Bool = false) {
        let createStyles = job?.styles
        let createLength = job?.length ?? .automatic
        let isPrompted = createStyles != nil
        guard !isGenerating else { return }
        guard canGenerate else { errorMessage = MusicGenerationError.metalUnavailable.errorDescription; return }
        automaticGenerationTask?.cancel()
        automaticGenerationTask = nil
        if isPrompted && autoplay { radioMode = false; radioWantsPlayback = false; isEditingRadio = false; discardRadioQueue() }
        activeCreation = job
        creationAutoplay = isPrompted && autoplay
        let voiceOverride: MusicGenerationRequest.Voice? = instrumental.map { $0 ? .instrumental : .vocals }
        let reservedSeed = isPrompted ? nil : preparedRadioSeed
        if !isPrompted { preparedRadioSeed = nil }
        let seed = reservedSeed ?? UInt64.random(in: 0...UInt64(Int64.max))
        let radioProfile = selected.musicProfile
        var request = createStyles.map { MusicPromptBuilder().makeCreateRequest(idea: idea, styles: $0, instrumental: instrumental ?? false, seed: seed, length: createLength) }
            ?? MusicPromptBuilder().makeRadioPlaybackRequest(profile: radioProfile, seed: seed, idea: idea, voiceOverride: voiceOverride)
        if isPrompted {
            request.createRenderer = createLength == .extended ? .metal : job?.renderer ?? .metal
            request.createAcoustics = job?.acoustics ?? .reference
        }
        let continuation = isPrompted ? nil : radioContinuation
        if request.voice == .vocals, let preparedLyrics, !preparedLyrics.isEmpty { request = request.withLyrics(preparedLyrics) }
        let id = UUID()
        let title = idea.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        generationID = id
        isGenerating = true
        isCreating = isPrompted
        generationProgress = 0.04
        radioRenderStage = .preparing
        if !isPrompted { errorMessage = nil }
        creationStatus = isPrompted ? "Preparing your song…" : ""
        creationNotice = nil
        generationTask = Task { [weak self, generationBackend, lyricsWriter] in
            defer {
                if isPrompted, let self, !self.isGenerating {
                    self.startNextCreation(autoplay: !self.isPlaying && !self.radioMode)
                    if !self.isGenerating && self.errorMessage == nil { self.fillRadioQueue() }
                }
            }
            var resultURL: URL?
            do {
                // A cancelled Radio job can still be inside acoustic prediction. Let it
                // release its GPU allocations before starting another render or writer model.
                try await generationBackend.waitForIdle()
                try Task.checkCancellation()
                guard self?.generationID == id else { return }
                var prepared = request
                if isPrompted {
                    self?.creationStatus = "Rewriting your idea…"
                    do {
                        if let rewritten = try await lyricsWriter.rewriteIdea(idea, styles: createStyles ?? "") {
                            try Task.checkCancellation()
                            guard self?.generationID == id else { return }
                            prepared = MusicPromptBuilder().makeCreateRequest(idea: rewritten, styles: createStyles ?? "", instrumental: instrumental ?? false, seed: seed, length: createLength)
                            prepared.createRenderer = request.createRenderer
                            prepared.createAcoustics = request.createAcoustics
                            if !request.lyrics.isEmpty { prepared = prepared.withLyrics(request.lyrics) }
                        } else {
                            self?.creationNotice = "Using your original idea. Automatic rewriting is unavailable right now."
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try Task.checkCancellation()
                        guard self?.generationID == id else { return }
                        self?.creationNotice = "Couldn't rewrite your idea, so we're using the original."
                    }
                    try Task.checkCancellation()
                    guard self?.generationID == id else { return }
                }
                if let continuation, prepared.voice != .instrumental, prepared.lyrics.isEmpty {
                    prepared = prepared.withLyrics(continuation.lyrics)
                }
                if prepared.voice == .vocals && prepared.lyrics.isEmpty {
                    self?.isWritingLyrics = true
                    self?.creationStatus = "Writing lyrics…"
                    if !isPrompted { self?.radioRenderStage = .lyrics }
                    do {
                        prepared = prepared.withLyrics(try await lyricsWriter.writeLyrics(for: prepared))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch where !isPrompted {
                        prepared = MusicPromptBuilder().makeRadioPlaybackRequest(profile: radioProfile, seed: seed, idea: idea, voiceOverride: .instrumental)
                    }
                    try Task.checkCancellation()
                    guard self?.generationID == id else { return }
                    self?.isWritingLyrics = false
                }
                if let reference = job?.reference {
                    prepared.semanticPrefix = reference.prefix
                } else if let continuation {
                    prepared.semanticPrefix = continuation.prefix
                    prepared.minimumSemanticFrames = max(prepared.minimumSemanticFrames, continuation.minimumFrames)
                }
                if let usage = try await generationBackend.promptUsage(for: prepared), usage.count > usage.limit {
                    if isPrompted { self?.creationStatus = "Revising the prompt to fit…" }
                    prepared = try await Self.fitMusicPrompt(prepared, usage: usage,
                                                              backend: generationBackend, writer: lyricsWriter)
                    try Task.checkCancellation()
                    guard self?.generationID == id else { return }
                    if isPrompted { self?.creationNotice = "The writing model revised a copy of your text to fit the music model." }
                }
                self?.creationStatus = "Preparing the music model…"
                if !isPrompted { self?.radioRenderStage = .preparing }
                let acoustics = prepared.createAcoustics
                let streamsAudio = isPrompted && self?.creationAutoplay == true && job?.reference?.originalAudio == nil
                let stream = streamsAudio ? AsyncStream.makeStream(of: MusicAudioPreview.self) : nil
                let previewTask = stream.map { stream in
                    Task { @MainActor [weak self] in
                        for await preview in stream.stream {
                            self?.receivePreview(preview, title: title.isEmpty ? "Your song" : title, generation: id, acoustics: acoustics)
                        }
                    }
                }
                defer { stream?.continuation.finish(); previewTask?.cancel() }
                let onPreview: (@Sendable (MusicAudioPreview) -> Void)?
                if let stream { onPreview = { preview in stream.continuation.yield(preview) } }
                else { onPreview = nil }
                if !isPrompted, continuation == nil, reservedSeed == nil, prepared.voice == .instrumental,
                   prepared.semanticPrefix.isEmpty, generationBackend.canPrepareRadioPair,
                   self?.canComposeRadioPairAhead == true {
                    prepared.radioSuccessorSeed = Self.newRadioSeed(excluding: prepared.seed)
                }
                let output = try await generationBackend.generate(prepared, onPreview: onPreview) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.generationID == id else { return }
                        let fraction: Double
                        switch progress {
                        case .tokens(let count, let limit):
                            fraction = 0.08 + 0.52 * Double(count) / Double(max(limit, 1))
                            if isPrompted { self.creationStatus = "Composing music · \(count) of up to \(limit) frames" }
                            else { self.radioRenderStage = .composing(frames: count) }
                        case .synthesis(let step, let total):
                            fraction = 0.60 + 0.34 * Double(step) / Double(max(total, 1))
                            if isPrompted { self.creationStatus = "Whole-song synthesis · step \(step) of \(total)" }
                            else { self.radioRenderStage = .rendering(step: step, total: total) }
                        case .waveform:
                            fraction = 0.96
                            if isPrompted { self.creationStatus = acoustics == .streaming ? "Finishing audio…" : "Decoding audio…" }
                            else { self.radioRenderStage = .finishing }
                        }
                        self.generationProgress = max(self.generationProgress, fraction)
                    }
                }
                let url = output.url
                resultURL = url
                stream?.continuation.finish()
                await previewTask?.value
                try Task.checkCancellation()
                guard let self, self.generationID == id else { try? FileManager.default.removeItem(at: url); return }
                let length = isPrompted ? 0 : try AVAudioPlayer(contentsOf: url).duration
                if let reference = job?.reference, let original = reference.originalAudio {
                    self.creationStatus = "Blending the original opening…"
                    try await Self.preserveOpening(from: original, in: url, prefix: reference.prefix, result: output.semanticTokens)
                    try Task.checkCancellation()
                    guard self.generationID == id else { try? FileManager.default.removeItem(at: url); return }
                }
                let track = GeneratedTrack(url: url, request: prepared, duration: length,
                                           semanticTokens: output.semanticTokens, continuesRadioSeed: continuation?.seed)
                if isPrompted {
                    let saved = try self.persistSong(track, title: title.isEmpty ? "Your song" : title)
                    self.lastCreatedSong = saved
                    let completed = GeneratedTrack(url: self.songURL(saved), request: prepared, semanticTokens: output.semanticTokens)
                    if !self.completePreview(completed, savedID: saved.id, generation: id), self.creationAutoplay {
                        try self.startTrack(completed, savedID: saved.id, crossfade: self.isPlaying)
                    }
                    self.finishGeneration(id)
                    try? FileManager.default.removeItem(at: url)
                } else {
                    self.radioCanRetry = true
                    self.preparedRadioSeed = output.radioSuccessorSeed
                    self.radioContinuation = nil
                    self.discardRadioReserve()
                    self.radioQueue.append(track)
                    self.finishGeneration(id)
                    if self.radioWantsPlayback && (!self.isPlaying || self.replaceWhenReady) {
                        self.advanceRadio(crossfade: self.isPlaying)
                    } else { self.fillRadioQueue() }
                }
                resultURL = nil
            } catch is CancellationError {
                if let resultURL { try? FileManager.default.removeItem(at: resultURL) }
                self?.cancelPreview(generation: id)
                if let self, self.generationID == id, !isPrompted {
                    self.radioWantsPlayback = false
                    self.radioPreloading = false
                    self.errorMessage = "Radio preparation stopped. Tap Play to try again."
                }
                self?.finishGeneration(id)
            } catch {
                if let resultURL { try? FileManager.default.removeItem(at: resultURL) }
                guard let self, self.generationID == id else { return }
                self.cancelPreview(generation: id)
                self.finishGeneration(id)
                if !isPrompted {
                    #if os(macOS)
                    if self.radioWantsPlayback, self.radioCanRetry {
                        self.radioCanRetry = false
                        self.scheduleRadioUpdate(after: .seconds(2))
                        return
                    }
                    #endif
                    self.radioWantsPlayback = false
                    self.radioPreloading = false
                }
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't generate this song. Please try again."
            }
        }
    }

    private static func fitMusicPrompt(_ original: MusicGenerationRequest, usage: MusicPromptUsage,
                                       backend: any MusicGenerationBackend, writer: any LyricsWriter) async throws -> MusicGenerationRequest {
        var request = original
        var budget = usage
        for attempt in 0..<4 {
            try Task.checkCancellation()
            let reviseStyle = request.lyrics.isEmpty || budget.lyricTokens < 32 || (attempt == 0 && budget.styleTokens > 35)
            let field: MusicPromptField = reviseStyle ? .description : .lyrics
            let text = reviseStyle ? request.style : request.lyrics
            let fieldTokens = reviseStyle ? budget.styleTokens : budget.lyricTokens
            let excess = budget.count - budget.limit
            let target = max(12, fieldTokens - excess - 10 * (attempt + 1))
            guard let revised = try await writer.reviseForMusicModel(text, field: field, targetTokens: target),
                  !revised.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
            if reviseStyle { request.style = revised } else { request = request.withLyrics(revised) }
            guard let updated = try await backend.promptUsage(for: request) else { return request }
            if updated.count <= updated.limit { return request }
            budget = updated
        }
        throw MusicGenerationError.promptTooLong(count: budget.count, limit: budget.limit)
    }

    func cancelGeneration() {
        if let generationID { cancelPreview(generation: generationID) }
        radioPreloading = false
        automaticGenerationTask?.cancel()
        automaticGenerationTask = nil
        preparedRadioSeed = nil
        generationTask?.cancel()
        generationTask = nil
        generationID = nil
        isGenerating = false
        isWritingLyrics = false
        isCreating = false
        activeCreation = nil
        generationProgress = 0
        radioRenderStage = .preparing
        creationStatus = ""
    }
    private func scheduleRadioUpdate(after delay: Duration = .milliseconds(450)) {
        guard canGenerate else { return }
        automaticGenerationTask?.cancel()
        automaticGenerationTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.automaticGenerationTask = nil
            self?.prepareRadio()
        }
    }
    func prepareRadio() {
        radioPreloading = true
        fillRadioQueue()
    }

    func cancelRadioPreparation() {
        radioWantsPlayback = false
        if !isCreating { cancelGeneration() }
    }

    private var canComposeRadioPairAhead: Bool {
        // Cold stations already wait for two songs. Once on air, keep a reserve or ample lead.
        if !isPlaying && currentTrack?.request.purpose != .radio { return true }
        return !radioQueue.isEmpty || (isPlaying && duration - elapsed >= 140)
    }

    private static func newRadioSeed(excluding seed: UInt64) -> UInt64 {
        let next = UInt64.random(in: 0...UInt64(Int64.max))
        return next == seed ? next ^ 1 : next
    }

    private func fillRadioQueue() {
        if radioQueue.count >= radioQueueCapacity {
            radioPreloading = false
            return
        }
        guard radioMode, radioWantsPlayback || radioPreloading, canGenerate, !isGenerating,
              !isEditingRadio, automaticGenerationTask == nil else { return }
        generateSong()
    }

    private func advanceRadio(crossfade: Bool) {
        guard radioMode, radioWantsPlayback else { return }
        #if os(macOS)
        // Start a new station with one song in reserve. Replacements and underrun
        // recovery can use the first ready song because playback is already underway.
        if !isPlaying, currentTrack?.request.purpose != .radio, radioQueue.count < radioQueueCapacity {
            fillRadioQueue()
            return
        }
        #endif
        while !radioQueue.isEmpty {
            let track = radioQueue.removeFirst()
            do {
                try startTrack(track, savedID: nil, crossfade: crossfade)
                replaceWhenReady = false
                radioTrackEnded = false
                break
            } catch {
                try? FileManager.default.removeItem(at: track.url)
                errorMessage = "Couldn't play the prepared song. Radio is preparing another."
            }
        }
        // An edit can arrive just before the crossfade. Use the already rendered
        // song if the replacement misses that deadline, then blend to it when ready.
        if radioQueue.isEmpty, radioTrackEnded || (crossfade && duration - elapsed <= 2),
           let reserve = radioReserve {
            radioReserve = nil
            do {
                try startTrack(reserve, savedID: nil, crossfade: crossfade)
                radioTrackEnded = false
            } catch {
                try? FileManager.default.removeItem(at: reserve.url)
            }
        }
        fillRadioQueue()
    }
    func writeLyrics(idea: String, createStyles: String? = nil) async throws -> String {
        let request = createStyles.map { MusicPromptBuilder().makeCreateRequest(idea: idea, styles: $0, instrumental: false, seed: 0) }
            ?? MusicPromptBuilder().makeRequest(profile: selected.musicProfile, seed: 0, idea: idea, voiceOverride: .vocals)
        return try await lyricsWriter.writeLyrics(for: request)
    }
    private func finishGeneration(_ id: UUID) {
        guard generationID == id else { return }
        generationTask = nil
        generationID = nil
        isGenerating = false
        isWritingLyrics = false
        isCreating = false
        activeCreation = nil
        generationProgress = 0
        radioRenderStage = .preparing
        creationStatus = ""
    }
    private func libraryDirectory() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = root.appendingPathComponent("Songs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func songURL(_ song: SavedSong) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Songs", isDirectory: true).appendingPathComponent(song.filename)
    }

    func remix(_ song: SavedSong) async throws {
        let tokens: [Int]
        let audio = songURL(song)
        if let filename = song.semanticFilename,
           let saved = try? await MusicReference.load(from: audio.deletingLastPathComponent().appendingPathComponent(filename)) {
            tokens = saved.tokens
        } else { tokens = try await MusicReference.load(from: audio).tokens }
        try Task.checkCancellation()
        remixSource = MusicReference(title: song.title, tokens: tokens, originalAudio: audio,
                                     openingFrames: max(50, tokens.count / 2), sourceLyrics: song.lyrics)
    }

    @concurrent
    private static func preserveOpening(from original: URL, in revised: URL, prefix: [Int], result: [Int]) async throws {
        let applied = min(prefix.count, result.count - 250)
        guard applied > 0, result.starts(with: prefix.prefix(applied)) else { throw MusicGenerationError.invalidReference }
        let source = try AVAudioFile(forReading: original, commonFormat: .pcmFormatInt16, interleaved: true)
        let generated = try AVAudioFile(forReading: revised, commonFormat: .pcmFormatInt16, interleaved: true)
        guard source.processingFormat == generated.processingFormat, generated.processingFormat.sampleRate == 48_000 else {
            throw MusicGenerationError.invalidReference
        }
        let blendStart = min(source.length, AVAudioFramePosition(applied * 1_920))
        guard blendStart < generated.length else { throw MusicGenerationError.invalidReference }
        let blendFrames = AVAudioFrameCount(min(24_000, source.length - blendStart, generated.length - blendStart))
        let format = generated.processingFormat
        let staging = revised.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            let output = try AVAudioFile(forWriting: staging, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000),
                  let other = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000),
                  let src = buffer.int16ChannelData?[0], let dst = other.int16ChannelData?[0] else {
                throw MusicGenerationError.invalidReference
            }
            func copy(_ file: AVAudioFile, until end: AVAudioFramePosition) throws {
                while file.framePosition < end {
                    try Task.checkCancellation()
                    let frames = AVAudioFrameCount(min(48_000, end - file.framePosition))
                    buffer.frameLength = frames
                    try file.read(into: buffer, frameCount: frames)
                    guard buffer.frameLength > 0 else { throw MusicGenerationError.invalidReference }
                    try output.write(from: buffer)
                }
            }
            try copy(source, until: blendStart)
            generated.framePosition = blendStart
            let channels = Int(format.channelCount)
            var blended: AVAudioFrameCount = 0
            while blended < blendFrames {
                try Task.checkCancellation()
                let remaining = blendFrames - blended
                buffer.frameLength = remaining
                other.frameLength = remaining
                try source.read(into: buffer, frameCount: remaining)
                try generated.read(into: other, frameCount: remaining)
                let read = min(buffer.frameLength, other.frameLength)
                guard read > 0 else { throw MusicGenerationError.invalidReference }
                for frame in 0..<Int(read) {
                    let mix = Float(Int(blended) + frame + 1) / Float(blendFrames)
                    for channel in 0..<channels {
                        let index = frame * channels + channel
                        dst[index] = Int16(clamping: Int((Float(src[index]) * (1 - mix) + Float(dst[index]) * mix).rounded()))
                    }
                }
                blended += read
                let position = blendStart + AVAudioFramePosition(blended)
                if source.framePosition != position { source.framePosition = position }
                if generated.framePosition != position { generated.framePosition = position }
                other.frameLength = read
                try output.write(from: other)
            }
            try copy(generated, until: generated.length)
        }
        _ = try FileManager.default.replaceItemAt(revised, withItemAt: staging)
    }
    private func persistSong(_ track: GeneratedTrack, title: String) throws -> SavedSong {
        let id = UUID()
        let item = SavedSong(id: id, title: title, filename: "\(id.uuidString).wav", style: track.request.style,
                             lyrics: track.request.lyrics, createdAt: Date(),
                             semanticFilename: track.semanticTokens.isEmpty ? nil : "\(id.uuidString).semantic.json")
        let directory = try libraryDirectory()
        let destination = directory.appendingPathComponent(item.filename)
        let semanticURL = item.semanticFilename.map { directory.appendingPathComponent($0) }
        try FileManager.default.copyItem(at: track.url, to: destination)
        let updated = [item] + savedSongs
        do {
            if let semanticURL { try JSONEncoder().encode(track.semanticTokens).write(to: semanticURL, options: .atomic) }
            let data = try JSONEncoder().encode(updated)
            UserDefaults.standard.set(data, forKey: "vibe-player-saved-songs")
            savedSongs = updated
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if let semanticURL { try? FileManager.default.removeItem(at: semanticURL) }
            throw error
        }
        return item
    }
    func likeCurrentSong() {
        guard let track = currentTrack else { return }
        if currentSavedID != nil { liked = true; return }
        do {
            let saved = try persistSong(track, title: trackName)
            currentSavedID = saved.id; liked = true; disliked = false
        } catch { errorMessage = "Couldn't save this song: \(error.localizedDescription)" }
    }
    func playSavedSong(_ song: SavedSong) {
        if isCreating { creationAutoplay = false } else { cancelGeneration() }
        discardRadioQueue(); radioMode = false; radioWantsPlayback = false; isEditingRadio = false
        do {
            let player = try AVAudioPlayer(contentsOf: songURL(song))
            installPlayer(player, name: song.title, sample: false, generated: true)
            currentTrack = nil; currentSavedID = song.id; liked = true
            play()
        } catch { errorMessage = "Couldn't open the saved song." }
    }
    func toggleLastCreatedSong() {
        guard let song = lastCreatedSong else { return }
        if currentSavedID == song.id { togglePlayback() }
        else { playSavedSong(song) }
    }
    func deleteSavedSong(_ song: SavedSong) {
        let remaining = savedSongs.filter { $0.id != song.id }
        guard let data = try? JSONEncoder().encode(remaining) else { return }
        UserDefaults.standard.set(data, forKey: "vibe-player-saved-songs")
        savedSongs = remaining
        if lastCreatedSong?.id == song.id { lastCreatedSong = nil }
        let audio = songURL(song)
        try? FileManager.default.removeItem(at: audio)
        if let filename = song.semanticFilename {
            try? FileManager.default.removeItem(at: audio.deletingLastPathComponent().appendingPathComponent(filename))
        }
        if currentSavedID == song.id { currentSavedID = nil; liked = false }
    }
    private func discardRadioQueue(keepingReserve: Bool = false) {
        preparedRadioSeed = nil
        if keepingReserve, radioReserve == nil, !radioQueue.isEmpty {
            radioReserve = radioQueue.removeFirst()
        } else if !keepingReserve {
            discardRadioReserve()
        }
        for track in radioQueue { try? FileManager.default.removeItem(at: track.url) }
        radioQueue.removeAll()
    }
    private func discardRadioReserve() {
        if let radioReserve { try? FileManager.default.removeItem(at: radioReserve.url) }
        radioReserve = nil
    }
    private func discardCurrentTrack() {
        if let currentTrack, currentTrack.url.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
            try? FileManager.default.removeItem(at: currentTrack.url)
        }
        currentTrack = nil
    }
    private func receivePreview(_ preview: MusicAudioPreview, title: String, generation: UUID, acoustics: CreateAcoustics) {
        guard generationID == generation, isCreating else { return }
        if let previewPlayer, previewGenerationID == generation {
            do {
                try previewPlayer.append(preview)
                try resumePreviewIfReady(previewPlayer)
            } catch {
                // The saved file can supply any range that was not scheduled.
            }
            return
        }
        guard creationAutoplay, preview.startFrame == 0 else { return }
        do {
            #if !os(macOS)
            try activatePlaybackSession()
            #endif
            let next = try PreviewPlayback(preview, acoustics: acoustics)
            let startsNow = next.readyToPlay
            if startsNow { try next.play() }
            stopPreview()
            fadeTask?.cancel(); fadingPlayer?.stop(); fadingPlayer = nil
            audio?.stop(); audio = nil; discardCurrentTrack(); clearTrackMetadata()
            previewPlayer = next
            previewGenerationID = generation
            isBufferingPreview = !startsNow
            currentSavedID = nil; liked = false; disliked = false
            isSample = false; isGenerated = true; isPlaying = true
            trackName = title; elapsed = 0; duration = Double(preview.totalFrames) / 48_000
            startTimer(); updateNowPlaying()
        } catch {
            // The full file still plays through the normal path if the audio route rejects early playback.
        }
    }

    private func completePreview(_ track: GeneratedTrack, savedID: UUID, generation: UUID) -> Bool {
        guard previewGenerationID == generation, let previewPlayer else { return false }
        do {
            let fallback = try AVAudioPlayer(contentsOf: track.url)
            fallback.delegate = self; fallback.isMeteringEnabled = true
            try previewPlayer.appendRemainder(at: track.url)
            if isPlaying { try previewPlayer.play() }
            isBufferingPreview = false
            previewGenerationID = nil
            audio = fallback; currentTrack = track; currentSavedID = savedID; liked = true
            duration = fallback.duration
            updateNowPlaying()
            return true
        } catch {
            cancelPreview(generation: generation)
            return false
        }
    }

    private func resumePreviewIfReady(_ preview: PreviewPlayback) throws {
        guard isPlaying, isBufferingPreview || preview.needsBuffer, preview.readyToPlay else { return }
        try preview.play()
        isBufferingPreview = false
        updateNowPlaying()
    }

    private func stopPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
        previewGenerationID = nil
        isBufferingPreview = false
    }

    private func cancelPreview(generation: UUID) {
        guard previewGenerationID == generation else { return }
        stopPreview(); isPlaying = false; isGenerated = false; duration = 0; elapsed = 0
        timer?.invalidate(); updateNowPlaying()
    }
    private func startTrack(_ track: GeneratedTrack, savedID: UUID?, crossfade: Bool) throws {
        let size = try track.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        let next = try size <= 8 * 1024 * 1024
            ? AVAudioPlayer(data: Data(contentsOf: track.url))
            : AVAudioPlayer(contentsOf: track.url)
        let previous = audio
        let oldTrack = currentTrack
        let fadeDuration = crossfade && previous?.isPlaying == true
            ? min(2, max(0, (previous?.duration ?? 0) - (previous?.currentTime ?? 0)))
            : 0
        fadeTask?.cancel(); fadingPlayer?.stop(); fadingPlayer = nil
        next.delegate = self; next.isMeteringEnabled = true; next.prepareToPlay()
        if !isPlaying {
            #if !os(macOS)
            try activatePlaybackSession()
            #endif
        }
        next.volume = fadeDuration > 0 ? 0 : 1
        if let seed = track.continuesRadioSeed, seed == oldTrack?.request.seed {
            let split = Double(track.request.semanticPrefix.count) / 25
            let position = previous?.currentTime ?? split
            next.currentTime = max(split, position < next.duration - 3 ? position : split)
        }
        guard next.play() else { throw MusicGenerationError.unavailable }
        stopPreview()
        clearTrackMetadata()
        audio = next; currentTrack = track; currentSavedID = savedID
        trackName = savedID == nil ? track.request.stationName : (savedSongs.first { $0.id == savedID }?.title ?? track.request.stationName)
        isSample = false; isGenerated = true; duration = next.duration; elapsed = next.currentTime; isPlaying = true
        liked = savedID != nil; disliked = false
        startTimer(); updateNowPlaying()
        if fadeDuration > 0, let previous {
            fadingPlayer = previous
            previous.setVolume(0, fadeDuration: fadeDuration)
            next.setVolume(1, fadeDuration: fadeDuration)
            fadeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(fadeDuration))
                previous.stop()
                if let oldTrack, oldTrack.url.path.hasPrefix(FileManager.default.temporaryDirectory.path) { try? FileManager.default.removeItem(at: oldTrack.url) }
                guard !Task.isCancelled else { return }
                self?.fadingPlayer = nil; self?.fadeTask = nil
            }
        } else {
            previous?.stop()
            if let oldTrack, oldTrack.url.path.hasPrefix(FileManager.default.temporaryDirectory.path) { try? FileManager.default.removeItem(at: oldTrack.url) }
        }
    }
    private func installPlayer(_ next: AVAudioPlayer, name: String, sample: Bool, generated: Bool) {
        stopPreview()
        fadeTask?.cancel(); fadingPlayer?.stop(); fadingPlayer = nil
        clearTrackMetadata()
        audio?.stop(); discardCurrentTrack(); currentSavedID = nil; liked = false; disliked = false
        audio = next; next.delegate = self; next.isMeteringEnabled = true; next.prepareToPlay()
        trackName = name; isSample = sample; isGenerated = generated; duration = next.duration; elapsed = 0; isPlaying = false
        audioLevel = 0; smoothedLevel = 0; timer?.invalidate()
        updateNowPlaying()
    }
    func load(url: URL, name: String, sample: Bool = false) {
        if isCreating { creationAutoplay = false } else { cancelGeneration() }
        discardRadioQueue(); radioWantsPlayback = false; isEditingRadio = false
        if !sample { radioMode = false }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            // Copy imported audio into the app container so it remains playable after the picker closes.
            let localURL: URL
            if sample { localURL = url } else {
                let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                localURL = directory.appendingPathComponent("imported-audio.\(url.pathExtension)")
                if FileManager.default.fileExists(atPath: localURL.path) { try FileManager.default.removeItem(at: localURL) }
                try FileManager.default.copyItem(at: url, to: localURL)
            }
            let next = try AVAudioPlayer(contentsOf: localURL)
            installPlayer(next, name: name, sample: sample, generated: false)
            if !sample {
                UserDefaults.standard.set(localURL.lastPathComponent, forKey: "imported-audio-filename")
                UserDefaults.standard.set(name, forKey: "imported-audio-name")
            }
            if !sample { loadTrackMetadata(from: localURL) }
            updateNowPlaying()
        } catch { errorMessage = "Couldn't open this audio file. Try another audio file." }
    }
    private func clearTrackMetadata() {
        artworkTask?.cancel(); artworkTask = nil; artworkRequestID = UUID()
        trackArtwork = nil; trackArtist = nil
    }
    private func loadTrackMetadata(from url: URL) {
        let id = UUID(); artworkRequestID = id
        artworkTask = Task { [weak self] in
            let asset = AVURLAsset(url: url)
            guard let metadata = try? await asset.load(.commonMetadata), !Task.isCancelled else { return }
            let artworkItem = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork).first
            let artistItem = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtist).first
            let artworkData = try? await artworkItem?.load(.dataValue)
            let artist = try? await artistItem?.load(.stringValue)
            guard !Task.isCancelled, let self, self.artworkRequestID == id else { return }
            self.trackArtwork = artworkData.flatMap(PlatformImage.init(data:))
            self.trackArtist = artist
            self.updateNowPlaying()
        }
    }
    func setSleepTimer(_ minutes: Int?) {
        sleepTimer?.invalidate(); sleepMinutes = minutes
        guard let minutes else { return }
        sleepTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.pause(); self?.sleepMinutes = nil }
        }
    }
    #if !os(macOS)
    private func activatePlaybackSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        // Give playback a larger I/O buffer while the next song uses CPU and GPU.
        try? session.setPreferredIOBufferDuration(0.023)
        try session.setActive(true)
    }
    #endif
    func togglePlayback() { wantsPlayback ? pause() : play() }
    func play() {
        if let previewPlayer {
            do {
                isBufferingPreview = !previewPlayer.readyToPlay
                if !isBufferingPreview { try previewPlayer.play() }
                isPlaying = true; startTimer(); updateNowPlaying()
            } catch { errorMessage = "Audio couldn't resume. Try opening the song from Library when it finishes." }
            return
        }
        if radioMode, canGenerate {
            radioWantsPlayback = true
            radioCanRetry = true
            if replaceWhenReady || radioTrackEnded || currentTrack?.request.purpose != .radio {
                advanceRadio(crossfade: isPlaying)
                return
            }
        }
        do {
            #if !os(macOS)
            try activatePlaybackSession()
            #endif
            guard let audio, audio.play() else {
                radioWantsPlayback = false
                errorMessage = "Audio couldn't start. Try another file."
                return
            }
            isPlaying = true; startTimer(); updateNowPlaying()
            fillRadioQueue()
        } catch {
            radioWantsPlayback = false
            errorMessage = "Audio couldn't start. Check your audio output and try again."
        }
    }
    func pause() {
        radioWantsPlayback = false
        previewPlayer?.pause()
        audio?.pause()
        audio?.setVolume(1, fadeDuration: 0)
        fadingPlayer?.stop()
        isPlaying = false; audioLevel = 0; smoothedLevel = 0
        timer?.invalidate()
        updateNowPlaying()
    }
    func seek(_ value: Double) {
        guard canSeek else { return }
        let wasPreviewing = previewPlayer != nil
        if wasPreviewing { stopPreview() }
        audio?.currentTime = min(max(value, 0), duration)
        elapsed = audio?.currentTime ?? 0
        if wasPreviewing, isPlaying { isPlaying = audio?.play() == true }
        updateNowPlaying()
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === audio else { return }
        radioTrackEnded = currentTrack?.request.purpose == .radio
        isPlaying = false; elapsed = radioTrackEnded ? duration : 0; audioLevel = 0; smoothedLevel = 0
        timer?.invalidate(); updateNowPlaying()
        advanceRadio(crossfade: false)
    }
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleAudio() }
        }
    }
    private func sampleAudio() {
        if let previewPlayer, isPlaying {
            elapsed = min(duration, previewPlayer.elapsed)
            if previewPlayer.hasEnded {
                stopPreview(); isPlaying = false; elapsed = 0
                timer?.invalidate(); updateNowPlaying()
            } else if previewPlayer.needsBuffer, !isBufferingPreview {
                isBufferingPreview = true
                updateNowPlaying()
            }
            return
        }
        guard let audio, isPlaying else { return }
        elapsed = audio.currentTime
        if radioMode, radioWantsPlayback, !radioQueue.isEmpty || radioReserve != nil, duration - elapsed <= 2.0 {
            advanceRadio(crossfade: true)
            return
        }
        audio.updateMeters()
        let power = audio.averagePower(forChannel: 0)
        let level = min(1, max(0, (Double(power) + 55) / 55))
        let previous = smoothedLevel
        smoothedLevel = previous * 0.82 + level * 0.18
        audioLevel = level
        if level > 0.35 && level > previous + 0.12 && Date().timeIntervalSince(lastBeat) > 0.28 {
            lastBeat = Date()
            beatPulse.toggle()
        }
    }
    private func setupRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.play() }; return .success }
        commands.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
    }
    private func updateNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: trackName,
            MPMediaItemPropertyArtist: radioMode ? selected.name : (trackArtist ?? "Vibe Player"),
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying && !isBufferingPreview ? 1.0 : 0.0
        ]
    }
}
