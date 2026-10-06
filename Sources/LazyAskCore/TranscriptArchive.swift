import Foundation

public actor TranscriptArchive {
    private let url: URL
    private var latestRevision = -1

    public init(url: URL) { self.url = url }

    public static func load(from url: URL) throws -> [TranscriptSegment] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([TranscriptSegment].self, from: Data(contentsOf: url))
            .filter(\.isFinal)
    }

    // Revisions keep an older queued snapshot from restoring deleted text.
    public func save(_ segments: [TranscriptSegment], revision: Int) throws {
        guard revision > latestRevision else { return }
        latestRevision = revision
        let final = segments.filter(\.isFinal)
        if final.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(final)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
