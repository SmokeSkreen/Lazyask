import Foundation
import LazyAskCore

actor RealtimeClient {
    private let socket: URLSessionWebSocketTask
    private var gate: SpeechGate
    private var tracker: RealtimeTranscriptTracker
    private var outgoing = Data()
    private var closed = false

    init(source: AudioSource, apiKey: String, threshold: Double) {
        var request = URLRequest(url: RealtimeProtocol.endpoint)
        request.timeoutInterval = 15
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        socket = URLSession.shared.webSocketTask(with: request)
        gate = SpeechGate(threshold: threshold)
        tracker = RealtimeTranscriptTracker(source: source)
    }

    func connect(languages: [String]) async throws {
        socket.resume()
        let socket = self.socket
        try await withTaskCancellationHandler {
            try await socket.send(.string(RealtimeProtocol.configuration(languages: languages)))
            while true {
                try Task.checkCancellation()
                let event = try await receiveEvent()
                if event.type == "error" { throw LazyAskError.api(event.error?.message ?? "The live session could not start.") }
                if event.type == "session.updated" || event.type == "transcription_session.updated" { return }
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    // Called by one consumer per source, so appends and commits stay in order.
    func consume(_ event: CaptureEvent) async throws {
        guard !closed else { throw CancellationError() }
        let commands: [AudioCommand]
        switch event {
        case .audio(let chunk): commands = gate.consume(chunk)
        case .tick(let now): commands = gate.flushIfIdle(nowMs: now)
        }
        tracker.activeTiming = gate.currentTiming
        for command in commands {
            try Task.checkCancellation()
            switch command {
            case .append(let data):
                outgoing.append(data)
                if outgoing.count >= 4_800 { try await flushAudio() }
            case .commit(let timing):
                try await flushAudio()
                try tracker.committed(timing)
                try await socket.send(.string(RealtimeProtocol.commit))
            case .clear:
                outgoing.removeAll()
                try await socket.send(.string(RealtimeProtocol.clear))
            }
        }
    }

    func receiveTranscript() async throws -> TranscriptSegment? {
        guard !closed else { throw CancellationError() }
        let event = try await receiveEvent()
        return try tracker.receive(event, nowMs: Date().timeIntervalSince1970 * 1_000)
    }

    func close() {
        closed = true
        outgoing.removeAll()
        socket.cancel(with: .goingAway, reason: nil)
    }

    private func flushAudio() async throws {
        guard !outgoing.isEmpty else { return }
        let data = outgoing
        outgoing.removeAll(keepingCapacity: true)
        try await socket.send(.string(RealtimeProtocol.append(data)))
    }

    private func receiveEvent() async throws -> RealtimeServerEvent {
        let message = try await socket.receive()
        let data: Data
        switch message {
        case .string(let value): data = Data(value.utf8)
        case .data(let value): data = value
        @unknown default: throw LazyAskError.disconnected
        }
        return try JSONDecoder().decode(RealtimeServerEvent.self, from: data)
    }
}
