import AppKit
import AVFoundation
import Combine
import LazyAskCore

@MainActor
final class AppModel: ObservableObject {
    enum ListeningState: Equatable {
        case idle, starting, listening, stopping, demo
        var active: Bool { self == .listening || self == .demo }
        var label: String {
            switch self {
            case .idle: "Stopped"
            case .starting: "Connecting"
            case .listening: "Listening"
            case .stopping: "Stopping"
            case .demo: "Demo"
            }
        }
    }

    @Published private(set) var state = ListeningState.idle
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var answer = ""
    @Published private(set) var question = ""
    @Published private(set) var isAnswering = false
    @Published private(set) var answerIsDemo = false
    @Published private(set) var levels: [AudioSource: Double] = [.system: 0, .mic: 0]
    @Published var errorMessage: String?
    @Published var answerError: String?
    @Published var showSettings = false
    @Published var keyDraft = ""
    @Published var questionDraft = ""
    @Published private(set) var hasKey = false
    @Published private(set) var microphoneAllowed = false
    @Published private(set) var screenAllowed = false
    @Published var retentionMinutes: Int { didSet { savePreferences() } }
    @Published var sensitivity: Double { didSet { savePreferences() } }
    @Published var answerModel: String { didSet { savePreferences() } }
    @Published var language: String { didSet { savePreferences() } }
    var onShowOverlay: (() -> Void)?
    var onOpenMain: (() -> Void)?
    var onHideOverlay: (() -> Void)?

    private var apiKey: String
    private var buffer: TranscriptBuffer
    private var triggerDetector = VoiceTriggerDetector()
    private var capture: AudioCapture?
    private var clients: [RealtimeClient] = []
    private var workers: [Task<Void, Never>] = []
    private var startTask: Task<Void, Never>?
    private var answerTask: Task<Void, Never>?
    private var triggerTask: Task<Void, Never>?
    private var demoTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var sessionID = UUID()
    private var answerID = UUID()
    private var lastLevelUpdate: [AudioSource: Double] = [:]

    init() {
        let defaults = UserDefaults.standard
        let retention = defaults.integer(forKey: "retentionMinutes")
        let minutes = [5, 8, 10].contains(retention) ? retention : 8
        retentionMinutes = minutes
        sensitivity = defaults.object(forKey: "sensitivity") as? Double ?? 0.55
        answerModel = defaults.string(forKey: "answerModel") ?? "gpt-4.1-mini"
        language = defaults.string(forKey: "language") ?? ""
        apiKey = KeychainStore.load() ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
        hasKey = !apiKey.isEmpty
        buffer = TranscriptBuffer(retentionMs: Double(minutes) * 60_000)
        refreshPermissions()
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                self.buffer.prune(nowMs: Self.nowMs)
                self.segments = self.buffer.segments
            }
        }
    }

    static var nowMs: Double { Date().timeIntervalSince1970 * 1_000 }

    func refreshPermissions() {
        microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        screenAllowed = CGPreflightScreenCaptureAccess()
    }

    func requestMicrophone() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refreshPermissions()
        if !microphoneAllowed { openPrivacy("Privacy_Microphone") }
    }

    func requestScreen() {
        _ = CGRequestScreenCaptureAccess()
        refreshPermissions()
        if !screenAllowed { openPrivacy("Privacy_ScreenCapture") }
    }

    func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) {
            NSWorkspace.shared.open(url)
        }
    }

    func saveKey() {
        let value = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try KeychainStore.save(value)
            apiKey = value
            hasKey = true
            keyDraft = ""
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func removeKey() {
        do {
            try KeychainStore.remove()
            apiKey = ""
            keyDraft = ""
            hasKey = false
        } catch { errorMessage = error.localizedDescription }
    }

    func toggleListening() {
        if state == .idle { startListening() }
        else { Task { await stopListening() } }
    }

    func startListening() {
        guard state == .idle else { return }
        guard hasKey else {
            showSettings = true
            onOpenMain?()
            errorMessage = "Add your OpenAI API key to start listening."
            return
        }
        let id = UUID()
        sessionID = id
        state = .starting
        errorMessage = nil
        clearConversation()
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                if !self.microphoneAllowed { await self.requestMicrophone() }
                try Task.checkCancellation()
                guard self.microphoneAllowed else {
                    throw LazyAskError.permission("Allow Microphone access in System Settings, then start again.")
                }
                if !self.screenAllowed { self.requestScreen() }
                guard self.screenAllowed else {
                    throw LazyAskError.permission("Allow Screen & System Audio Recording for Lazy Ask in System Settings. Quit and reopen the app if macOS asks you to.")
                }
                let threshold = 0.025 - self.sensitivity * 0.023
                let systemClient = RealtimeClient(source: .system, apiKey: self.apiKey, threshold: threshold)
                let micClient = RealtimeClient(source: .mic, apiKey: self.apiKey, threshold: threshold)
                self.clients = [systemClient, micClient]
                let languages = self.language.isEmpty ? [] : [self.language]
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await systemClient.connect(languages: languages) }
                    group.addTask { try await micClient.connect(languages: languages) }
                    group.addTask {
                        try await Task.sleep(for: .seconds(15))
                        throw LazyAskError.api("The live connection timed out. Check your network and start again.")
                    }
                    _ = try await group.next()
                    _ = try await group.next()
                    group.cancelAll()
                }
                try Task.checkCancellation()
                guard self.sessionID == id else { return }
                let capture = AudioCapture()
                self.capture = capture
                try await capture.start()
                try Task.checkCancellation()
                guard self.sessionID == id else { return }
                self.state = .listening
                self.startWorkers(capture.system, client: systemClient, id: id)
                self.startWorkers(capture.microphone, client: micClient, id: id)
            } catch {
                guard self.sessionID == id else { return }
                if !(error is CancellationError) { self.errorMessage = error.localizedDescription }
                await self.stopListening()
            }
        }
    }

    private func startWorkers(_ events: AsyncThrowingStream<CaptureEvent, Error>, client: RealtimeClient, id: UUID) {
        workers.append(Task { [weak self] in
            do {
                for try await event in events {
                    try Task.checkCancellation()
                    guard let self, self.sessionID == id else { return }
                    if case .audio(let chunk) = event {
                        if Self.nowMs - (self.lastLevelUpdate[chunk.source] ?? 0) > 100 {
                            self.levels[chunk.source] = min(1, chunk.rms * 12)
                            self.lastLevelUpdate[chunk.source] = Self.nowMs
                        }
                    }
                    try await client.consume(event)
                }
            } catch { await self?.handleCaptureFailure(error, id: id) }
        })
        workers.append(Task { [weak self] in
            do {
                while !Task.isCancelled {
                    if let segment = try await client.receiveTranscript() {
                        guard let self, self.sessionID == id else { return }
                        self.accept(segment)
                    }
                }
            } catch { await self?.handleCaptureFailure(error, id: id) }
        })
    }

    private func handleCaptureFailure(_ error: Error, id: UUID) async {
        guard sessionID == id, state != .stopping, !(error is CancellationError) else { return }
        errorMessage = error.localizedDescription
        await stopListening()
        onOpenMain?()
    }

    func stopListening() async {
        guard state != .stopping else { return }
        state = .stopping
        sessionID = UUID()
        startTask?.cancel()
        startTask = nil
        triggerTask?.cancel()
        triggerTask = nil
        demoTask?.cancel()
        demoTask = nil
        cancelAnswer()
        let oldClients = clients
        clients.removeAll()
        for client in oldClients { await client.close() }
        workers.forEach { $0.cancel() }
        workers.removeAll()
        let oldCapture = capture
        capture = nil
        await oldCapture?.stop()
        triggerDetector.reset()
        levels = [.system: 0, .mic: 0]
        state = .idle
    }

    private func accept(_ segment: TranscriptSegment) {
        buffer.upsert(segment, nowMs: Self.nowMs)
        segments = buffer.segments
        guard let trigger = triggerDetector.consume(segment) else { return }
        if trigger.intent == .awaitingQuestion {
            cancelAnswer()
            triggerTask?.cancel()
            question = "Listening for your question..."
            answer = ""
            answerError = nil
            onShowOverlay?()
            return
        }
        triggerTask?.cancel()
        triggerTask = Task { [weak self] in
            // Allow a meeting turn's final event to catch up with the mic stream.
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, let self else { return }
            self.ask(intent: trigger.intent, text: trigger.text, beforeMs: trigger.timestampMs)
        }
    }

    func askLatest() { ask(intent: .latestQuestion, text: "I'm not sure, Lazy Ask", beforeMs: Self.nowMs) }

    func askDirect(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ask(intent: .direct(trimmed), text: trimmed, beforeMs: Self.nowMs)
    }

    private func ask(intent: AskIntent, text: String, beforeMs: Double) {
        cancelAnswer()
        buffer.prune(nowMs: Self.nowMs)
        segments = buffer.segments
        do {
            let request = try AnswerRequest.build(intent: intent, triggerText: text,
                                                 segments: segments, beforeMs: beforeMs)
            guard hasKey || state == .demo else {
                errorMessage = "Add your OpenAI API key to ask a question."
                showSettings = true
                onOpenMain?()
                return
            }
            let id = UUID()
            answerID = id
            question = request.question
            answer = ""
            answerError = nil
            isAnswering = true
            answerIsDemo = state == .demo
            let service: any AnswerService = answerIsDemo ? DemoAnswerService()
                : OpenAIAnswerService(apiKey: apiKey, model: answerModel)
            onShowOverlay?()
            answerTask = Task { [weak self] in
                do {
                    let value = try await service.answer(request) { [weak self] delta in
                        await self?.appendAnswer(delta, id: id)
                    }
                    guard let self, self.answerID == id, !Task.isCancelled else { return }
                    self.answer = value
                    self.isAnswering = false
                } catch {
                    guard let self, self.answerID == id else { return }
                    self.isAnswering = false
                    if !(error is CancellationError) { self.answerError = error.localizedDescription }
                }
            }
        } catch {
            question = "Latest question"
            answerError = error.localizedDescription
            answer = ""
            onShowOverlay?()
        }
    }

    private func appendAnswer(_ delta: String, id: UUID) {
        guard answerID == id else { return }
        answer += delta
    }

    func cancelAnswer() {
        answerID = UUID()
        answerTask?.cancel()
        answerTask = nil
        isAnswering = false
    }

    func clearConversation() {
        cancelAnswer()
        triggerTask?.cancel()
        triggerDetector.reset()
        buffer.clear()
        segments = []
        question = ""
        answer = ""
        answerError = nil
        answerIsDemo = false
    }

    func runDemo() {
        guard state == .idle else { return }
        clearConversation()
        errorMessage = nil
        state = .demo
        demoTask = Task { [weak self] in
            guard let self else { return }
            let now = Self.nowMs
            self.accept(TranscriptSegment(source: .system, text: "The product list is loading slowly. We want to reduce database requests.",
                                          startMs: now - 9_000, endMs: now - 5_000))
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self.accept(TranscriptSegment(source: .system, text: "How would a cache help us here?",
                                          startMs: now - 4_000, endMs: now - 1_000))
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self.accept(TranscriptSegment(source: .mic, text: "I'm not sure, Lazy Ask.",
                                          startMs: now, endMs: now + 600))
        }
    }

    func copyAnswer() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
    }

    private func savePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(retentionMinutes, forKey: "retentionMinutes")
        defaults.set(sensitivity, forKey: "sensitivity")
        defaults.set(answerModel, forKey: "answerModel")
        defaults.set(language, forKey: "language")
        buffer.retentionMs = Double(retentionMinutes) * 60_000
    }
}
