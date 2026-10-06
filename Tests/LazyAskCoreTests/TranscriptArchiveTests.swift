import Foundation
import Testing
@testable import LazyAskCore

@Suite("Saved transcript")
struct TranscriptArchiveTests {
    @Test func unlimitedBufferKeepsOldAndLargeHistory() {
        let items = (0..<700).map { segment("Old meeting text", source: .system, start: Double($0), end: Double($0 + 1)) }
        var buffer = TranscriptBuffer(segments: items)
        buffer.upsert(segment(String(repeating: "x", count: 70_000), start: 800, end: 900), nowMs: 1_000_000_000)
        buffer.prune(nowMs: 2_000_000_000)
        #expect(buffer.segments.count == 701)
        #expect(buffer.segments.last?.text.count == 70_000)
        buffer.clear()
        #expect(buffer.segments.isEmpty)
    }

    @Test func historySurvivesReloadAndClearDeletesFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("transcript.json")
        let archive = TranscriptArchive(url: url)
        let final = segment("What is a cache?", source: .system)
        try await archive.save([final, segment("unfinished", final: false)], revision: 1)
        #expect(try TranscriptArchive.load(from: url) == [final])
        try await archive.save([], revision: 2)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try TranscriptArchive.load(from: url).isEmpty)
        try await archive.save([final], revision: 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func invalidHistoryIsNotSilentlyDiscarded() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        #expect(throws: DecodingError.self) { try TranscriptArchive.load(from: url) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "not json")
    }

    @Test func answerContextIsBoundedWithoutDeletingHistory() throws {
        let items = (0..<700).map { segment(String(repeating: "text ", count: 30), source: .system,
                                          start: Double($0), end: Double($0 + 1)) }
        let buffer = TranscriptBuffer(segments: items)
        let request = try AnswerRequest.build(intent: .direct("Summarize"), triggerText: "test",
                                              segments: buffer.segments, beforeMs: 1_000)
        #expect(request.context.count <= 600)
        #expect(request.context.reduce(0) { $0 + $1.text.count } <= 60_000)
        #expect(buffer.segments.count == 700)
        #expect(request.context.last?.id == items.last?.id)
    }
}
