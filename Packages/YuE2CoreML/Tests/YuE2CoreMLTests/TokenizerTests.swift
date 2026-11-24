import Foundation
import Testing
@testable import YuE2CoreML

@Test func tokenizerCoversUnicodeAndMergesByRank() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    var ranks = (0...255).map { "\(Data([UInt8($0)]).base64EncodedString()) \($0)" }
    ranks.append("\(Data("ab".utf8).base64EncodedString()) 256")
    try ranks.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    let encoder = try Tokenizer(url: url)
    #expect(try encoder.encode("ab") == [256])
    let text = "e\u{0301} 🎧\n"
    #expect(try encoder.encode(text) == text.utf8.map(Int.init))
}
