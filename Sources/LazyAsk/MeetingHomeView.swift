import LazyAskCore
import SwiftUI

struct MeetingHomeView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 210)
            Divider()
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(model.homeTitle).font(.system(size: 20, weight: .semibold))
                        .lineLimit(1).help(model.homeTitle)
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search meeting names", text: $model.meetingSearch).textFieldStyle(.plain)
                    }
                    .padding(7).background(Color.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 5))
                    .frame(width: 170)
                    Button(action: newMeeting) { Label("New meeting", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).disabled(!model.libraryAvailable || model.isNavigating || model.state != .idle)
                }
                .padding(18)
                Divider()
                if model.filteredMeetings.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "text.bubble").font(.system(size: 30)).foregroundStyle(.tertiary)
                        Text(model.meetingSearch.isEmpty ? "No Lazy Meetings" : "No matches")
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                        if model.meetingSearch.isEmpty {
                            Button(action: newMeeting) { Label("New meeting", systemImage: "plus") }
                                .buttonStyle(.bordered).disabled(!model.libraryAvailable || model.state != .idle)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(model.filteredMeetings) { meeting in
                        meetingRow(meeting).listRowSeparator(.visible)
                    }
                    .listStyle(.plain)
                }
                Divider()
                HStack {
                    Text("\(model.filteredMeetings.count) meeting\(model.filteredMeetings.count == 1 ? "" : "s")")
                    Spacer()
                    Label("On this Mac", systemImage: "internaldrive")
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(14)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.circle.fill").font(.system(size: 25)).foregroundStyle(accent)
                Text("Lazy Ask").font(.system(size: 19, weight: .semibold))
            }
            .padding(18)
            folderButton("All meetings", symbol: "tray.full", id: nil, count: model.meetings.count)
            folderButton("Unfiled", symbol: "tray", id: "", count: model.meetings.filter { $0.folderID == nil }.count)
            HStack {
                Text("Folders").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                IconButton("New folder", symbol: "folder.badge.plus") { model.beginEdit(.newFolder) }
                    .disabled(!model.libraryAvailable)
            }
            .padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 6)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.folders) { folder in
                        HStack(spacing: 0) {
                            folderButton(folder.name, symbol: "folder", id: folder.id,
                                         count: model.meetings.filter { $0.folderID == folder.id }.count)
                            Menu {
                                Button("Rename", systemImage: "pencil") { model.beginEdit(.renameFolder(folder.id)) }
                                Button("Delete folder", systemImage: "trash", role: .destructive) {
                                    model.pendingDeletion = .folder(folder.id)
                                }
                            } label: { Image(systemName: "ellipsis").frame(width: 18, height: 24) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden)
                            .fixedSize().padding(.trailing, 12).help("Folder actions").accessibilityLabel("Actions for folder " + folder.name)
                        }
                    }
                }
            }
            Spacer(minLength: 12)
            Divider()
            HStack {
                Button(action: model.runDemo) { Label("Run demo", systemImage: "play.circle") }
                    .buttonStyle(.borderless).disabled(model.state != .idle || model.isNavigating)
                Spacer()
                IconButton("Settings", symbol: "gearshape") { model.showSettings = true }
            }
            .padding(16)
        }
        .background(Color.primary.opacity(0.025))
    }

    private func folderButton(_ name: String, symbol: String, id: String?, count: Int) -> some View {
        Button { model.folderFilter = id } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(id == nil || id == "" ? accent : .orange)
                Text(name).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 3)
                Text("\(count)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9).padding(.vertical, 8)
            .background(model.folderFilter == id ? accent.opacity(0.1) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain).padding(.horizontal, 9).help(name)
    }

    private func meetingRow(_ meeting: LazyMeeting) -> some View {
        HStack(spacing: 14) {
            Button { Task { await model.openMeeting(meeting.id) } } label: {
                HStack(spacing: 12) {
                    Image(systemName: "text.bubble").font(.system(size: 20)).foregroundStyle(accent).frame(width: 30)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(meeting.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        if !meeting.preview.isEmpty {
                            Text(meeting.preview).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        HStack(spacing: 8) {
                            Text(Date(timeIntervalSince1970: meeting.updatedAtMs / 1_000), format: .dateTime.month().day().hour().minute())
                            if meeting.segmentCount == 0 { Text("Empty transcript") }
                            if let name = model.folders.first(where: { $0.id == meeting.folderID })?.name {
                                Label(name, systemImage: "folder").lineLimit(1)
                            }
                        }
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(model.isNavigating).accessibilityLabel("Open " + meeting.name)
            Menu {
                Button("Rename", systemImage: "pencil") { model.beginEdit(.renameMeeting(meeting.id)) }
                Menu("Move to", systemImage: "folder") {
                    Button("Unfiled") { model.moveMeeting(meeting.id, to: nil) }
                    ForEach(model.folders) { folder in
                        Button(folder.name) { model.moveMeeting(meeting.id, to: folder.id) }
                    }
                }
                Button("Delete meeting", systemImage: "trash", role: .destructive) {
                    model.pendingDeletion = .meeting(meeting.id)
                }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 26) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Meeting actions").accessibilityLabel("Actions for " + meeting.name)
        }
        .padding(.vertical, 10)
    }

    private func newMeeting() {
        model.beginEdit(.newMeeting(model.folderFilter == "" ? nil : model.folderFilter))
    }
}

struct MeetingNameEditor: View {
    @ObservedObject var model: AppModel
    let edit: AppModel.LibraryEdit

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(edit.title).font(.system(size: 18, weight: .semibold))
            TextField("Name", text: $model.nameDraft).textFieldStyle(.roundedBorder)
                .onSubmit(model.saveEdit)
            if let error = model.errorMessage {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.libraryEdit = nil }.keyboardShortcut(.cancelAction)
                Button(edit.isNew ? "Create" : "Save", action: model.saveEdit)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(model.nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.nameDraft.count > 120)
            }
        }
        .padding(22).frame(width: 380)
    }
}
