import Foundation

private final class GeminiStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            body = data
        }
        guard let url = request.url, url.path.contains("gemini-4-neon"),
              let key = request.value(forHTTPHeaderField: "x-goog-api-key") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        if key == "offline-key" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        guard
              let body, let contents = String(data: body, encoding: .utf8),
              (contents.contains("Polish the following lyrics") && contents.contains("original line")) || contents.contains("Reply with one short word") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: key == "bad-key" ? 403 : 200, httpVersion: nil, headerFields: nil)!
        let result = key == "empty-key" ? "" : "Polished line"
        let data = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"\(result)\"}]},\"finishReason\":\"STOP\"}]}".data(using: .utf8)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct GeminiPolishChecks {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiStub.self]
        let writer = GeminiLyricsWriter(session: URLSession(configuration: configuration))
        let result = try await writer.polish("original line", kind: "lyrics", idea: "midnight", styles: "mellow", apiKey: "test-key")
        precondition(result == "Polished line")
        try await writer.testKey("  test-key  ")
        do {
            try await writer.testKey("bad-key")
            preconditionFailure("Rejected keys must fail verification")
        } catch GeminiLyricsError.rejected(403) { }
        do {
            try await writer.testKey("empty-key")
            preconditionFailure("Empty Gemini responses must fail verification")
        } catch GeminiLyricsError.empty { }

        let offline = GeminiLyricsWriter(session: URLSession(configuration: configuration), readKey: { "offline-key" },
                                        localCompletion: { prompt, _ in
            precondition(prompt.contains("original line"))
            return "Polished offline"
        })
        let fallback = try await offline.polish("original line", kind: "lyrics", idea: "midnight", styles: "mellow")
        precondition(fallback == "Polished offline")
        do {
            try await offline.testKey("offline-key")
            preconditionFailure("Key verification must require a real Gemini connection")
        } catch let error as URLError { precondition(error.code == .notConnectedToInternet) }

        let missingKey = GeminiLyricsWriter(readKey: { nil }, localCompletion: { prompt, _ in
            precondition(prompt.contains("Write original lyrics"))
            precondition(prompt.contains("one coherent story") && prompt.contains("chorus wording identical"))
            return "[Verse]\nA local melody"
        })
        let request = MusicPromptBuilder().makeCreateRequest(idea: "the moon", styles: "folk", instrumental: false, seed: 1)
        let localLyrics = try await missingKey.writeLyrics(for: request)
        precondition(localLyrics == "[Verse]\nA local melody")
        print("Gemini, offline songwriting, and key verification checks passed")
    }
}
