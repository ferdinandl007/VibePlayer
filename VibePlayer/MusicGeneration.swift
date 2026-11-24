import Foundation

/// A snapshot of the controls, independent of the player UI and the model runtime.
struct MusicProfile: Equatable, Sendable {
    enum Category: String, Sendable { case genre, mood, instrument, voice }
    struct Trait: Equatable, Sendable {
        let name: String
        let category: Category
        let intensity: Double
    }
    let name: String
    let traits: [Trait]
    let tempo: Double
}

enum CreateRenderer: Sendable {
    case metal, metalPaired
}

enum CreateLength: String, Sendable {
    case automatic, extended

    var maximumFrames: Int { self == .extended ? 6_400 : 5_200 }
    var minimumFrames: Int { self == .extended ? 5_250 : 200 }
}

enum CreateAcoustics: String, Sendable {
    case streaming, reference

    static func resolve(preference: String, instrumental: Bool, supportsEarlyPlayback: Bool) -> Self {
        guard supportsEarlyPlayback else { return .reference }
        return Self(rawValue: preference) ?? (instrumental ? .streaming : .reference)
    }
}

/// Text and generation parameters accepted by the YuE2 renderer.
struct MusicGenerationRequest: Equatable, Sendable {
    enum Voice: Sendable { case instrumental, vocals, unspecified }
    enum Purpose: Sendable { case radio, createdSong }
    let stationName: String
    var style: String
    private(set) var lyrics: String
    let voice: Voice
    let purpose: Purpose
    let seed: UInt64
    /// YuE2 semantic frames at 25 Hz; a ceiling, not a guaranteed song duration.
    let maxSemanticFrames: Int
    let synthesisSteps: Int
    var createRenderer: CreateRenderer = .metal
    var minimumSemanticFrames = 200
    var createAcoustics: CreateAcoustics = .reference

    func withLyrics(_ lyrics: String) -> MusicGenerationRequest {
        var request = self
        request.lyrics = lyrics
        return request
    }
}

struct MusicPromptBuilder {
    /// The Create screen starts with its own description instead of inheriting a radio station.
    func makeCreateRequest(idea: String, styles: String, instrumental: Bool, seed: UInt64,
                           length: CreateLength = .automatic) -> MusicGenerationRequest {
        let voice: MusicGenerationRequest.Voice = instrumental ? .instrumental : .vocals
        var parts = [instrumental ? "instrumental" : "vocal music"]
        let cleanStyles = styles.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanIdea = idea.trimmingCharacters(in: .whitespacesAndNewlines)
        if length == .extended { parts.append("extended arrangement with a closing section") }
        if !cleanStyles.isEmpty { parts.append("styles: " + cleanStyles) }
        if !cleanIdea.isEmpty { parts.append("song idea: " + cleanIdea) }
        return MusicGenerationRequest(stationName: "Your song", style: parts.joined(separator: "; "), lyrics: "", voice: voice, purpose: .createdSong, seed: seed, maxSemanticFrames: length.maximumFrames, synthesisSteps: 8, createRenderer: .metal, minimumSemanticFrames: length.minimumFrames)
    }

    func makeRequest(profile: MusicProfile, seed: UInt64, maxSemanticFrames: Int = 5_000, idea: String = "", voiceOverride: MusicGenerationRequest.Voice? = nil) -> MusicGenerationRequest {
        let active = profile.traits.filter { $0.intensity.isFinite && $0.intensity > 0 }
        func values(_ category: MusicProfile.Category) -> [MusicProfile.Trait] {
            active.filter { $0.category == category }.sorted {
                if $0.intensity == $1.intensity { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                return $0.intensity > $1.intensity
            }
        }
        func description(_ trait: MusicProfile.Trait) -> String {
            let level = min(1, max(0, trait.intensity))
            let emphasis = level < 0.34 ? "subtle" : level < 0.67 ? "moderate" : "prominent"
            return "\(emphasis) \(trait.name.lowercased())"
        }
        let voices = values(.voice)
        let voice = voices.first { $0.name.caseInsensitiveCompare("Instrumental") == .orderedSame || $0.name.caseInsensitiveCompare("Vocals") == .orderedSame }
        let voiceMode: MusicGenerationRequest.Voice
        if let voiceOverride {
            voiceMode = voiceOverride
        } else if let voice {
            voiceMode = voice.name.caseInsensitiveCompare("Instrumental") == .orderedSame ? .instrumental : .vocals
        } else if profile.traits.contains(where: { $0.category == .voice }) {
            voiceMode = .unspecified
        } else {
            voiceMode = .vocals
        }
        var parts: [String] = []
        switch voiceMode {
        case .instrumental: parts.append("instrumental")
        case .vocals: parts.append("vocal music")
        case .unspecified: break
        }
        let genres = values(.genre).map(description)
        let moods = values(.mood).map(description)
        let instruments = values(.instrument).map(description)
        if !genres.isEmpty { parts.append("styles: " + genres.joined(separator: ", ")) }
        if !moods.isEmpty { parts.append("moods: " + moods.joined(separator: ", ")) }
        if !instruments.isEmpty { parts.append("instruments: " + instruments.joined(separator: ", ")) }
        let tempo = profile.tempo.isFinite ? min(180, max(50, profile.tempo.rounded())) : 90
        parts.append("\(Int(tempo)) BPM")
        let cleanIdea = idea.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanIdea.isEmpty { parts.append("song idea: " + cleanIdea) }
        return MusicGenerationRequest(stationName: profile.name, style: parts.joined(separator: "; "), lyrics: "", voice: voiceMode, purpose: .radio, seed: seed, maxSemanticFrames: maxSemanticFrames, synthesisSteps: 8)
    }

    func makeRadioPlaybackRequest(profile: MusicProfile, seed: UInt64, idea: String,
                                  voiceOverride: MusicGenerationRequest.Voice?) -> MusicGenerationRequest {
        var request = makeRequest(profile: profile, seed: seed, maxSemanticFrames: 4_200,
                                  idea: idea, voiceOverride: voiceOverride)
        request.minimumSemanticFrames = 2_000
        return request
    }
}

/// A renderer must produce a complete local audio file playable by AVAudioPlayer.
/// Implementations own inference, cancellation and temporary-file management.
@MainActor
protocol MusicGenerationBackend {
    var isAvailable: Bool { get }
    var canUsePairedMetal: Bool { get }
    var canStreamAcoustics: Bool { get }
    var canCreateExtended: Bool { get }
    func prepareEarlyPlayback()
    func waitForIdle() async throws
    func promptUsage(for request: MusicGenerationRequest) async throws -> MusicPromptUsage?
    func generate(_ request: MusicGenerationRequest, onPreview: (@Sendable (MusicAudioPreview) -> Void)?,
                  onProgress: @escaping @Sendable (MusicGenerationProgress) -> Void) async throws -> URL
}

struct MusicAudioPreview: Sendable {
    let samples: [Int16]
    let totalFrames: Int
    var startFrame = 0
    var lowLatency = false
}

struct MusicPromptUsage: Sendable {
    let count: Int
    let limit: Int
    let styleTokens: Int
    let lyricTokens: Int
}

enum MusicGenerationProgress: Sendable {
    case tokens(Int, Int), synthesis(Int, Int), waveform
}

extension MusicGenerationBackend {
    var canUsePairedMetal: Bool { false }
    var canStreamAcoustics: Bool { false }
    var canCreateExtended: Bool { false }
    func prepareEarlyPlayback() {}
    func waitForIdle() async throws {}
    func promptUsage(for request: MusicGenerationRequest) async throws -> MusicPromptUsage? { nil }
}

struct UnavailableMusicGenerationBackend: MusicGenerationBackend {
    let isAvailable = false
    func generate(_ request: MusicGenerationRequest, onPreview: (@Sendable (MusicAudioPreview) -> Void)?,
                  onProgress: @escaping @Sendable (MusicGenerationProgress) -> Void) async throws -> URL {
        throw MusicGenerationError.metalUnavailable
    }
}

enum MusicGenerationError: LocalizedError {
    case unavailable, metalUnavailable, extendedUnavailable, promptTooLong(count: Int, limit: Int)
    var errorDescription: String? {
        switch self {
        case .unavailable: "Song generation isn't available yet."
        case .metalUnavailable: "The Metal music model is unavailable on this device."
        case .extendedUnavailable: "Extended songs require the 4:16 Metal model. Select Automatic length to use the installed model."
        case .promptTooLong(let count, let limit): "The description and lyrics use \(count) tokens. The music model can use \(limit). Shorten the description or reduce the lyrics, then create again."
        }
    }
}
