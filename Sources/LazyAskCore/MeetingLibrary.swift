import Foundation
import SQLite3

public struct LazyMeeting: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let folderID: String?
    public let createdAtMs: Double
    public let updatedAtMs: Double
    public let segmentCount: Int
    public let preview: String
}

public struct MeetingFolder: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
}

public enum LibraryError: LocalizedError, Sendable {
    case database(String)
    case invalidName
    case notFound

    public var errorDescription: String? {
        switch self {
        case .database(let message): "Meeting library: " + message
        case .invalidName: "Enter a name between 1 and 120 characters."
        case .notFound: "This meeting or folder no longer exists."
        }
    }
}

// One locked connection keeps writes ordered, including rename, move, and deletion.
public final class MeetingLibrary: @unchecked Sendable {
    public let url: URL
    private var database: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL, legacyArchiveURL: URL? = nil) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let status = sqlite3_open_v2(url.path, &database,
                                    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open the database."
            if let database { sqlite3_close(database) }
            database = nil
            throw LibraryError.database(message)
        }
        do {
            sqlite3_busy_timeout(database, 3_000)
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try execute("PRAGMA secure_delete = ON")
            try execute("""
                CREATE TABLE IF NOT EXISTS folders (id TEXT PRIMARY KEY, name TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS meetings (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL,
                    folder_id TEXT REFERENCES folders(id) ON DELETE SET NULL,
                    created_ms REAL NOT NULL, updated_ms REAL NOT NULL,
                    segment_count INTEGER NOT NULL DEFAULT 0, preview TEXT NOT NULL DEFAULT ''
                );
                CREATE TABLE IF NOT EXISTS segments (
                    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                    id TEXT NOT NULL, source TEXT NOT NULL, text TEXT NOT NULL,
                    start_ms REAL NOT NULL, end_ms REAL NOT NULL,
                    PRIMARY KEY (meeting_id, id)
                );
                CREATE INDEX IF NOT EXISTS segment_timeline ON segments(meeting_id, start_ms, id);
                CREATE INDEX IF NOT EXISTS meeting_folders ON meetings(folder_id, updated_ms DESC);
                CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                """)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try migrateLegacyArchive(legacyArchiveURL)
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { if let database { sqlite3_close(database) } }

    public func meetings() throws -> [LazyMeeting] {
        try lock.withLock {
            var result: [LazyMeeting] = []
            try query("SELECT id, name, folder_id, created_ms, updated_ms, segment_count, preview FROM meetings ORDER BY updated_ms DESC, id") { statement in
                result.append(LazyMeeting(id: text(statement, 0), name: text(statement, 1),
                    folderID: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : text(statement, 2),
                    createdAtMs: sqlite3_column_double(statement, 3), updatedAtMs: sqlite3_column_double(statement, 4),
                    segmentCount: Int(sqlite3_column_int64(statement, 5)), preview: text(statement, 6)))
            }
            return result
        }
    }

    public func folders() throws -> [MeetingFolder] {
        try lock.withLock {
            var result: [MeetingFolder] = []
            try query("SELECT id, name FROM folders ORDER BY name COLLATE NOCASE, id") { statement in
                result.append(MeetingFolder(id: text(statement, 0), name: text(statement, 1)))
            }
            return result
        }
    }

    @discardableResult
    public func createMeeting(name: String, folderID: String? = nil) throws -> String {
        try lock.withLock {
            let name = try validatedName(name)
            if let folderID { try requireFolder(folderID) }
            let id = UUID().uuidString
            let now = Date().timeIntervalSince1970 * 1_000
            try run("INSERT INTO meetings(id, name, folder_id, created_ms, updated_ms) VALUES (?, ?, ?, ?, ?)",
                    [.string(id), .string(name), folderID.map(Value.string) ?? .null, .number(now), .number(now)])
            return id
        }
    }

    @discardableResult
    public func createFolder(name: String) throws -> String {
        try lock.withLock {
            let id = UUID().uuidString
            try run("INSERT INTO folders(id, name) VALUES (?, ?)", [.string(id), .string(try validatedName(name))])
            return id
        }
    }

    public func renameMeeting(id: String, name: String) throws {
        try lock.withLock {
            try requireMeeting(id)
            try run("UPDATE meetings SET name = ? WHERE id = ?", [.string(try validatedName(name)), .string(id)])
        }
    }

    public func renameFolder(id: String, name: String) throws {
        try lock.withLock {
            try requireFolder(id)
            try run("UPDATE folders SET name = ? WHERE id = ?", [.string(try validatedName(name)), .string(id)])
        }
    }

    public func moveMeeting(id: String, folderID: String?) throws {
        try lock.withLock {
            try requireMeeting(id)
            if let folderID { try requireFolder(folderID) }
            try run("UPDATE meetings SET folder_id = ? WHERE id = ?", [folderID.map(Value.string) ?? .null, .string(id)])
        }
    }

    public func deleteMeeting(id: String) throws {
        try lock.withLock {
            try requireMeeting(id)
            try run("DELETE FROM meetings WHERE id = ?", [.string(id)])
            sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        }
    }

    public func deleteFolder(id: String) throws {
        try lock.withLock {
            try requireFolder(id)
            // Removing a folder preserves its meetings in Unfiled.
            try run("DELETE FROM folders WHERE id = ?", [.string(id)])
        }
    }

    public func transcript(meetingID: String) throws -> [TranscriptSegment] {
        try lock.withLock {
            try requireMeeting(meetingID)
            var result: [TranscriptSegment] = []
            try query("SELECT id, source, text, start_ms, end_ms FROM segments WHERE meeting_id = ? ORDER BY start_ms, id",
                      [.string(meetingID)]) { statement in
                guard let source = AudioSource(rawValue: text(statement, 1)) else {
                    throw LibraryError.database("A transcript contains an unknown audio source.")
                }
                result.append(TranscriptSegment(id: text(statement, 0), source: source, text: text(statement, 2),
                    startMs: sqlite3_column_double(statement, 3), endMs: sqlite3_column_double(statement, 4)))
            }
            return result
        }
    }

    public func saveSegment(_ segment: TranscriptSegment, meetingID: String) throws {
        guard segment.isFinal else { return }
        try lock.withLock {
            try transaction {
                try requireMeeting(meetingID)
                try insertSegment(segment, meetingID: meetingID)
                try updateSummary(meetingID)
            }
        }
    }

    public func clearTranscript(meetingID: String) throws {
        try lock.withLock {
            try transaction {
                try requireMeeting(meetingID)
                try run("DELETE FROM segments WHERE meeting_id = ?", [.string(meetingID)])
                try updateSummary(meetingID)
            }
            sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        }
    }

    private func migrateLegacyArchive(_ legacyURL: URL?) throws {
        let imported = try exists("SELECT 1 FROM metadata WHERE key = 'legacy_import_done'")
        if !imported {
            let segments = try legacyURL.map { try TranscriptArchive.load(from: $0) } ?? []
            try transaction {
                if !segments.isEmpty {
                    let id = try createMeeting(name: "Imported meeting")
                    for segment in segments { try insertSegment(segment, meetingID: id) }
                    try updateSummary(id)
                }
                try run("INSERT INTO metadata(key, value) VALUES ('legacy_import_done', '1')")
            }
        }
        // Only remove the old file after the import and its marker commit together.
        if let legacyURL, FileManager.default.fileExists(atPath: legacyURL.path) {
            try FileManager.default.removeItem(at: legacyURL)
        }
    }

    private func insertSegment(_ segment: TranscriptSegment, meetingID: String) throws {
        try run("""
            INSERT INTO segments(meeting_id, id, source, text, start_ms, end_ms) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(meeting_id, id) DO UPDATE SET source=excluded.source, text=excluded.text,
            start_ms=excluded.start_ms, end_ms=excluded.end_ms
            """, [.string(meetingID), .string(segment.id), .string(segment.source.rawValue), .string(segment.text),
                  .number(segment.startMs), .number(segment.endMs)])
    }

    private func updateSummary(_ meetingID: String) throws {
        try run("""
            UPDATE meetings SET updated_ms = ?,
                segment_count = (SELECT COUNT(*) FROM segments WHERE meeting_id = ?),
                preview = COALESCE((SELECT substr(text, 1, 160) FROM segments WHERE meeting_id = ? ORDER BY start_ms DESC, id DESC LIMIT 1), '')
            WHERE id = ?
            """, [.number(Date().timeIntervalSince1970 * 1_000), .string(meetingID), .string(meetingID), .string(meetingID)])
    }

    private func requireMeeting(_ id: String) throws {
        guard try exists("SELECT 1 FROM meetings WHERE id = ?", [.string(id)]) else { throw LibraryError.notFound }
    }

    private func requireFolder(_ id: String) throws {
        guard try exists("SELECT 1 FROM folders WHERE id = ?", [.string(id)]) else { throw LibraryError.notFound }
    }

    private func validatedName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else { throw LibraryError.invalidName }
        return name
    }

    private enum Value { case string(String), number(Double), null }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func statement(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &result, nil) == SQLITE_OK, let result else { throw failure() }
        do {
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let status: Int32
                switch value {
                case .string(let text):
                    guard text.utf8.count <= Int32.max else { throw LibraryError.database("The text is too large to save.") }
                    status = sqlite3_bind_text(result, index, text, Int32(text.utf8.count), transient)
                case .number(let value): status = sqlite3_bind_double(result, index, value)
                case .null: status = sqlite3_bind_null(result, index)
                }
                guard status == SQLITE_OK else { throw failure() }
            }
            return result
        } catch { sqlite3_finalize(result); throw error }
    }

    private func run(_ sql: String, _ values: [Value] = []) throws {
        let statement = try statement(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func query(_ sql: String, _ values: [Value] = [], row: (OpaquePointer) throws -> Void) throws {
        let statement = try statement(sql, values)
        defer { sqlite3_finalize(statement) }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw failure() }
            try row(statement)
        }
    }

    private func exists(_ sql: String, _ values: [Value] = []) throws -> Bool {
        var found = false
        try query(sql, values) { _ in found = true }
        return found
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }

    private func failure() -> LibraryError {
        .database(database.map { String(cString: sqlite3_errmsg($0)) } ?? "The database is closed.")
    }
}
