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
        /// `reclaimEstimate()` is what a confirm would actually free.
        public let size: Int64
        public let reason: String // "duplicate", "app leftover", "big & untouched", etc.
        /// Set when this file shares physical extents with the other
        /// staged items of the same key. Nil for ordinary copies.
        /// Only consulted when `sharing` is nil (the path could not be
        /// examined) — see `reclaimEstimate()`.
        public let sharesStorageGroup: String?
        /// Copies in the duplicate group this item came from. Shared
        /// extents count as reclaimable only when this many copies of
        /// the group are still staged.
        public let groupCopyCount: Int
        /// What the filesystem says this path shares, derived by the queue
        /// itself (TASK-038) so every staging surface gets correct reclaim
        /// math, not just the Duplicates screen. Nil while measuring, or when
        /// the path could not be examined.
        public internal(set) var sharing: StorageSharing.Profile?
        /// True until the background measurement finishes. A large folder
        /// takes seconds (a 325k-file ~/Library/Caches: ~9.6 s), so staging
        /// returns at once and the figure fills in afterwards.
        public internal(set) var isMeasuring: Bool
        /// Where `sharing` came from: the last scan's tree (instant), or a
        /// walk of the path (TASK-082). Nil while measuring.
        public internal(set) var measurementSource: MeasurementSource? = nil
        /// Why the last Move to Trash left this item here, in plain words.
        /// Nil until a commit fails on it. The item stays staged — nothing
        /// is ever deleted permanently instead (AGENTS.md rule 1).
        public internal(set) var lastFailure: String? = nil
    }

    /// A move-to-Trash error as one sentence a person can act on.
    public static func plainReason(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return "It’s no longer there — it was moved or deleted since the scan."
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return "No permission to move it. Grant Full Disk Access, or check who owns it."
            case NSFileWriteVolumeReadOnlyError:
                return "Its volume is read-only."
            case NSFeatureUnsupportedError:
                return "This volume has no Trash, so it can’t be moved there. Remove it in Finder if you’re sure."
            default: break
            }
        }
        if ns.domain == NSPOSIXErrorDomain {
            switch Int32(ns.code) {
            case EPERM, EACCES: return "No permission to move it. Grant Full Disk Access, or check who owns it."
            case EBUSY: return "It’s in use. Quit the app using it and try again."
            case ENOENT: return "It’s no longer there — it was moved or deleted since the scan."
            case EROFS: return "Its volume is read-only."
            default: break
            }
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return plainReason(underlying) }
        return ns.localizedDescription
    }

    public enum MeasurementSource: Sendable, Equatable {
        /// From the scan finished at this time, checked unchanged since.
        case scan(Date)
        case walk
    }

    /// What confirming would free, and why the rest would not.
    public struct ReclaimEstimate: Sendable, Equatable {
        /// Bytes freed once the Trash is emptied. Moving to the Trash alone
        /// frees nothing.
        public var bytes: Int64
        /// Hard-linked or cloned data that stays in use because some of its
        /// names or clones are not queued.
        public var heldByUnqueuedCopies: Int64
        /// Blocks shared with something the filesystem cannot identify
        /// (partially edited clones, local snapshots). Not counted.
        public var sharedUnattributed: Int64
        /// True when the real figure may be higher than `bytes`: unattributed
        /// sharing, a folder that could not be fully read, or a path that
        /// could not be examined at all.
        public var isLowerBound: Bool
        /// `bytes` split across items, so a row and the commit receipt can
        /// show their share. Items inside a queued folder get 0 here — the
        /// folder carries them. Always sums to `bytes`.
        public var perItem: [UUID: Int64]
        /// True while any item is still being measured; `bytes` then uses the
        /// caller-supplied size for those items and is provisional. The UI
        /// must not offer the destructive action on a provisional figure.
        public var isCalculating: Bool = false

        public static let empty = ReclaimEstimate(
            bytes: 0, heldByUnqueuedCopies: 0, sharedUnattributed: 0, isLowerBound: false, perItem: [:]
        )
    }

    /// One row of a commit's outcome.
    public struct CommitEntry: Sendable {
        public let item: StagedItem
        public let error: Error?
        /// True when this item was inside a folder that was moved to the
        /// Trash in the same commit, so it went with its folder.
        public let movedWithFolder: Bool
        /// This item's share of `CommitReport.freedWhenTrashEmptied`.
        public let freedBytes: Int64
        /// Where the Trash put it (TASK-080), so it can be put back.
        public let trashedURL: URL?
    }

    public struct CommitReport: Sendable {
        public let entries: [CommitEntry]
        /// Recomputed over what actually moved, so a partial failure never
        /// reports space from an item that is still on disk.
        public let freedWhenTrashEmptied: Int64
        public let isLowerBound: Bool
    }

    private var items: [StagedItem] = []
    /// The latest scan, for measuring staged folders without walking them.
    private var scanContext: StorageSharing.ScanContext?
    private var measurementWaiters: [CheckedContinuation<Void, Never>] = []

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

    /// Called after every scan (and with nil when the tree is gone), so
    /// staging can measure from the tree when that is exact (TASK-082).
    public func setScanContext(_ context: StorageSharing.ScanContext?) {
        scanContext = context
    }

    public func stage(
        _ url: URL,
        size: Int64,
        reason: String,
        sharesStorageGroup: String? = nil,
        groupCopyCount: Int = 1
    ) async -> Bool {
        let path = url.path
        guard !Self.excludedPrefixes.contains(where: { path.hasPrefix($0) }) else {
            return false
        }
        let preflight = CleanupPreflight.evaluate(url: url)
        guard preflight.allowed else {
            return false
        }
        let standardized = url.standardizedFileURL
        guard !items.contains(where: { $0.url.standardizedFileURL == standardized }) else { return false }

        let item = StagedItem(
            url: standardized,
            size: size,
            reason: reason,
            sharesStorageGroup: sharesStorageGroup,
            groupCopyCount: max(groupCopyCount, 1),
            sharing: nil,
            isMeasuring: true
        )
        items.append(item)
        // Measure off the actor and off Swift's cooperative pool, so staging
        // a huge folder returns immediately and never parks a thread.
        let id = item.id
        let measuredPath = standardized.path
        let context = scanContext
        Task {
            // The tree first: exact when it can be, nil otherwise.
            if let context, let seeded = await StorageSharing.seededProfileOffPool(context: context, path: measuredPath) {
                self.recordMeasurement(seeded, source: .scan(context.capturedAt), for: id)
                return
            }
            let sharing = await StorageSharing.profileOffPool(atPath: measuredPath)
            self.recordMeasurement(sharing, source: .walk, for: id)
        }
        return true
    }

    private func recordMeasurement(_ sharing: StorageSharing.Profile?, source: MeasurementSource, for id: UUID) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].sharing = sharing
            items[index].isMeasuring = false
            items[index].measurementSource = source
        }
        resumeWaitersIfSettled()
    }

    private func resumeWaitersIfSettled() {
        guard !items.contains(where: \.isMeasuring) else { return }
        let waiters = measurementWaiters
        measurementWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Suspends until every staged item has been measured.
    public func waitForMeasurements() async {
        guard items.contains(where: \.isMeasuring) else { return }
        await withCheckedContinuation { measurementWaiters.append($0) }
    }

    public func unstage(id: UUID) {
        items.removeAll { $0.id == id }
        resumeWaitersIfSettled()
    }

    public func allItems() -> [StagedItem] { items }

    /// Bytes a confirm would free once the Trash is emptied.
    public func totalSize() -> Int64 {
        Self.estimate(for: items).bytes
    }

    public func reclaimEstimate() -> ReclaimEstimate {
        Self.estimate(for: items)
    }

    /// Reclaim math across a set of staged items (TASK-038).
    ///
    /// - An item inside another queued item's folder is skipped: the folder's
    ///   profile already contains it, and counting both was a double count.
    /// - Ordinary data counts in full (its PRIVATESIZE on APFS).
    /// - A hard-linked inode counts once, and only when every one of its names
    ///   is queued — pnpm's `node_modules`, hard-linked into a global store,
    ///   frees almost nothing on its own.
    /// - A pure-clone family counts its shared blocks once, and only when the
    ///   whole family is queued.
    /// - Items that could not be examined fall back to the size the caller
    ///   gave, plus the caller's shared-storage hint (the pre-TASK-038 rule).
    static func estimate(for items: [StagedItem]) -> ReclaimEstimate {
        var result = ReclaimEstimate.empty
        let ordered = items.sorted { $0.url.path < $1.url.path }
        let covered = coveredItemIDs(in: ordered)

        var hardLinks: [StorageSharing.InodeKey: (share: StorageSharing.HardLinkShare, owner: UUID)] = [:]
        var clones: [StorageSharing.CloneKey: (share: StorageSharing.CloneShare, owner: UUID)] = [:]
        var hinted: [String: (staged: Int, copyCount: Int, fileSize: Int64, owner: UUID)] = [:]

        for item in ordered {
            result.perItem[item.id] = 0
            guard !covered.contains(item.id) else { continue }

            if item.isMeasuring {
                // Provisional until measured: the caller's size, flagged.
                result.isCalculating = true
                result.perItem[item.id, default: 0] += item.size
                continue
            }
            guard let profile = item.sharing else {
                result.isLowerBound = true
                if let key = item.sharesStorageGroup {
                    var entry = hinted[key]
                        ?? (staged: 0, copyCount: item.groupCopyCount, fileSize: item.size, owner: item.id)
                    entry.staged += 1
                    entry.copyCount = max(entry.copyCount, item.groupCopyCount)
                    hinted[key] = entry
                } else {
                    result.perItem[item.id, default: 0] += item.size
                }
                continue
            }

            result.perItem[item.id, default: 0] += profile.ownedBytes
            result.sharedUnattributed += profile.sharedUnattributedBytes
            if profile.sharedUnattributedBytes > 0 || !profile.isComplete {
                result.isLowerBound = true
            }
            for (key, share) in profile.hardLinks {
                if var existing = hardLinks[key] {
                    existing.share.namesStaged += share.namesStaged
                    hardLinks[key] = existing
                } else {
                    hardLinks[key] = (share, item.id)
                }
            }
            for (key, share) in profile.clones {
                if var existing = clones[key] {
                    existing.share.membersStaged += share.membersStaged
                    existing.share.familySize = max(existing.share.familySize, share.familySize)
                    existing.share.sharedBytes = max(existing.share.sharedBytes, share.sharedBytes)
                    clones[key] = existing
                } else {
                    clones[key] = (share, item.id)
                }
            }
        }

        for (_, entry) in hardLinks {
            if entry.share.namesStaged >= entry.share.linkCount {
                result.perItem[entry.owner, default: 0] += entry.share.bytes
            } else {
                result.heldByUnqueuedCopies += entry.share.bytes
            }
        }
        for (_, entry) in clones {
            if entry.share.membersStaged >= entry.share.familySize {
                result.perItem[entry.owner, default: 0] += entry.share.sharedBytes
            } else {
                result.heldByUnqueuedCopies += entry.share.sharedBytes
            }
        }
        for (_, entry) in hinted where entry.copyCount > 0 {
            if entry.staged >= entry.copyCount {
                result.perItem[entry.owner, default: 0] += entry.fileSize
            } else {
                result.heldByUnqueuedCopies += entry.fileSize
            }
        }

        result.bytes = result.perItem.values.reduce(0, +)
        return result
    }

    /// Items whose path lies inside another queued item's folder.
    static func coveredItemIDs(in items: [StagedItem]) -> Set<UUID> {
        let folders = items.map { $0.url.path.hasSuffix("/") ? $0.url.path : $0.url.path + "/" }
        var covered = Set<UUID>()
        for (index, item) in items.enumerated() {
            let path = item.url.path
            for (otherIndex, folder) in folders.enumerated() where otherIndex != index {
                if path.hasPrefix(folder) {
                    covered.insert(item.id)
                    break
                }
            }
        }
        return covered
    }

    /// Executes the staged cleanup: moves every item to the Trash. Returns
    /// per-item results so the UI can report partial failures (e.g. a
    /// TCC-protected path) without losing track of what did succeed.
    @discardableResult
    public func commit() async -> [(item: StagedItem, error: Error?)] {
        await commitReport().entries.map { ($0.item, $0.error) }
    }

    /// `commit()` plus what it freed. Folders go first; an item inside a
    /// folder that moved successfully went with it, so it is reported as
    /// moved rather than retried and shown as a failure.
    public func commitReport() async -> CommitReport {
        await commitReport(movingToTrash: Self.moveToTrash)
    }

    /// The only function in the app that removes anything from its place on
    /// disk, and it only ever moves to the Trash. Returns where it went.
    private static func moveToTrash(_ url: URL) throws -> URL? {
        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
        return trashedURL as URL?
    }

    /// Seam for tests only, so the commit ordering can be checked without
    /// filling the developer's real Trash. Production code must go through
    /// `commitReport()`, whose mover is `moveToTrash` — never pass a deleting
    /// function here.
    func commitReport(movingToTrash move: (URL) throws -> URL?) async -> CommitReport {
        // The receipt must be computed from real measurements, and a moved
        // item can no longer be measured — so finish measuring first.
        await waitForMeasurements()
        let ordered = items.sorted {
            $0.url.pathComponents.count == $1.url.pathComponents.count
                ? $0.url.path < $1.url.path
                : $0.url.pathComponents.count < $1.url.pathComponents.count
        }
        // Moving to the Trash is a rename — measured 0.6 ms a file and 3 ms for
        // an 8k-file folder — so items go one at a time (the Windows build had
        // to batch its shell calls; MAC-FIXES-FROM-WINDOWS §2.1). What was
        // slow was this check scanning every moved path per item; a set and
        // the item's own ancestors make it O(depth).
        var moved = Set<String>()
        func insideMovedFolder(_ path: String) -> Bool {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty, parent != "/" {
                if moved.contains(parent) { return true }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return false
        }
        var outcomes: [(item: StagedItem, error: Error?, withFolder: Bool, trashed: URL?)] = []
        for item in ordered {
            let path = item.url.path
            if insideMovedFolder(path) {
                outcomes.append((item, nil, true, nil))
                continue
            }
            do {
                let trashed = try move(item.url)
                moved.insert(path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path)
                outcomes.append((item, nil, false, trashed))
            } catch {
                outcomes.append((item, error, false, nil))
            }
        }

        let succeeded = outcomes.filter { $0.error == nil }.map(\.item)
        let freed = Self.estimate(for: succeeded)
        let entries = outcomes.map { outcome in
            CommitEntry(
                item: outcome.item,
                error: outcome.error,
                movedWithFolder: outcome.withFolder,
                freedBytes: outcome.error == nil ? (freed.perItem[outcome.item.id] ?? 0) : 0,
                trashedURL: outcome.trashed
            )
        }

        // Clear only the items that succeeded, so failures stay staged
        // for the user to retry (e.g. after granting Full Disk Access).
        var failures: [UUID: String] = [:]
        for outcome in outcomes { if let error = outcome.error { failures[outcome.item.id] = Self.plainReason(error) } }
        items = items.compactMap { item in
            guard let reason = failures[item.id] else { return nil }
            var kept = item
            kept.lastFailure = reason
            return kept
        }
        return CommitReport(entries: entries, freedWhenTrashEmptied: freed.bytes, isLowerBound: freed.isLowerBound)
    }
}
