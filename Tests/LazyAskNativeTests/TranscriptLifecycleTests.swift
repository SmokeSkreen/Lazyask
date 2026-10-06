import Foundation
import LazyAskCore
import Testing
@testable import LazyAsk

@Suite("Transcript lifecycle")
struct TranscriptLifecycleTests {
    @Test @MainActor func stopAndReopenKeepHistoryAndDemoStaysSeparate() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("meetings.sqlite3")
        let model = AppModel(databaseURL: url, apiKeyOverride: "")
        #expect(model.isHome)
        model.beginEdit(.newMeeting(nil))
        model.nameDraft = "Meeting A"
        model.saveEdit()
        let id = try #require(model.selectedMeetingID)
        let real = TranscriptSegment(source: .system, text: "Our real meeting history.", startMs: 1, endMs: 2)
        model.accept(real)
        await model.stopListening()
        #expect(model.segments == [real])
        let reopened = AppModel(databaseURL: url, apiKeyOverride: "")
        #expect(reopened.isHome)
        await reopened.openMeeting(id)
        #expect(reopened.segments == [real])
        reopened.runDemo()
        reopened.clearConversation()
        await reopened.stopListening()
        await Task.yield()
        #expect(reopened.segments == [real])
        let store = try MeetingLibrary(url: url)
        #expect(try store.transcript(meetingID: id) == [real])
        reopened.clearConversation()
        reopened.accept(real)
        await reopened.stopListening()
        #expect(reopened.segments.isEmpty)
        #expect(try store.transcript(meetingID: id).isEmpty)
    }

    @Test @MainActor func switchingMeetingsKeepsTranscriptsAndAnswerContextSeparate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(databaseURL: root.appendingPathComponent("library.sqlite3"), apiKeyOverride: "")
        model.beginEdit(.newMeeting(nil))
        model.nameDraft = "A"
        model.saveEdit()
        let a = try #require(model.selectedMeetingID)
        let textA = TranscriptSegment(source: .system, text: "Private context A", startMs: 1, endMs: 2)
        model.accept(textA)
        await model.goHome()
        #expect(model.isHome)
        #expect(model.segments.isEmpty)
        model.beginEdit(.newMeeting(nil))
        model.nameDraft = "B"
        model.saveEdit()
        let b = try #require(model.selectedMeetingID)
        let textB = TranscriptSegment(source: .system, text: "Context B", startMs: 3, endMs: 4)
        model.accept(textB)
        #expect(model.segments == [textB])
        let request = try AnswerRequest.build(intent: .direct("Explain"), triggerText: "test", segments: model.segments, beforeMs: 10)
        #expect(request.context == [textB])
        await model.openMeeting(a)
        #expect(model.segments == [textA])
        await model.confirmDeletion(.meeting(a))
        #expect(model.isHome)
        #expect(model.meetings.count == 1)
        await model.openMeeting(b)
        #expect(model.segments == [textB])
    }

    @Test @MainActor func foldersRenameMoveAndDeleteRefreshTheHomeScreen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(databaseURL: root.appendingPathComponent("library.sqlite3"), apiKeyOverride: "")
        model.beginEdit(.newFolder)
        model.nameDraft = "Work"
        model.saveEdit()
        let folder = try #require(model.folders.first?.id)
        #expect(model.folderFilter == folder)
        model.beginEdit(.newMeeting(folder))
        model.nameDraft = "Meeting"
        model.saveEdit()
        let id = try #require(model.selectedMeetingID)
        await model.goHome()
        model.beginEdit(.renameMeeting(id))
        model.nameDraft = "Renamed meeting"
        model.saveEdit()
        model.beginEdit(.renameFolder(folder))
        model.nameDraft = "Research"
        model.saveEdit()
        #expect(model.filteredMeetings.first?.name == "Renamed meeting")
        #expect(model.homeTitle == "Research")
        model.meetingSearch = "renamed"
        #expect(model.filteredMeetings.count == 1)
        model.meetingSearch = "missing"
        #expect(model.filteredMeetings.isEmpty)
        model.meetingSearch = ""
        model.moveMeeting(id, to: nil)
        #expect(model.filteredMeetings.isEmpty)
        model.moveMeeting(id, to: folder)
        await model.confirmDeletion(.folder(folder))
        #expect(model.folderFilter == "")
        #expect(model.filteredMeetings.first?.id == id)
    }
}
