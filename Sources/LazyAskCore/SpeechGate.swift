import Foundation

public struct TurnTiming: Sendable, Equatable {
    public var startMs: Double
    public var endMs: Double

    public init(startMs: Double, endMs: Double) {
        self.startMs = startMs
        self.endMs = endMs
    }
}

public enum AudioCommand: Sendable, Equatable {
    case append(Data)
    case commit(TurnTiming)
    case clear
}

// A small energy gate bounds silence uploads and commits turns locally.
public struct SpeechGate: Sendable {
    private let threshold: Double
    private let silenceMs: Double
    private let maxTurnMs: Double
    private var preRoll: [AudioChunk] = []
    private var active: TurnTiming?
    private var lastSpeechMs = 0.0

    public init(threshold: Double = 0.008, silenceMs: Double = 800, maxTurnMs: Double = 15_000) {
        self.threshold = threshold
        self.silenceMs = silenceMs
        self.maxTurnMs = maxTurnMs
    }

    public var currentTiming: TurnTiming? { active }

    public mutating func consume(_ chunk: AudioChunk) -> [AudioCommand] {
        guard chunk.sampleRate == 24_000, !chunk.pcm16.isEmpty else { return [] }
        let end = chunk.timestampMs + chunk.durationMs
        let speaking = chunk.rms >= threshold
        var commands: [AudioCommand] = []
        if active == nil {
            preRoll.append(chunk)
            preRoll.removeAll { $0.timestampMs + $0.durationMs < chunk.timestampMs - 250 }
            guard speaking else { return [] }
            active = TurnTiming(startMs: preRoll.first?.timestampMs ?? chunk.timestampMs, endMs: end)
            var prefix = Data()
            preRoll.forEach { prefix.append($0.pcm16) }
            commands.append(.append(prefix))
            preRoll.removeAll()
        } else {
            active?.endMs = end
            commands.append(.append(chunk.pcm16))
        }
        if speaking {
            lastSpeechMs = end
        }
        if let timing = active,
           end - lastSpeechMs >= silenceMs || timing.endMs - timing.startMs >= maxTurnMs {
            commands += finish()
        }
        return commands
    }

    public mutating func flushIfIdle(nowMs: Double) -> [AudioCommand] {
        guard let timing = active, nowMs - timing.endMs >= silenceMs else { return [] }
        return finish()
    }

    private mutating func finish() -> [AudioCommand] {
        guard let timing = active else { return [] }
        active = nil
        preRoll.removeAll()
        // The API needs at least 100 ms of input for a commit.
        return timing.endMs - timing.startMs >= 100 ? [.commit(timing)] : [.clear]
    }
}
