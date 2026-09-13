import Foundation

/// The safety layer DiskBuddy's "never deletes in the background" promise
/// depends on. Items are staged here first; nothing leaves disk until the
/// user explicitly confirms, and even then it goes to the Trash (via
/// `FileManager.trashItem`), never `unlink`/`removeItem` directly, so any
/// mistake is recoverable exactly like a normal Finder delete.
public actor CleanupQueue {

    public struct StagedItem: Identifiable, Sendable {
        public let id: UUID = UUID()
        public let url: URL
        /// Size of this file, not the bytes deleting it will free.
        /// Shared clones keep `size` so the row can show the file, and
        /// `reclaimableTotal()` is what a confirm would actually free.
        public let size: Int64
        public let reason: String // "duplicate", "app leftover", "big & untouched", etc.
        /// Set when this file shares physical extents with the other
        /// staged items of the same key. Nil for ordinary copies.
        public let sharesStorageGroup: String?
        /// Copies in the duplicate group this item came from. Shared
        /// extents count as reclaimable only when this many copies of
        /// the group are still staged.
        public let groupCopyCount: Int
    }

    private var items: [StagedItem] = []

    /// Paths that must never be staged, regardless of what a scan or
    /// heuristic suggests. This is a second, independent safety net on
    /// top of relying on SIP/permissions to fail the delete — belt and
    /// suspenders, since a permission failure is a worse UX than never
    /// offering the item at all.
    private static let excludedPrefixes: [String] = [
        "/System",
        "/Library/Apple",
        "/private/var/db",
        NSHomeDirectory() + "/Library/Keychains",
    ]

    public init() {}

    public func stage(
        _ url: URL,
        size: Int64,
        reason: String,
        sharesStorageGroup: String? = nil,
        groupCopyCount: Int = 1
    ) -> Bool {
        let path = url.path
        guard !Self.excludedPrefixes.contains(where: { path.hasPrefix($0) }) else {
            return false
        }
        guard !items.contains(where: { $0.url == url }) else { return false }
        items.append(StagedItem(
            url: url,
            size: size,
            reason: reason,
            sharesStorageGroup: sharesStorageGroup,
            groupCopyCount: max(groupCopyCount, 1)
        ))
        return true
    }

    public func unstage(id: UUID) {
        items.removeAll { $0.id == id }
    }

    public func allItems() -> [StagedItem] { items }

    /// Bytes a confirm would free. An ordinary file contributes its
    /// `size`. A shared-extent group contributes `size` once, and only
    /// when every copy from that group is still staged. Deleting one
    /// clone contributes 0.
    public func totalSize() -> Int64 {
        var plain: Int64 = 0
        var groups: [String: (staged: Int, copyCount: Int, fileSize: Int64)] = [:]
        for item in items {
            if let key = item.sharesStorageGroup {
                var entry = groups[key] ?? (staged: 0, copyCount: item.groupCopyCount, fileSize: item.size)
                entry.staged += 1
                entry.copyCount = max(entry.copyCount, item.groupCopyCount)
                groups[key] = entry
            } else {
                plain += item.size
            }
        }
        var shared: Int64 = 0
        for (_, entry) in groups where entry.staged >= entry.copyCount && entry.copyCount > 0 {
            shared += entry.fileSize
        }
        return plain + shared
    }

    /// Executes the staged cleanup: moves every item to the Trash. Returns
    /// per-item results so the UI can report partial failures (e.g. a
    /// TCC-protected path) without losing track of what did succeed.
    @discardableResult
    public func commit() -> [(item: StagedItem, error: Error?)] {
        var results: [(StagedItem, Error?)] = []
        for item in items {
            do {
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: item.url, resultingItemURL: &trashedURL)
                results.append((item, nil))
            } catch {
                results.append((item, error))
            }
        }
        // Clear only the items that succeeded, so failures stay staged
        // for the user to retry (e.g. after granting Full Disk Access).
        let failedIDs = Set(results.filter { $0.1 != nil }.map { $0.0.id })
        items = items.filter { failedIDs.contains($0.id) }
        return results
    }
}
