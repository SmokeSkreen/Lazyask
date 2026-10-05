import AppKit
import LazyAskCore
import SwiftUI

private let accent = Color(red: 0.12, green: 0.48, blue: 0.35)

struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill").font(.system(size: 28)).foregroundStyle(accent)
                Text("Lazy Ask").font(.system(size: 23, weight: .semibold))
                Spacer()
                StateLabel(model: model)
                Button(action: model.toggleListening) {
                    Label(model.state == .starting ? "Cancel" : model.state.active ? "Stop" : "Start listening",
                          systemImage: model.state == .starting || model.state.active ? "stop.fill" : "mic.fill")
                        .frame(minWidth: 108)
                }
                .buttonStyle(.borderedProminent).tint(accent)
                .disabled(model.state == .stopping)
                IconButton("Settings", symbol: "gearshape") { model.showSettings = true }
            }
            .padding(20)
            Divider()
            if let error = model.errorMessage {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text(error).font(.system(size: 12)).textSelection(.enabled)
                    Spacer(minLength: 8)
                    IconButton("Dismiss error", symbol: "xmark") { model.errorMessage = nil }
                }
                .padding(12).background(Color.red.opacity(0.06))
                Divider()
            }
            HSplitView {
                transcript.frame(minWidth: 280, idealWidth: 360)
                answerPane.frame(minWidth: 280, idealWidth: 340)
            }
            Divider()
            HStack(spacing: 12) {
                TextField("Ask a question...", text: $model.questionDraft, axis: .vertical)
                    .lineLimit(1...3).textFieldStyle(.plain).onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 25)).foregroundStyle(accent)
                }
                .buttonStyle(.plain).help("Ask Lazy Ask")
                .accessibilityLabel("Ask Lazy Ask")
                .disabled(model.questionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 640, minHeight: 440)
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transcript").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(model.retentionMinutes) min").font(.system(size: 11)).foregroundStyle(.secondary)
                IconButton("Clear transcript and answer", symbol: "trash") { model.clearConversation() }
                    .disabled(model.segments.isEmpty && model.answer.isEmpty)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            if model.segments.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "waveform").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("No transcript yet").foregroundStyle(.secondary).font(.system(size: 13))
                    Button(action: model.runDemo) { Label("Run demo", systemImage: "play.circle") }
                        .buttonStyle(.bordered).disabled(model.state != .idle)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 17) {
                            ForEach(model.segments) { segment in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(segment.source.label)
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(segment.source == .mic ? accent : .secondary)
                                        Spacer()
                                        Text(Date(timeIntervalSince1970: segment.startMs / 1_000), style: .time)
                                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                                    }
                                    Text(segment.text).font(.system(size: 13)).lineSpacing(3)
                                        .foregroundStyle(segment.isFinal ? .primary : .secondary)
                                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                                .id(segment.id)
                            }
                        }
                        .padding(.horizontal, 18).padding(.bottom, 20)
                    }
                    .onChange(of: model.segments.last?.text) {
                        if let id = model.segments.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
            HStack(spacing: 20) {
                AudioMeter(label: "Meeting", symbol: "speaker.wave.2", level: model.levels[.system] ?? 0)
                AudioMeter(label: "Mic", symbol: "mic", level: model.levels[.mic] ?? 0)
            }
            .padding(18).background(Color.primary.opacity(0.025))
        }
    }

    private var answerPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Answer").font(.system(size: 14, weight: .semibold))
                if model.answerIsDemo { Text("SAMPLE").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary) }
                Spacer()
                IconButton("Answer latest question", symbol: "questionmark.bubble") { model.askLatest() }
                IconButton("Show overlay", symbol: "rectangle.on.rectangle") { model.onShowOverlay?() }
                IconButton("Copy answer", symbol: "doc.on.doc") { model.copyAnswer() }.disabled(model.answer.isEmpty)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            AnswerContent(model: model).padding(.horizontal, 18)
        }
    }

    private func send() {
        guard !model.questionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.askDirect(model.questionDraft)
        model.questionDraft = ""
    }
}

struct IconButton: View {
    let label: String
    let symbol: String
    let action: () -> Void

    init(_ label: String, symbol: String, action: @escaping () -> Void) {
        self.label = label
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 24) }
            .buttonStyle(.borderless).help(label).accessibilityLabel(label)
    }
}

private struct StateLabel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(model.state.active ? accent : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
            Text(model.state.label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(width: 86, alignment: .leading)
    }
}

private struct AudioMeter: View {
    let label: String
    let symbol: String
    let level: Double
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).frame(width: 14)
            Text(label).font(.system(size: 11))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.08))
                    Rectangle().fill(accent).frame(width: geometry.size.width * min(1, max(0, level)))
                }
            }
            .frame(width: 42, height: 3)
        }
        .foregroundStyle(.secondary).accessibilityLabel("\(label) audio level")
    }
}

struct AnswerContent: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                if !model.question.isEmpty {
                    Text(model.question).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if !model.answer.isEmpty {
                    Text(model.answer).font(.system(size: 15)).lineSpacing(5)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } else if !model.isAnswering && model.answerError == nil && model.question.isEmpty {
                    Text("No answer yet").font(.system(size: 13)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 140)
                }
                if model.isAnswering {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Thinking...").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        IconButton("Cancel answer", symbol: "stop.circle") { model.cancelAnswer() }
                    }
                }
                if let error = model.answerError {
                    Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12))
                        .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct OverlayView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill").foregroundStyle(accent)
                Text("Lazy Ask").font(.system(size: 14, weight: .semibold))
                if model.answerIsDemo { Text("SAMPLE").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary) }
                Spacer()
                IconButton("Copy answer", symbol: "doc.on.doc") { model.copyAnswer() }.disabled(model.answer.isEmpty)
                IconButton("Open Lazy Ask", symbol: "arrow.up.left.and.arrow.down.right") { model.onOpenMain?() }
                IconButton("Dismiss overlay", symbol: "xmark") { model.onHideOverlay?() }
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            Divider()
            AnswerContent(model: model).padding(16)
        }
        .background(.regularMaterial)
        .frame(minWidth: 340, minHeight: 210)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Settings").font(.system(size: 19, weight: .semibold))
                Spacer()
                IconButton("Close settings", symbol: "xmark") { dismiss() }
            }
            Form {
                Section("OpenAI") {
                    HStack {
                        Label(model.hasKey ? "API key connected" : "API key required", systemImage: "key")
                        Spacer()
                        if model.hasKey {
                            IconButton("Remove API key", symbol: "trash") { model.removeKey() }
                        }
                    }
                    HStack {
                        SecureField(model.hasKey ? "Replace API key" : "API key", text: $model.keyDraft)
                            .onSubmit { model.saveKey() }
                        Button("Save", action: model.saveKey).disabled(model.keyDraft.isEmpty)
                    }
                    TextField("Answer model", text: $model.answerModel)
                }
                Section("Permissions") {
                    permissionRow("Microphone", symbol: "mic", allowed: model.microphoneAllowed) {
                        Task { await model.requestMicrophone() }
                    }
                    permissionRow("Screen & system audio", symbol: "speaker.wave.2", allowed: model.screenAllowed) {
                        model.requestScreen()
                    }
                }
                Section("Listening") {
                    Picker("Transcript window", selection: $model.retentionMinutes) {
                        ForEach([5, 8, 10], id: \.self) { Text("\($0) minutes").tag($0) }
                    }
                    Picker("Language", selection: $model.language) {
                        Text("Auto").tag("")
                        Text("English").tag("en")
                        Text("Chinese").tag("zh")
                        Text("Spanish").tag("es")
                        Text("French").tag("fr")
                    }
                    HStack {
                        Text("Speech sensitivity")
                        Slider(value: $model.sensitivity, in: 0...1).frame(maxWidth: 170)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(model.state != .idle)
            if let error = model.errorMessage {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20).frame(width: 460, height: 550)
        .onAppear { model.refreshPermissions() }
    }

    private func permissionRow(_ name: String, symbol: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Label(name, systemImage: symbol)
            Spacer()
            if allowed { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) }
            else { Button("Allow", action: action) }
        }
    }
}
