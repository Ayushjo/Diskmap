import Foundation

/// What the last cleanup moved to the Trash and where it went, kept so it can
/// be put back — after a relaunch too (TASK-080).
public struct CleanupRecord: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var originalPath: String
        public var trashedPath: String
        public var bytes: Int64

        public init(originalPath: String, trashedPath: String, bytes: Int64) {
            self.originalPath = originalPath
            self.trashedPath = trashedPath
            self.bytes = bytes
        }
    }

    public var date: Date
    public var items: [Item]

    public init(date: Date, items: [Item]) {
        self.date = date
        self.items = items
    }

    /// The items a commit moved by themselves (an item that went inside its
    /// folder comes back with the folder), with where the Trash put them.
    public init(report: CleanupQueue.CommitReport, date: Date = Date()) {
        self.date = date
        self.items = report.entries.compactMap { entry in
            guard entry.error == nil, !entry.movedWithFolder, let trashed = entry.trashedURL else { return nil }
            return Item(originalPath: entry.item.url.path, trashedPath: trashed.path, bytes: entry.freedBytes)
        }
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DiskMap/last-cleanup.json")
    }

    public static func load(from url: URL) -> CleanupRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CleanupRecord.self, from: data)
    }

    /// Written whole and atomically; an empty record replaces a used one.
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public struct PutBackReport: Sendable {
    public var restored: [CleanupRecord.Item]
    public var skipped: [(item: CleanupRecord.Item, reason: String)]
}

extension CleanupQueue {
    /// Moves the last cleanup's items from the Trash back where they were.
    /// A move back into the user's own folders — never a removal: an item is
    /// skipped, with the reason, when it is no longer in the Trash or when
    /// something new already sits at its old path (nothing is replaced). A
    /// missing parent folder is recreated. Only `FileManager.moveItem`.
    ///
    /// `move` is a seam for tests; production code uses the default.
    public static func putBack(
        _ record: CleanupRecord,
        move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) -> PutBackReport {
        var report = PutBackReport(restored: [], skipped: [])
        let fileManager = FileManager.default
        func exists(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) == 0   // a dangling symlink still occupies the name
        }
        for item in record.items {
            guard exists(item.trashedPath) else {
                report.skipped.append((item, "Already removed from the Trash"))
                continue
            }
            guard !exists(item.originalPath) else {
                report.skipped.append((item, "Something new is at \(CanonicalPath.displayPath(absolutePath: item.originalPath))"))
                continue
            }
            let original = URL(fileURLWithPath: item.originalPath)
            do {
                try fileManager.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try move(URL(fileURLWithPath: item.trashedPath), original)
                report.restored.append(item)
            } catch {
                report.skipped.append((item, error.localizedDescription))
            }
        }
        return report
    }
}
