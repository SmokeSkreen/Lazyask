import Foundation
import Testing
@testable import LazyAskCore

@Suite("Voice triggers")
struct TriggerTests {
    @Test(arguments: ["I'm not sure, Lazy Ask.", "I am not sure ... LAZY ASK!", "I'm really not sure, Lazyask", "I\u{2019}m not sure, lazy-ask, please"])
    func uncertaintyPhrase(text: String) {
        #expect(WakePhrase.detect(text) == .latestQuestion)
    }

    @Test func directQuestion() {
        #expect(WakePhrase.detect("Lazy Ask, what is a cache?") == .direct("what is a cache"))
        #expect(WakePhrase.detect("Hey, Lazy Ask: explain the difference.") == .direct("explain the difference"))
    }

    @Test func incompleteAndUnrelatedText() {
        #expect(WakePhrase.detect("I'm not sure, lazy") == nil)
        #expect(WakePhrase.detect("We can ask a question later") == nil)
        #expect(WakePhrase.detect("lazily asking") == nil)
        #expect(WakePhrase.detect("Lazy Ask") == .awaitingQuestion)
    }

    @Test func onlyFinalMicrophoneCanTrigger() {
        var detector = VoiceTriggerDetector()
        #expect(detector.consume(segment("Lazy Ask, what is a cache?", source: .system)) == nil)
        #expect(detector.consume(segment("Lazy Ask, what is a cache?", final: false)) == nil)
        #expect(detector.consume(segment("Lazy Ask, what is a cache?"))?.intent == .direct("what is a cache"))
    }

    @Test func phraseAcrossSpeechTurns() {
        var detector = VoiceTriggerDetector()
        #expect(detector.consume(segment("I'm not sure, Lazy", start: 0, end: 500)) == nil)
        #expect(detector.consume(segment("Ask.", start: 900, end: 1_400))?.intent == .latestQuestion)
    }

    @Test func followUpAfterBareWakePhrase() {
        var detector = VoiceTriggerDetector()
        #expect(detector.consume(segment("Lazy Ask", start: 0, end: 500))?.intent == .awaitingQuestion)
        #expect(detector.consume(segment("What is a cache?", start: 1_000, end: 1_700))?.intent == .direct("What is a cache?"))
    }

    @Test func staleWakeDoesNotCaptureLaterSpeech() {
        var detector = VoiceTriggerDetector()
        _ = detector.consume(segment("Lazy Ask", start: 0, end: 500))
        #expect(detector.consume(segment("What is a cache?", start: 9_000, end: 10_000)) == nil)
    }

    @Test func duplicateFinalNeverFiresAgain() {
        var detector = VoiceTriggerDetector()
        let command = segment("I'm not sure, Lazy Ask")
        #expect(detector.consume(command) != nil)
        #expect(detector.consume(command) == nil)
        _ = detector.consume(segment("Thank you", start: 2_000, end: 2_500))
        #expect(detector.consume(command) == nil)
    }
}

@Suite("Question selection")
struct QuestionTests {
    @Test func latestActualQuestion() {
        let items = [segment("What is HTTP?", source: .system, start: 0),
                     segment("Let's discuss our product list. How would a cache help?", source: .system, start: 1_000),
                     segment("I'm not sure, Lazy Ask", start: 2_000)]
        #expect(QuestionExtractor.latest(in: items, beforeMs: 2_000) == "How would a cache help?")
    }

    @Test func punctuationMissing() {
        #expect(QuestionExtractor.latest(in: [segment("Could you explain caching", source: .system)], beforeMs: 1_000)
                == "Could you explain caching")
    }

    @Test func lateArrivalUsesSpeechTime() {
        let items = [segment("What is new?", source: .system, start: 2_000),
                     segment("What is old?", source: .system, start: 100)]
        #expect(QuestionExtractor.latest(in: items, beforeMs: 1_000) == "What is old?")
        #expect(QuestionExtractor.latest(in: items, beforeMs: 3_000) == "What is new?")
    }

    @Test func noQuestionDoesNotGuess() {
        #expect(QuestionExtractor.latest(in: [segment("The list is slow.", source: .system)], beforeMs: 1_000) == nil)
        #expect(throws: LazyAskError.self) {
            try AnswerRequest.build(intent: .latestQuestion, triggerText: "Lazy Ask", segments: [], beforeMs: 1_000)
        }
    }

    @Test func directQuestionUsesContextWithoutWakeCommands() throws {
        let context = [segment("Our list has 500 products.", source: .system), segment("Lazy Ask, help me", start: 500)]
        let request = try AnswerRequest.build(intent: .direct("How can we improve it?"), triggerText: "test",
                                             segments: context, beforeMs: 1_000)
        #expect(request.question == "How can we improve it?")
        #expect(request.context.count == 1)
    }
}

func segment(_ text: String, source: AudioSource = .mic, start: Double = 0,
             end: Double = 500, final: Bool = true) -> TranscriptSegment {
    TranscriptSegment(source: source, text: text, startMs: start, endMs: max(start, end), isFinal: final)
}
