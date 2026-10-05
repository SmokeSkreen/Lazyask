import Foundation

public enum RealtimeProtocol {
    public static let endpoint = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!

    public static func configuration(languages: [String] = []) throws -> String {
        struct Event: Encodable {
            let type = "session.update"
            let session: Session
        }
        struct Session: Encodable {
            let type = "transcription"
            let audio: Audio
        }
        struct Audio: Encodable { let input: Input }
        struct Input: Encodable {
            let format = Format()
            let transcription: Transcription
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: Keys.self)
                try container.encode(format, forKey: .format)
                try container.encode(transcription, forKey: .transcription)
                try container.encodeNil(forKey: .turnDetection)
            }
            enum Keys: String, CodingKey { case format, transcription, turnDetection = "turn_detection" }
        }
        struct Format: Encodable { let type = "audio/pcm"; let rate = 24_000 }
        struct Transcription: Encodable {
            let model = "gpt-live-transcribe"
            let prompt = "A live meeting. The assistant's name is Lazy Ask. Preserve questions and the words Lazy Ask."
            let keywords = ["Lazy Ask", "Lazyask"]
            let languages: [String]?
        }
        let event = Event(session: Session(audio: Audio(input: Input(transcription: Transcription(
            languages: languages.isEmpty ? nil : languages
        )))))
        return String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
    }

    public static func append(_ data: Data) throws -> String {
        struct Event: Encodable { let type = "input_audio_buffer.append"; let audio: String }
        return String(decoding: try JSONEncoder().encode(Event(audio: data.base64EncodedString())), as: UTF8.self)
    }

    public static let commit = #"{"type":"input_audio_buffer.commit"}"#
    public static let clear = #"{"type":"input_audio_buffer.clear"}"#
}

public struct RealtimeServerEvent: Decodable, Sendable {
    public let type: String
    public let itemID: String?
    public let delta: String?
    public let transcript: String?
    public let error: APIErrorDetail?

    enum CodingKeys: String, CodingKey {
        case type, delta, transcript, error
        case itemID = "item_id"
    }
}

public struct APIErrorDetail: Decodable, Sendable {
    public let message: String?
    public let code: String?
}

public struct RealtimeTranscriptTracker: Sendable {
    private let source: AudioSource
    private var pending: [TurnTiming] = []
    private var timings: [String: TurnTiming] = [:]
    private var texts: [String: String] = [:]
    private var finalized: Set<String> = []
    private var itemOrder: [String] = []
    public var activeTiming: TurnTiming?

    public init(source: AudioSource) { self.source = source }

    public mutating func committed(_ timing: TurnTiming) throws {
        guard pending.count < 100 else { throw LazyAskError.api("Transcription is falling behind. Start listening again.") }
        pending.append(timing)
    }

    public mutating func receive(_ event: RealtimeServerEvent, nowMs: Double) throws -> TranscriptSegment? {
        if event.type == "error" || event.type == "conversation.item.input_audio_transcription.failed" {
            throw LazyAskError.api(event.error?.message ?? "Live transcription failed.")
        }
        guard let id = event.itemID else { return nil }
        if event.type == "input_audio_buffer.committed" {
            timings[id] = pending.isEmpty ? (activeTiming ?? TurnTiming(startMs: nowMs, endMs: nowMs)) : pending.removeFirst()
            if !itemOrder.contains(id) { itemOrder.append(id) }
            while itemOrder.count > 600 {
                let old = itemOrder.removeFirst()
                timings.removeValue(forKey: old)
                texts.removeValue(forKey: old)
                finalized.remove(old)
            }
            return nil
        }
        let final = event.type == "conversation.item.input_audio_transcription.completed"
        guard final || event.type == "conversation.item.input_audio_transcription.delta" else { return nil }
        guard !finalized.contains(id) else { return nil }
        let text: String
        if final {
            text = event.transcript ?? texts[id] ?? ""
            finalized.insert(id)
            texts.removeValue(forKey: id)
        } else {
            text = (texts[id] ?? "") + (event.delta ?? "")
            texts[id] = String(text.suffix(12_000))
        }
        if timings[id] == nil {
            timings[id] = pending.first ?? activeTiming ?? TurnTiming(startMs: nowMs, endMs: nowMs)
        }
        let timing = timings[id]!
        return TranscriptSegment(id: source.rawValue + ":" + id, source: source,
                                 text: String(text.suffix(12_000)), startMs: timing.startMs,
                                 endMs: timing.endMs, isFinal: final)
    }
}
