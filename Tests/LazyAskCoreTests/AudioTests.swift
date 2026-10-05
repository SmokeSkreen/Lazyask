import Foundation
import Testing
@testable import LazyAskCore

@Suite("Local speech turns")
struct AudioTests {
    @Test func silenceIsNotUploaded() {
        var gate = SpeechGate()
        #expect(gate.consume(chunk(amplitude: 0, start: 0)).isEmpty)
        #expect(gate.consume(chunk(amplitude: 0, start: 100)).isEmpty)
        #expect(gate.flushIfIdle(nowMs: 2_000).isEmpty)
    }

    @Test func keepsPreRollAndCommitsAfterPause() {
        var gate = SpeechGate(silenceMs: 200)
        _ = gate.consume(chunk(amplitude: 0, start: 0))
        let first = gate.consume(chunk(amplitude: 3_000, start: 100))
        guard case .append(let prefix) = first.first else { Issue.record("Missing speech append"); return }
        #expect(prefix.count == 9_600)
        _ = gate.consume(chunk(amplitude: 0, start: 200))
        let ending = gate.consume(chunk(amplitude: 0, start: 300))
        #expect(ending.last == .commit(TurnTiming(startMs: 0, endMs: 400)))
    }

    @Test func finishesWhenSourceStopsSendingSamples() {
        var gate = SpeechGate(silenceMs: 500)
        _ = gate.consume(chunk(amplitude: 3_000, start: 0))
        #expect(gate.flushIfIdle(nowMs: 300).isEmpty)
        #expect(gate.flushIfIdle(nowMs: 600) == [.commit(TurnTiming(startMs: 0, endMs: 100))])
        #expect(gate.flushIfIdle(nowMs: 2_000).isEmpty)
    }

    @Test func longSpeechIsBounded() {
        var gate = SpeechGate(maxTurnMs: 300)
        _ = gate.consume(chunk(amplitude: 3_000, start: 0))
        _ = gate.consume(chunk(amplitude: 3_000, start: 100))
        let ending = gate.consume(chunk(amplitude: 3_000, start: 200))
        #expect(ending.last == .commit(TurnTiming(startMs: 0, endMs: 300)))
    }

    @Test func pcmIsLittleEndianMono24k() {
        let audio = chunk(amplitude: 16_384, start: 0)
        #expect(audio.durationMs == 100)
        #expect(abs(audio.rms - 0.5) < 0.0001)
    }
}

func chunk(amplitude: Int16, start: Double) -> AudioChunk {
    let samples = [Int16](repeating: amplitude.littleEndian, count: 2_400)
    let data = samples.withUnsafeBytes { Data($0) }
    return AudioChunk(source: .mic, pcm16: data, timestampMs: start)
}
