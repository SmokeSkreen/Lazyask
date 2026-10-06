import Foundation

public enum AudioSource: String, Codable, Sendable, CaseIterable {
    case system
    case mic

    public var label: String { self == .system ? "Meeting" : "You" }
}

public struct AudioChunk: Sendable {
    public let source: AudioSource
    public let pcm16: Data
    public let sampleRate: Int
    public let timestampMs: Double

    public init(source: AudioSource, pcm16: Data, sampleRate: Int = 24_000, timestampMs: Double) {
        self.source = source
        self.pcm16 = pcm16
        self.sampleRate = sampleRate
        self.timestampMs = timestampMs
    }

    public var durationMs: Double { Double(pcm16.count / 2) / Double(sampleRate) * 1_000 }

    public var rms: Double {
        guard pcm16.count >= 2 else { return 0 }
        return pcm16.withUnsafeBytes { bytes in
            var sum = 0.0
            for offset in stride(from: 0, to: bytes.count - 1, by: 2) {
                let sample = Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self))
                let value = Double(sample) / 32_768
                sum += value * value
            }
            return sqrt(sum / Double(bytes.count / 2))
        }
    }
}

public struct TranscriptSegment: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let source: AudioSource
    public var text: String
    public var startMs: Double
    public var endMs: Double
    public var isFinal: Bool

    public init(id: String = UUID().uuidString, source: AudioSource, text: String,
                startMs: Double, endMs: Double, isFinal: Bool = true) {
        self.id = id
        self.source = source
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.isFinal = isFinal
    }
}

public struct TranscriptBuffer: Sendable {
    public private(set) var segments: [TranscriptSegment] = []
    public var retentionMs: Double
    private let maxSegments: Int
    private let maxCharacters: Int

    public init(retentionMs: Double = .infinity, maxSegments: Int = .max,
                maxCharacters: Int = .max, segments: [TranscriptSegment] = []) {
        self.retentionMs = retentionMs
        self.maxSegments = max(1, maxSegments)
        self.maxCharacters = max(1, maxCharacters)
        self.segments = segments.sorted { ($0.startMs, $0.id) < ($1.startMs, $1.id) }
    }

    public mutating func upsert(_ segment: TranscriptSegment, nowMs: Double) {
        guard segment.endMs >= nowMs - retentionMs else { return }
        var bounded = segment
        bounded.text = String(segment.text.suffix(maxCharacters))
        if let index = segments.firstIndex(where: { $0.id == segment.id }) {
            // A late partial event must not replace an already-final transcript.
            guard !segments[index].isFinal || segment.isFinal else { return }
            segments[index] = bounded
        } else {
            segments.append(bounded)
        }
        segments.sort { ($0.startMs, $0.id) < ($1.startMs, $1.id) }
        prune(nowMs: nowMs)
    }

    public mutating func prune(nowMs: Double) {
        guard retentionMs.isFinite || maxSegments != .max || maxCharacters != .max else { return }
        segments.removeAll { $0.endMs < nowMs - retentionMs }
        var characters = segments.reduce(0) { $0 + $1.text.count }
        while segments.count > maxSegments || characters > maxCharacters {
            characters -= segments.removeFirst().text.count
        }
    }

    public mutating func clear() { segments.removeAll() }
}
