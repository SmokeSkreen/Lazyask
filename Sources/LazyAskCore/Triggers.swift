import Foundation

public enum AskIntent: Equatable, Sendable {
    case latestQuestion
    case direct(String)
    case awaitingQuestion
}

public enum WakePhrase {
    private static let pattern = #"\blazy[\s,\-]*ask\b"#

    public static func detect(_ text: String) -> AskIntent? {
        let normalized = text.replacingOccurrences(of: "\u{2019}", with: "'")
        guard let range = normalized.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let before = String(normalized[..<range.lowerBound]).lowercased()
        let after = String(normalized[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if after.isEmpty || ["please", "thanks", "thank you"].contains(after.lowercased()) {
            let unsure = before.range(of: #"\b(i'?m|i am)\s+(really\s+)?not\s+sure\b"#,
                                     options: .regularExpression) != nil
            return unsure ? .latestQuestion : .awaitingQuestion
        }
        return .direct(after)
    }

    public static func contains(_ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

public struct VoiceTrigger: Sendable, Equatable {
    public let intent: AskIntent
    public let text: String
    public let timestampMs: Double
}

public struct VoiceTriggerDetector: Sendable {
    private var recent: [TranscriptSegment] = []
    private var seen: [String: Double] = [:]
    private var newestStartMs = -Double.infinity
    private var pendingWake: TranscriptSegment?

    public init() {}

    public mutating func consume(_ segment: TranscriptSegment) -> VoiceTrigger? {
        guard segment.source == .mic, segment.isFinal, seen[segment.id] == nil,
              segment.startMs >= newestStartMs else { return nil }
        newestStartMs = segment.startMs
        recent.removeAll { $0.endMs < segment.startMs - 6_000 }
        seen = seen.filter { $0.value >= segment.startMs - 60_000 }
        seen[segment.id] = segment.endMs
        if let pending = pendingWake {
            pendingWake = nil
            if segment.startMs >= pending.startMs, segment.startMs - pending.endMs <= 6_000,
               WakePhrase.detect(segment.text) == nil {
                recent.removeAll()
                return VoiceTrigger(intent: .direct(segment.text), text: pending.text + " " + segment.text,
                                    timestampMs: segment.startMs)
            }
        }
        if let last = recent.last, segment.startMs < last.startMs {
            return nil
        }
        recent.append(segment)
        let combined = recent.map(\.text).joined(separator: " ")
        guard let intent = WakePhrase.detect(combined) else { return nil }
        recent.removeAll()
        if intent == .awaitingQuestion { pendingWake = segment }
        return VoiceTrigger(intent: intent, text: combined, timestampMs: segment.startMs)
    }

    public mutating func reset() {
        recent.removeAll()
        seen.removeAll()
        newestStartMs = -Double.infinity
        pendingWake = nil
    }
}

public enum QuestionExtractor {
    public static func latest(in segments: [TranscriptSegment], beforeMs: Double) -> String? {
        let candidates = segments.filter {
            $0.startMs <= beforeMs && !WakePhrase.contains($0.text) && !$0.text.isEmpty
        }.sorted { $0.startMs > $1.startMs }
        for segment in candidates {
            let sentences = segment.text.components(separatedBy: CharacterSet(charactersIn: ".!\n"))
            for sentence in sentences.reversed() {
                let value = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                if let mark = value.lastIndex(of: "?") {
                    let questions = String(value[...mark]).components(separatedBy: "?")
                        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    if let question = questions.last { return question.trimmingCharacters(in: .whitespaces) + "?" }
                }
                let prefix = #"^(?:so[ ,]+|and[ ,]+|okay[ ,]+|well[ ,]+)?(?:what|why|how|when|where|who|which|whose|can|could|would|should|will|do|does|did|is|are|have|has|tell me|explain|walk (?:me|us) through)\b"#
                if value.range(of: prefix, options: [.regularExpression, .caseInsensitive]) != nil {
                    return value
                }
            }
        }
        return nil
    }
}

public struct AnswerRequest: Codable, Sendable, Equatable {
    public let triggerText: String
    public let question: String
    public let context: [TranscriptSegment]

    public init(triggerText: String, question: String, context: [TranscriptSegment]) {
        self.triggerText = triggerText
        self.question = question
        self.context = context
    }

    public static func build(intent: AskIntent, triggerText: String, segments: [TranscriptSegment],
                             beforeMs: Double) throws -> AnswerRequest {
        let available = segments.filter { $0.startMs <= beforeMs && !WakePhrase.contains($0.text) }
        var context: [TranscriptSegment] = []
        var characters = 0
        for segment in available.reversed() {
            guard context.count < 600 else { break }
            let remaining = 60_000 - characters
            guard remaining > 0 else { break }
            var bounded = segment
            bounded.text = String(segment.text.suffix(remaining))
            context.append(bounded)
            characters += bounded.text.count
        }
        context.reverse()
        let question: String
        switch intent {
        case .direct(let text):
            question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .latestQuestion:
            guard let latest = QuestionExtractor.latest(in: available, beforeMs: beforeMs) else {
                throw LazyAskError.noQuestion
            }
            question = latest
        case .awaitingQuestion:
            throw LazyAskError.noQuestion
        }
        guard !question.isEmpty else { throw LazyAskError.noQuestion }
        return AnswerRequest(triggerText: triggerText, question: question, context: context)
    }
}

public enum LazyAskError: LocalizedError, Sendable {
    case noQuestion
    case api(String)
    case disconnected
    case invalidAudio
    case permission(String)

    public var errorDescription: String? {
        switch self {
        case .noQuestion: "I couldn't find a recent question. Ask Lazy Ask your question directly."
        case .api(let message): message
        case .disconnected: "The live connection ended. Start listening again to reconnect."
        case .invalidAudio: "The audio format could not be converted. Check your input device and start again."
        case .permission(let message): message
        }
    }
}
