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
    @Published var sensitivity: Double { didSet { savePreferences() } }
    @Published var answerModel: String { didSet { savePreferences() } }
    @Published var language: String { didSet { savePreferences() } }
    @Published private(set) var meetings: [LazyMeeting] = []
    @Published private(set) var folders: [MeetingFolder] = []
    @Published private(set) var selectedMeetingID: String?
    @Published private(set) var isNavigating = false
    @Published var folderFilter: String?
    @Published var meetingSearch = ""
    @Published var libraryEdit: LibraryEdit?
    @Published var nameDraft = ""
    @Published var pendingDeletion: LibraryDeletion?
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
    private let library: MeetingLibrary?
    private var demoBackup: TranscriptBuffer?
    private var clearedAtMs = -Double.infinity
    var canClearTranscript: Bool { !segments.isEmpty || !answer.isEmpty }
    var isHome: Bool { selectedMeetingID == nil && state != .demo }
    var selectedMeeting: LazyMeeting? { meetings.first { $0.id == selectedMeetingID } }
    var meetingTitle: String { selectedMeeting?.name ?? "Demo meeting" }
    var libraryAvailable: Bool { library != nil }

    var filteredMeetings: [LazyMeeting] {
        meetings.filter { meeting in
            let inFolder = folderFilter == nil || (folderFilter == "" ? meeting.folderID == nil : meeting.folderID == folderFilter)
            return inFolder && (meetingSearch.isEmpty || meeting.name.localizedCaseInsensitiveContains(meetingSearch))
        }
    }

    var homeTitle: String {
        if folderFilter == "" { return "Unfiled" }
        return folders.first { $0.id == folderFilter }?.name ?? "Lazy Meetings"
    }

    enum LibraryEdit: Identifiable {
        case newMeeting(String?), renameMeeting(String), newFolder, renameFolder(String)
        var id: String {
            switch self {
            case .newMeeting: "new-meeting"
            case .renameMeeting(let id): "rename-meeting:" + id
            case .newFolder: "new-folder"
            case .renameFolder(let id): "rename-folder:" + id
            }
        }
        var title: String {
            switch self {
            case .newMeeting: "New Lazy Meeting"
            case .renameMeeting: "Rename meeting"
            case .newFolder: "New folder"
            case .renameFolder: "Rename folder"
            }
        }
        var isNew: Bool {
            switch self { case .newMeeting, .newFolder: true; default: false }
        }
    }

    enum LibraryDeletion {
        case meeting(String), folder(String)
        var title: String {
            switch self { case .meeting: "Delete Lazy Meeting?"; case .folder: "Delete folder?" }
        }
        var message: String {
            switch self {
            case .meeting: "This meeting and its saved transcript will be deleted."
            case .folder: "The folder will be deleted. Its meetings will stay in Unfiled."
            }
        }
    }
    private var sessionID = UUID()
    private var answerID = UUID()
    private var lastLevelUpdate: [AudioSource: Double] = [:]

    init(databaseURL suppliedDatabaseURL: URL? = nil, legacyArchiveURL: URL? = nil, apiKeyOverride: String? = nil) {
        let defaults = UserDefaults.standard
        sensitivity = defaults.object(forKey: "sensitivity") as? Double ?? 0.55
        answerModel = defaults.string(forKey: "answerModel") ?? "gpt-4.1-mini"
        language = defaults.string(forKey: "language") ?? ""
        apiKey = apiKeyOverride ?? KeychainStore.load() ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
        hasKey = !apiKey.isEmpty
        buffer = TranscriptBuffer()
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LazyAsk", isDirectory: true)
        let databaseURL = suppliedDatabaseURL ?? directory.appendingPathComponent("meetings.sqlite3")
        let legacyURL = legacyArchiveURL ?? (suppliedDatabaseURL == nil ? directory.appendingPathComponent("transcript.json") : nil)
        do {
            let store = try MeetingLibrary(url: databaseURL, legacyArchiveURL: legacyURL)
            let savedMeetings = try store.meetings()
            let savedFolders = try store.folders()
            library = store
            meetings = savedMeetings
            folders = savedFolders
        } catch {
            library = nil
            errorMessage = "Your meeting library could not be opened: " + error.localizedDescription
        }
        refreshPermissions()
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
        guard state == .idle, !isNavigating else { return }
        guard selectedMeetingID != nil, library != nil else {
            errorMessage = "Open a Lazy Meeting before starting to listen."
            onOpenMain?()
            return
        }
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
        resetAnswer()
        triggerDetector.reset()
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                self.refreshPermissions()
                if !self.microphoneAllowed { await self.requestMicrophone() }
                try Task.checkCancellation()
                guard self.microphoneAllowed else {
                    throw LazyAskError.permission("Allow Microphone access in System Settings, then start again.")
                }
                if !self.screenAllowed { self.requestScreen() }
                guard self.screenAllowed else {
                    throw LazyAskError.permission("Allow Screen & System Audio Recording for Lazy Ask in System Settings. If it is already on, quit and reopen Lazy Ask, then try again.")
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
        if state == .stopping {
            while state == .stopping {
                do { try await Task.sleep(for: .milliseconds(25)) }
                catch { return }
            }
            return
        }
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
        if let backup = demoBackup {
            buffer = backup
            segments = buffer.segments
            demoBackup = nil
            resetAnswer()
        }
        state = .idle
    }

    func accept(_ segment: TranscriptSegment) {
        guard selectedMeetingID != nil || state == .demo else { return }
        guard state == .demo || segment.startMs >= clearedAtMs else { return }
        buffer.upsert(segment, nowMs: Self.nowMs)
        segments = buffer.segments
        if segment.isFinal, state != .demo, let meetingID = selectedMeetingID {
            do {
                try requireLibrary().saveSegment(segment, meetingID: meetingID)
                try refreshLibrary()
            } catch { errorMessage = "Your transcript could not be saved: " + error.localizedDescription }
        }
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
        guard !isHome else { onOpenMain?(); return }
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
        if state == .demo {
            demoTask?.cancel()
            buffer.clear()
            segments = []
            resetAnswer()
            triggerDetector.reset()
            return
        }
        guard let meetingID = selectedMeetingID else { return }
        do {
            try requireLibrary().clearTranscript(meetingID: meetingID)
            try refreshLibrary()
        } catch { errorMessage = error.localizedDescription; return }
        clearedAtMs = Self.nowMs
        buffer.clear()
        segments = []
        resetAnswer()
        triggerDetector.reset()
    }

    private func resetAnswer() {
        cancelAnswer()
        triggerTask?.cancel()
        question = ""
        answer = ""
        answerError = nil
        answerIsDemo = false
    }

    func runDemo() {
        guard state == .idle else { return }
        demoBackup = buffer
        buffer = TranscriptBuffer()
        segments = []
        resetAnswer()
        triggerDetector.reset()
        errorMessage = nil
        state = .demo
        demoTask = Task { [weak self] in
            guard !Task.isCancelled, let self, self.state == .demo else { return }
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
        defaults.set(sensitivity, forKey: "sensitivity")
        defaults.set(answerModel, forKey: "answerModel")
        defaults.set(language, forKey: "language")
    }

    private func requireLibrary() throws -> MeetingLibrary {
        guard let library else { throw LibraryError.database("The library is unavailable. Check the error above and reopen the app.") }
        return library
    }

    private func refreshLibrary() throws {
        let library = try requireLibrary()
        meetings = try library.meetings()
        folders = try library.folders()
    }

    func beginEdit(_ edit: LibraryEdit) {
        errorMessage = nil
        switch edit {
        case .renameMeeting(let id): nameDraft = meetings.first { $0.id == id }?.name ?? ""
        case .renameFolder(let id): nameDraft = folders.first { $0.id == id }?.name ?? ""
        default: nameDraft = ""
        }
        libraryEdit = edit
    }

    func saveEdit() {
        guard let edit = libraryEdit, !isNavigating else { return }
        do {
            let library = try requireLibrary()
            switch edit {
            case .newMeeting(let folderID):
                guard state == .idle else { throw LibraryError.database("Wait until listening has stopped before creating a meeting.") }
                let id = try library.createMeeting(name: nameDraft, folderID: folderID)
                meetingSearch = ""
                try refreshLibrary()
                try loadMeeting(id)
            case .renameMeeting(let id): try library.renameMeeting(id: id, name: nameDraft)
            case .newFolder:
                folderFilter = try library.createFolder(name: nameDraft)
            case .renameFolder(let id): try library.renameFolder(id: id, name: nameDraft)
            }
            try refreshLibrary()
            libraryEdit = nil
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func openMeeting(_ id: String) async {
        guard !isNavigating else { return }
        isNavigating = true
        defer { isNavigating = false }
        await stopListening()
        do { try loadMeeting(id); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    private func loadMeeting(_ id: String) throws {
        let saved = try requireLibrary().transcript(meetingID: id)
        resetAnswer()
        triggerDetector.reset()
        onHideOverlay?()
        questionDraft = ""
        clearedAtMs = -Double.infinity
        buffer = TranscriptBuffer(segments: saved)
        segments = buffer.segments
        selectedMeetingID = id
    }

    func goHome() async {
        guard !isNavigating else { return }
        isNavigating = true
        defer { isNavigating = false }
        await stopListening()
        resetAnswer()
        onHideOverlay?()
        selectedMeetingID = nil
        questionDraft = ""
        buffer.clear()
        segments = []
        do { try refreshLibrary() } catch { errorMessage = error.localizedDescription }
    }

    func moveMeeting(_ id: String, to folderID: String?) {
        do {
            try requireLibrary().moveMeeting(id: id, folderID: folderID)
            try refreshLibrary()
        } catch { errorMessage = error.localizedDescription }
    }

    func confirmDeletion(_ requestedDeletion: LibraryDeletion? = nil) async {
        guard let deletion = requestedDeletion ?? pendingDeletion, !isNavigating else { return }
        pendingDeletion = nil
        do {
            switch deletion {
            case .meeting(let id):
                if selectedMeetingID == id { await goHome() }
                try requireLibrary().deleteMeeting(id: id)
            case .folder(let id):
                try requireLibrary().deleteFolder(id: id)
                if folderFilter == id { folderFilter = "" }
            }
            try refreshLibrary()
        } catch { errorMessage = error.localizedDescription }
    }

    func showLibraryInFinder() {
        if let library { NSWorkspace.shared.activateFileViewerSelecting([library.url]) }
    }
}
