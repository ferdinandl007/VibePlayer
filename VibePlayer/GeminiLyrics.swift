import Foundation
import Security
#if canImport(FoundationModels)
import FoundationModels
#endif

struct GeminiKeyStore {
    private let service = "com.vibeplayer.gemini"
    private let account = "user-api-key"

    func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw GeminiLyricsError.keychain(status) }
        guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else { throw GeminiLyricsError.keychain(errSecDecode) }
        return key
    }

    func save(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let data = key.data(using: .utf8) else { throw GeminiLyricsError.missingKey }
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw GeminiLyricsError.keychain(addStatus) }
        } else if status != errSecSuccess { throw GeminiLyricsError.keychain(status) }
    }

    func remove() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GeminiLyricsError.keychain(status) }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

enum GeminiLyricsError: LocalizedError {
    case missingKey, keychain(OSStatus), invalidResponse, rejected(Int), empty, offlineModelUnavailable
    var errorDescription: String? {
        switch self {
        case .missingKey: return "Enable Apple Intelligence for offline songwriting or add a Gemini key in Songwriting settings."
        case .keychain(let status): return "Couldn't access the Gemini API key on this device (Keychain error \(status))."
        case .invalidResponse: return "Gemini returned an incomplete response. Please try again."
        case .rejected(let status): return "Gemini couldn't complete the request (HTTP \(status)). Check your key, model access, and quota."
        case .empty: return "Gemini didn't return any text. Please try again."
        case .offlineModelUnavailable: return "Apple’s on-device model isn’t ready. Use your own lyrics, or reconnect to use Gemini."
        }
    }
}

@MainActor
protocol LyricsWriter {
    func writeLyrics(for request: MusicGenerationRequest) async throws -> String
    func rewriteIdea(_ idea: String, styles: String) async throws -> String?
    func reviseForMusicModel(_ text: String, field: MusicPromptField, targetTokens: Int) async throws -> String?
    func suggestRadioTitle(for request: MusicGenerationRequest) async throws -> String?
}

enum MusicPromptField: String { case description, lyrics }

extension LyricsWriter {
    func rewriteIdea(_ idea: String, styles: String) async throws -> String? { nil }
    func reviseForMusicModel(_ text: String, field: MusicPromptField, targetTokens: Int) async throws -> String? { nil }
    func suggestRadioTitle(for request: MusicGenerationRequest) async throws -> String? { nil }
}

struct GeminiLyricsWriter: LyricsWriter {
    private let session: URLSession
    private let readKey: @Sendable () throws -> String?
    private let localCompletion: @Sendable (String, Int) async throws -> String?

    init(session: URLSession = .shared,
         readKey: @escaping @Sendable () throws -> String? = { try GeminiKeyStore().read() },
         localCompletion: @escaping @Sendable (String, Int) async throws -> String? = { instruction, limit in
             try await AppleSongwriting.complete(instruction, limit: limit)
         }) {
        self.session = session
        self.readKey = readKey
        self.localCompletion = localCompletion
    }

    func testKey(_ key: String) async throws {
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else { throw GeminiLyricsError.missingKey }
        _ = try await complete("Reply with one short word: ready.", apiKey: cleanKey, maxOutputTokens: 512, timeout: 30)
    }

    func rewriteIdea(_ idea: String, styles: String) async throws -> String? {
        try await preferredCompletion(polishPrompt(idea, kind: "song idea", idea: "", styles: styles), localLimit: 150)
    }

    func writeLyrics(for request: MusicGenerationRequest) async throws -> String {
        guard let text = try await preferredCompletion(lyricsPrompt(for: request), localLimit: 420) else {
            throw GeminiLyricsError.missingKey
        }
        return text
    }

    func suggestRadioTitle(for request: MusicGenerationRequest) async throws -> String? {
        let prompt = """
        Invent one original song title of two to five words that fits this music. Return only the title.
        Station: \(request.stationName)
        Sound: \(request.style.prefix(500))
        Lyrics excerpt: \(request.lyrics.prefix(400))
        """
        if let local = try? await localCompletion(prompt, 32), !local.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return local
        }
        try Task.checkCancellation()
        guard let key = try readKey(), !key.isEmpty else { return nil }
        return try await complete(prompt, apiKey: key, maxOutputTokens: 256, timeout: 5)
    }

    func reviseForMusicModel(_ text: String, field: MusicPromptField, targetTokens: Int) async throws -> String? {
        let guidance = field == .lyrics
            ? "Keep the language, story, section labels, and closing lines. Keep repeated refrains identical. Use fewer, shorter lines with common words that are easy to sing clearly."
            : "Keep the genre, mood, tempo, instruments, core idea, and instrumental choice or vocal details such as diction and placement in the mix. Use a compact description."
        let prompt = "Rewrite this song \(field.rawValue) to fit within about \(targetTokens) music-model tokens (aim for \(max(4, targetTokens / 2)) words or fewer). \(guidance) Return only the revised \(field.rawValue). Do not add commentary or Markdown fences.\n\n\(text)"
        return try await preferredCompletion(prompt, localLimit: max(32, targetTokens))
    }

    // The overload accepts a key explicitly so the transport can be tested without Keychain.
    func writeLyrics(for request: MusicGenerationRequest, apiKey: String) async throws -> String {
        try await complete(lyricsPrompt(for: request), apiKey: apiKey)
    }

    func polish(_ text: String, kind: String, idea: String, styles: String) async throws -> String {
        guard let revised = try await preferredCompletion(polishPrompt(text, kind: kind, idea: idea, styles: styles),
                                                          localLimit: kind == "lyrics" ? 420 : 150) else {
            throw GeminiLyricsError.missingKey
        }
        return revised
    }

    func polish(_ text: String, kind: String, idea: String, styles: String, apiKey: String) async throws -> String {
        try await complete(polishPrompt(text, kind: kind, idea: idea, styles: styles), apiKey: apiKey)
    }

    private func lyricsPrompt(for request: MusicGenerationRequest) -> String {
        """
        Write original lyrics for a song matching this description: \(request.style).
        Use the requested language. Follow one coherent story or image, with a consistent speaker and a chorus that follows naturally from the verse. Use short, complete phrases with familiar words and an even rhythm, about five to nine syllables per line. Keep the chorus wording identical if it repeats. Use [Verse], [Chorus], and [Outro] section labels and aim for 12 to 16 short sung lines. Return lyrics only. Leave out titles, explanations, vocal filler, and production notes unless explicitly requested. Do not imitate a named artist or quote existing songs.
        """
    }

    private func polishPrompt(_ text: String, kind: String, idea: String, styles: String) -> String {
        "Polish the following \(kind) for a song. Preserve the author's meaning, language, and creative intent; improve clarity and expression. For lyrics, preserve section labels and make the lines singable. For song ideas and styles, keep it under 50 words. Return only the revised \(kind), with no explanation or markdown fence. Song idea: \(idea)\nStyles: \(styles)\nText to polish:\n\(text)"
    }

    private func preferredCompletion(_ instruction: String, localLimit: Int) async throws -> String? {
        guard let key = try readKey(), !key.isEmpty else {
            return try await localCompletion(instruction, localLimit)
        }
        do {
            return try await complete(instruction, apiKey: key)
        } catch let error as URLError where Self.connectivityErrors.contains(error.code) {
            try Task.checkCancellation()
            guard let text = try await localCompletion(instruction, localLimit) else {
                throw GeminiLyricsError.offlineModelUnavailable
            }
            return text
        }
    }

    private static let connectivityErrors: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
        .dnsLookupFailed, .timedOut, .dataNotAllowed, .internationalRoamingOff
    ]

    private func complete(_ instruction: String, apiKey: String, maxOutputTokens: Int = 2048, timeout: TimeInterval = 90) async throws -> String {
        let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-4-neon:generateContent")!
        var http = URLRequest(url: endpoint, timeoutInterval: timeout)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let body: [String: Any] = ["contents": [["parts": [["text": instruction]]]], "generationConfig": ["maxOutputTokens": maxOutputTokens, "thinkingConfig": ["thinkingLevel": "LOW"]]]
        http.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: http)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw GeminiLyricsError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw GeminiLyricsError.rejected(response.statusCode) }
        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        guard let candidate = decoded.candidates?.first, candidate.finishReason == "STOP" else { throw GeminiLyricsError.invalidResponse }
        let lyrics = candidate.content.parts.filter { $0.thought != true }.compactMap(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lyrics.isEmpty else { throw GeminiLyricsError.empty }
        return lyrics
    }

    private struct GeminiResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String?; let thought: Bool? }
                let parts: [Part]
            }
            let content: Content
            let finishReason: String?
        }
        let candidates: [Candidate]?
    }
}

private enum AppleSongwriting {
    static func complete(_ instruction: String, limit: Int) async throws -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            let session = LanguageModelSession(instructions: "Help write concise, original songs. Follow the requested output format and return the text only.")
            let response = try await session.respond(to: instruction,
                                                     options: GenerationOptions(temperature: 0.65, maximumResponseTokens: limit))
            try Task.checkCancellation()
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        #endif
        return nil
    }
}
