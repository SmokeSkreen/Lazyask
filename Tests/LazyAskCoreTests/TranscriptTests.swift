import Foundation
import Testing
@testable import LazyAskCore

@Suite("Rolling transcript")
struct TranscriptTests {
    @Test func evictionDuringSilence() {
        var buffer = TranscriptBuffer(retentionMs: 1_000)
        buffer.upsert(segment("hello", end: 500), nowMs: 500)
        buffer.prune(nowMs: 1_501)
        #expect(buffer.segments.isEmpty)
    }

    @Test func lateExpiredFinalIsIgnored() {
        var buffer = TranscriptBuffer(retentionMs: 1_000)
        buffer.upsert(segment("old audio", end: 500), nowMs: 2_000)
        #expect(buffer.segments.isEmpty)
    }

    @Test func partialUpsertAndNoDowngrade() {
        var buffer = TranscriptBuffer()
        var value = segment("What", final: false)
        buffer.upsert(value, nowMs: 500)
        value.text = "What is a cache?"
        value.isFinal = true
        buffer.upsert(value, nowMs: 600)
        value.isFinal = false
        value.text = "What"
        buffer.upsert(value, nowMs: 700)
        #expect(buffer.segments.count == 1)
        #expect(buffer.segments[0].text == "What is a cache?")
        #expect(buffer.segments[0].isFinal)
    }

    @Test func sortsByCaptureTimeAndBoundsMemory() {
        var buffer = TranscriptBuffer(maxSegments: 2, maxCharacters: 10)
        buffer.upsert(segment("later", start: 1_000, end: 1_500), nowMs: 1_500)
        buffer.upsert(segment("early", start: 0, end: 500), nowMs: 1_500)
        #expect(buffer.segments.map(\.text) == ["early", "later"])
        buffer.upsert(segment("newest", start: 2_000, end: 2_500), nowMs: 2_500)
        #expect(buffer.segments.map(\.text) == ["newest"])
    }

    @Test func outOfOrderCompletionsMatchTheirOwnTurns() throws {
        var tracker = RealtimeTranscriptTracker(source: .system)
        try tracker.committed(TurnTiming(startMs: 100, endMs: 500))
        try tracker.committed(TurnTiming(startMs: 1_000, endMs: 1_500))
        _ = try tracker.receive(event(#"{"type":"input_audio_buffer.committed","item_id":"a"}"#), nowMs: 2_000)
        _ = try tracker.receive(event(#"{"type":"input_audio_buffer.committed","item_id":"b"}"#), nowMs: 2_000)
        let second = try tracker.receive(event(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"b","transcript":"second"}"#), nowMs: 3_000)
        let first = try tracker.receive(event(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":"first"}"#), nowMs: 4_000)
        #expect(second?.startMs == 1_000)
        #expect(first?.startMs == 100)
        #expect(first?.id == "system:a")
    }

    @Test func realtimeConfigurationUsesClientTurnDetection() throws {
        let data = Data(try RealtimeProtocol.configuration(languages: ["en"]).utf8)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let session = try #require(root["session"] as? [String: Any])
        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let transcription = try #require(input["transcription"] as? [String: Any])
        #expect(session["type"] as? String == "transcription")
        #expect(input["turn_detection"] is NSNull)
        #expect(transcription["model"] as? String == "gpt-live-transcribe")
        #expect(transcription["languages"] as? [String] == ["en"])
    }

    @Test func partialTimingSurvivesTheCommitBoundary() throws {
        var tracker = RealtimeTranscriptTracker(source: .system)
        tracker.activeTiming = TurnTiming(startMs: 100, endMs: 500)
        let partial = try event(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"a","delta":"What "}"#)
        #expect(try tracker.receive(partial, nowMs: 800)?.startMs == 100)
        tracker.activeTiming = nil
        try tracker.committed(TurnTiming(startMs: 100, endMs: 900))
        let next = try event(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"a","delta":"is a cache?"}"#)
        #expect(try tracker.receive(next, nowMs: 1_500)?.startMs == 100)
    }
}

func event(_ json: String) throws -> RealtimeServerEvent {
    try JSONDecoder().decode(RealtimeServerEvent.self, from: Data(json.utf8))
}
