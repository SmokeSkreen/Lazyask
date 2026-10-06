import Foundation
import Testing
@testable import LazyAskCore

@Suite("Lazy Meeting library")
struct MeetingLibraryTests {
    @Test func meetingsAndFoldersSurviveReopeningWithNamesAndMoves() throws {
        let root = temporaryLibraryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("meetings.sqlite3")
        let library = try MeetingLibrary(url: url)
        let folder = try library.createFolder(name: " Work ")
        let id = try library.createMeeting(name: " Monday meeting ", folderID: folder)
        try library.renameMeeting(id: id, name: "O'Brien's meeting \u{1f4dd}")
        try library.renameFolder(id: folder, name: "Project notes")
        let reopened = try MeetingLibrary(url: url)
        #expect(try reopened.meetings().first?.name == "O'Brien's meeting \u{1f4dd}")
        #expect(try reopened.meetings().first?.folderID == folder)
        #expect(try reopened.folders().first?.name == "Project notes")
        try reopened.moveMeeting(id: id, folderID: nil)
        #expect(try library.meetings().first?.folderID == nil)
    }

    @Test func transcriptIDsAreIsolatedAndFinalUpdatesDoNotDuplicate() throws {
        let root = temporaryLibraryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try MeetingLibrary(url: root.appendingPathComponent("library.sqlite3"))
        let a = try library.createMeeting(name: "A")
        let b = try library.createMeeting(name: "B")
        var first = TranscriptSegment(id: "same-id", source: .system, text: "A question?", startMs: 10, endMs: 20)
        var second = first
        second.text = "B question?"
        try library.saveSegment(first, meetingID: a)
        try library.saveSegment(second, meetingID: b)
        first.text = "A corrected question?"
        try library.saveSegment(first, meetingID: a)
        #expect(try library.transcript(meetingID: a) == [first])
        #expect(try library.transcript(meetingID: b) == [second])
        #expect(try library.meetings().first { $0.id == a }?.segmentCount == 1)
        #expect(try library.meetings().first { $0.id == a }?.preview == first.text)
    }

    @Test func deletingFolderPreservesMeetingsAndDeletingMeetingCannotResurrect() throws {
        let root = temporaryLibraryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try MeetingLibrary(url: root.appendingPathComponent("library.sqlite3"))
        let folder = try library.createFolder(name: "Folder")
        let id = try library.createMeeting(name: "Keep me", folderID: folder)
        let text = segment("Retained transcript", source: .system)
        try library.saveSegment(text, meetingID: id)
        try library.deleteFolder(id: folder)
        #expect(try library.folders().isEmpty)
        #expect(try library.meetings().first?.folderID == nil)
        #expect(try library.transcript(meetingID: id) == [text])
        try library.deleteMeeting(id: id)
        #expect(try library.meetings().isEmpty)
        #expect(throws: LibraryError.self) { try library.saveSegment(text, meetingID: id) }
        #expect(throws: LibraryError.self) { try library.transcript(meetingID: id) }
        #expect(try library.meetings().isEmpty)
    }

    @Test func clearOnlyAffectsTheSelectedMeetingAndPartialsAreNotSaved() throws {
        let root = temporaryLibraryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try MeetingLibrary(url: root.appendingPathComponent("library.sqlite3"))
        let a = try library.createMeeting(name: "A")
        let b = try library.createMeeting(name: "B")
        try library.saveSegment(segment("Final"), meetingID: a)
        let text = segment("Other meeting")
        try library.saveSegment(text, meetingID: b)
        try library.saveSegment(segment("Not finished", final: false), meetingID: b)
        try library.clearTranscript(meetingID: a)
        #expect(try library.transcript(meetingID: a).isEmpty)
        #expect(try library.transcript(meetingID: b) == [text])
        #expect(try library.meetings().first { $0.id == a }?.segmentCount == 0)
        #expect(try library.meetings().first { $0.id == a }?.preview == "")
    }

    @Test func legacyTranscriptMigratesExactlyOnceWithoutLosingText() throws {
        let root = temporaryLibraryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = root.appendingPathComponent("transcript.json")
        let database = root.appendingPathComponent("library.sqlite3")
        let old = [segment("First question?", source: .system), segment("Answer", start: 1_000, end: 1_500)]
        try JSONEncoder().encode(old).write(to: legacy)
        let library = try MeetingLibrary(url: database, legacyArchiveURL: legacy)
        let imported = try #require(library.meetings().first)
        #expect(imported.name == "Imported meeting")
        #expect(try library.transcript(meetingID: imported.id) == old)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        let reopened = try MeetingLibrary(url: database, legacyArchiveURL: legacy)
        #expect(try reopened.meetings().count == 1)
        try reopened.deleteMeeting(id: imported.id)
        let afterDelete = try MeetingLibrary(url: database, legacyArchiveURL: legacy)
        #expect(try afterDelete.meetings().isEmpty)
    }

    @Test func failedMigrationKeepsTheOldFileAndCanBeRetried() throws {
        let root = temporaryLibraryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = root.appendingPathComponent("transcript.json")
        let url = root.appendingPathComponent("library.sqlite3")
        try Data("broken JSON".utf8).write(to: legacy)
        #expect(throws: DecodingError.self) { try MeetingLibrary(url: url, legacyArchiveURL: legacy) }
        #expect(try String(contentsOf: legacy, encoding: .utf8) == "broken JSON")
        let text = segment("Recovered transcript")
        try JSONEncoder().encode([text]).write(to: legacy)
        let retry = try MeetingLibrary(url: url, legacyArchiveURL: legacy)
        let id = try #require(retry.meetings().first?.id)
        #expect(try retry.transcript(meetingID: id) == [text])
    }

    @Test func longHistoryHasNoStorageWindowAndPreviewUsesCaptureOrder() throws {
        let root = temporaryLibraryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try MeetingLibrary(url: root.appendingPathComponent("library.sqlite3"))
        let id = try library.createMeeting(name: "Long meeting")
        let newest = segment("Latest question?", source: .system, start: 10_000, end: 11_000)
        let oldest = segment(String(repeating: "old ", count: 20_000), start: 0)
        try library.saveSegment(newest, meetingID: id)
        try library.saveSegment(oldest, meetingID: id)
        #expect(try library.transcript(meetingID: id) == [oldest, newest])
        #expect(try library.meetings().first?.preview == newest.text)
    }

    @Test func invalidNamesAndMissingFoldersDoNotCreateRecords() throws {
        let root = temporaryLibraryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try MeetingLibrary(url: root.appendingPathComponent("library.sqlite3"))
        #expect(throws: LibraryError.self) { try library.createMeeting(name: "   ") }
        #expect(throws: LibraryError.self) { try library.createFolder(name: String(repeating: "x", count: 121)) }
        #expect(throws: LibraryError.self) { try library.createMeeting(name: "Missing folder", folderID: "missing") }
        #expect(try library.meetings().isEmpty)
        #expect(try library.folders().isEmpty)
    }
}

func temporaryLibraryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("LazyAsk-tests-" + UUID().uuidString)
}
