import Foundation

/// The last picture of one folder, kept so the next scan can start from it
/// (TASK-061): a tree file plus a small JSON baseline. One slot per client
/// ("app", "cli"), overwritten on every scan — disk use is bounded to one
/// tree per client, and nothing ever has to be deleted to keep it that way.
public struct ScanCache: Sendable {
    public let directory: URL
    public let slot: String

    public init(directory: URL, slot: String = "last") {
        self.directory = directory
        self.slot = slot
    }

    /// ~/Library/Application Support/DiskMap/ScanCache
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DiskMap/ScanCache", isDirectory: true)
    }

    public struct Baseline: Codable, Sendable, Equatable {
        public var rootPath: String
        /// FSEvents id captured before the walk (or replay) that produced the tree.
        public var eventID: UInt64
        public var volumeUUID: String
        /// When the disk was last walked in full. Incremental updates never
        /// move this; the policy forces a full walk when it gets old.
        public var fullScanAt: Date
        public var updatedAt: Date
        public var incrementalRuns: Int
        /// Folders that could not be opened, carried across updates.
        public var deniedPaths: [String]

        public init(rootPath: String, eventID: UInt64, volumeUUID: String, fullScanAt: Date,
                    updatedAt: Date, incrementalRuns: Int, deniedPaths: [String]) {
            self.rootPath = rootPath
            self.eventID = eventID
            self.volumeUUID = volumeUUID
            self.fullScanAt = fullScanAt
            self.updatedAt = updatedAt
            self.incrementalRuns = incrementalRuns
            self.deniedPaths = deniedPaths
        }
    }

    func treeURL(for rootPath: String) -> URL { directory.appendingPathComponent(slot + ".tree") }
    func baselineURL(for rootPath: String) -> URL { directory.appendingPathComponent(slot + ".json") }

    public func baseline(for rootPath: String) -> Baseline? {
        guard let data = try? Data(contentsOf: baselineURL(for: rootPath)),
              let baseline = try? JSONDecoder().decode(Baseline.self, from: data),
              baseline.rootPath == rootPath else { return nil }
        return baseline
    }

    func loadTree(for rootPath: String) -> FileTree? {
        guard let snapshot = try? SnapshotStore.load(from: treeURL(for: rootPath)),
              snapshot.rootPath == rootPath else { return nil }
        return snapshot.tree
    }

    /// The tree is written before the baseline, and both atomically, so a
    /// crash in between leaves an old baseline that simply fails to match.
    public func save(tree: FileTree, baseline: Baseline) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = DiskSnapshot(rootPath: baseline.rootPath, capturedAt: baseline.updatedAt, tree: tree)
        try SnapshotCodec.encode(snapshot).write(to: treeURL(for: baseline.rootPath), options: .atomic)
        try JSONEncoder().encode(baseline).write(to: baselineURL(for: baseline.rootPath), options: .atomic)
    }

    /// Makes the next update fall back to a full walk (the baseline no longer
    /// matches any tree), without deleting anything.
    public func invalidate(rootPath: String) {
        guard var baseline = baseline(for: rootPath) else { return }
        baseline.volumeUUID = ""
        try? JSONEncoder().encode(baseline).write(to: baselineURL(for: rootPath), options: .atomic)
    }
}

/// Brings a cached tree up to date by re-listing only the folders FSEvents
/// says changed (TASK-061). Any doubt — a reset event database, dropped
/// events, a stale or over-used baseline, a spot check that disagrees with
/// the disk — returns `.fullScanNeeded` with the reason, never a guess.
public enum IncrementalScan {

    public struct Policy: Sendable {
        /// Full walk after this many incremental updates in a row.
        public var maxIncrementalRuns = 20
        /// Full walk when the last one is older than this.
        public var maxAge: TimeInterval = 7 * 86_400
        /// Past this many changed folders a full walk is simpler and not much slower.
        public var maxChangedDirectories = 20_000
        /// Unchanged folders re-read to confirm FSEvents missed nothing.
        public var spotChecks = 64
        public init() {}
    }

    public struct Update: Sendable {
        public var tree: FileTree
        public var baseline: ScanCache.Baseline
        public var deniedDirectoryIDs: [Int32]
        public var changedDirectories: Int
        public var rewalkedSubtrees: Int
        public var spotChecked: Int
        public var elapsedSeconds: Double

        /// The same shape a full walk returns, for callers that take either.
        public var scanResult: ScanEngine.Result {
            let flags = tree.flags
            return ScanEngine.Result(
                tree: tree, itemCount: max(0, tree.count - 1), elapsedSeconds: elapsedSeconds,
                peakResidentBytesDuringWalk: 0, residentBytesAfterEnumeratorRelease: nil,
                notDownloadedCount: flags.reduce(0) { $0 + ($1 & NodeFlags.notDownloaded != 0 ? 1 : 0) },
                hardLinkCount: flags.reduce(0) { $0 + ($1 & NodeFlags.hardLink != 0 ? 1 : 0) },
                crossMountSkipCount: 0, deniedDirectoryIDs: deniedDirectoryIDs,
                vanishedDirectoryCount: 0, otherUnopenedDirectoryCount: 0,
                eventIDAtStart: baseline.eventID
            )
        }
    }

    public enum Outcome: Sendable {
        case updated(Update)
        case fullScanNeeded(reason: String)
    }

    /// The baseline to save after a full walk. `eventIDAtStart` must have
    /// been read before the walk began.
    public static func baselineAfterFullScan(root: URL, eventIDAtStart: UInt64, deniedPaths: [String],
                                             now: Date = Date()) -> ScanCache.Baseline? {
        guard let uuid = FSEventHistory.volumeUUID(forPath: FSEventHistory.realPath(root.path)) else { return nil }
        return ScanCache.Baseline(rootPath: root.path, eventID: eventIDAtStart, volumeUUID: uuid, fullScanAt: now,
                                  updatedAt: now, incrementalRuns: 0, deniedPaths: deniedPaths)
    }

    /// A tree already in memory and the baseline that produced it. Starting
    /// from it skips reading the cache from disk (~0.45 s of a ~0.75 s
    /// update on a 2.25M-node home), which is what a Rescan in the app does.
    public struct Base: Sendable {
        public var tree: FileTree
        public var baseline: ScanCache.Baseline
        public init(tree: FileTree, baseline: ScanCache.Baseline) {
            self.tree = tree
            self.baseline = baseline
        }
    }

    /// Runs on a dedicated thread (the walk engine's rule: blocking work never
    /// sits on the cooperative pool).
    public static func update(root: URL, cache: ScanCache, base: Base? = nil, sharing: SharingMode = .off,
                              policy: Policy = Policy(), now: Date = Date()) async -> Outcome {
        await withCheckedContinuation { continuation in
            BulkScan.startScanThread(name: "DiskMap.incremental") {
                continuation.resume(returning: updateSync(root: root, cache: cache, base: base, sharing: sharing,
                                                          policy: policy, now: now))
            }
        }
    }

    static func updateSync(root: URL, cache: ScanCache, base: Base? = nil, sharing: SharingMode = .off,
                           policy: Policy, now: Date) -> Outcome {
        let started = Date()
        let rootPath = root.path
        guard !CanonicalPath.mayContainFirmlinkTwins(scanRootPath: rootPath) else {
            return .fullScanNeeded(reason: "system-volume scans are always walked in full")
        }
        let inMemory = base.flatMap { $0.baseline.rootPath == rootPath ? $0 : nil }
        guard let baseline = inMemory?.baseline ?? cache.baseline(for: rootPath) else {
            return .fullScanNeeded(reason: "no earlier scan of this folder")
        }
        let realRoot = FSEventHistory.realPath(rootPath)
        guard let uuid = FSEventHistory.volumeUUID(forPath: realRoot), uuid == baseline.volumeUUID else {
            return .fullScanNeeded(reason: "the volume's change history was reset")
        }
        if baseline.incrementalRuns >= policy.maxIncrementalRuns {
            return .fullScanNeeded(reason: "periodic full rescan (\(baseline.incrementalRuns) quick updates in a row)")
        }
        if now.timeIntervalSince(baseline.fullScanAt) > policy.maxAge {
            return .fullScanNeeded(reason: "periodic full rescan (last full scan over a week ago)")
        }
        FSEventHistory.waitForPendingEvents(marker: cache.directory.appendingPathComponent(".event-barrier"))
        let newEventID = FSEventHistory.currentEventID()
        guard baseline.eventID <= newEventID else {
            return .fullScanNeeded(reason: "the change history is older than the last scan")
        }
        guard let changes = FSEventHistory.changes(since: baseline.eventID, realPath: realRoot) else {
            return .fullScanNeeded(reason: "the change history did not answer in time")
        }
        if let reason = changes.fullRescanReason { return .fullScanNeeded(reason: reason) }

        // Event paths are real paths; express them relative to the scan root.
        func relative(_ path: String) -> String? {
            if path == realRoot { return "" }
            if path.hasPrefix(realRoot + "/") { return String(path.dropFirst(realRoot.count + 1)) }
            if path == rootPath { return "" }
            if path.hasPrefix(rootPath + "/") { return String(path.dropFirst(rootPath.count + 1)) }
            return nil
        }
        let changed = changes.directories.compactMap(relative)
        let subtrees = changes.subtrees.compactMap(relative)
        if changed.count + subtrees.count > policy.maxChangedDirectories {
            return .fullScanNeeded(reason: "\(changed.count + subtrees.count) folders changed")
        }
        guard let old = inMemory?.tree ?? cache.loadTree(for: rootPath), old.count > 0 else {
            return .fullScanNeeded(reason: "the saved scan could not be read")
        }
        // Clone accounting must match the saved tree's, or the totals would
        // mix counted-once and counted-per-copy clones (TASK-077).
        let layout = BulkScan.sharingLayout(rootPath: rootPath, requested: sharing)
        if (layout != nil) != old.hasSharingInfo {
            return .fullScanNeeded(reason: layout != nil ? "the saved scan predates clone accounting"
                                                         : "clone accounting was turned off")
        }

        var rootInfo = stat()
        guard lstat(rootPath, &rootInfo) == 0 else { return .fullScanNeeded(reason: "the folder can't be read") }
        var rebuild = Rebuild(old: old, rootPath: rootPath, rootDevID: Int32(rootInfo.st_dev))
        rebuild.sharing = layout
        rebuild.sharingMode = sharing
        for path in changed { rebuild.markChanged(relativePath: path, subtree: false) }
        for path in subtrees { rebuild.markChanged(relativePath: path, subtree: true) }
        rebuild.carriedDenied = Set(baseline.deniedPaths)
        rebuild.run(rootModifiedDay: Int32(max(0, rootInfo.st_mtimespec.tv_sec / 86_400)))

        let checked = rebuild.spotCheck(limit: policy.spotChecks)
        if let mismatch = checked.mismatch {
            return .fullScanNeeded(reason: "a spot check found an unreported change in \(CanonicalPath.displayPath(absolutePath: mismatch))")
        }

        var tree = rebuild.new
        tree.compact()
        var deniedIDs = rebuild.newDenied
        var deniedPaths = Set(deniedIDs.map { tree.path(of: $0, root: root).path })
        for path in rebuild.carriedDenied where !deniedPaths.contains(path) {
            if case .found(let id) = FileQuery.node(atPath: path, tree: tree, rootPath: rootPath) {
                deniedIDs.append(id)
                deniedPaths.insert(path)
            }
        }
        let updated = ScanCache.Baseline(
            rootPath: rootPath, eventID: newEventID, volumeUUID: uuid, fullScanAt: baseline.fullScanAt,
            updatedAt: now, incrementalRuns: baseline.incrementalRuns + 1, deniedPaths: deniedPaths.sorted()
        )
        return .updated(Update(
            tree: tree, baseline: updated, deniedDirectoryIDs: deniedIDs.sorted(),
            changedDirectories: rebuild.relisted, rewalkedSubtrees: rebuild.rewalked,
            spotChecked: checked.count, elapsedSeconds: Date().timeIntervalSince(started)
        ))
    }

    /// Copies the old tree into a new one, re-listing changed folders and
    /// walking new or unreliable subtrees. The copy keeps `parent[i] < i`
    /// (every node is appended after its parent) and drops deleted entries,
    /// so the result is indistinguishable from a tree the walk produced.
    struct Rebuild {
        let old: FileTree
        let rootPath: String
        let rootDevID: Int32
        var new: FileTree
        var changedIDs = Set<Int32>()
        var subtreeIDs = Set<Int32>()
        var carriedDenied = Set<String>()
        var newDenied: [Int32] = []
        /// New-tree ids whose children were read from disk in this update.
        var freshIDs = Set<Int32>()
        var relisted = 0
        var rewalked = 0
        /// Read and carry APFS sharing facts (TASK-077).
        var sharing: SharingLayout?
        var sharingMode: SharingMode = .off

        init(old: FileTree, rootPath: String, rootDevID: Int32) {
            self.old = old
            self.rootPath = rootPath
            self.rootDevID = rootDevID
            self.new = old.emptiedKeepingNames()
        }

        /// Marks the deepest existing folder on `relativePath`. A path that
        /// no longer resolves means something new or gone below that folder,
        /// which re-listing the folder discovers.
        mutating func markChanged(relativePath: String, subtree: Bool) {
            var current: Int32 = 0
            var complete = true
            for component in relativePath.split(separator: "/") {
                var child = old.firstChild[Int(current)]
                var next: Int32 = -1
                while child != -1 {
                    if old.name(of: child) == component { next = child; break }
                    child = old.nextSibling[Int(child)]
                }
                guard next != -1, old.isDirectory[Int(next)] else { complete = false; break }
                current = next
            }
            if subtree && complete { subtreeIDs.insert(current) } else { changedIDs.insert(current) }
            // A folder's own dates and size fields come from its parent's
            // listing, and the parent gets no event when only the folder's
            // contents change. Re-list the parent too, so they are exact.
            let parentID = old.parent[Int(current)]
            if parentID >= 0 { changedIDs.insert(parentID) }
        }

        func path(_ newID: Int32) -> String {
            new.path(of: newID, root: URL(fileURLWithPath: rootPath)).path
        }

        mutating func run(rootModifiedDay: Int32) {
            new.hasSharingInfo = sharing != nil
            let rootID = new.appendNodeReusingName(
                old.nameIndex[0], parent: -1, isDirectory: true,
                logicalSize: old.logicalSize[0], allocatedSize: old.allocatedSize[0],
                modifiedDaysSinceEpoch: rootModifiedDay, createdDaysSinceEpoch: old.createdDay[0],
                flags: old.flags[0], fileID: old.fileID[0]
            )
            var stack: [(old: Int32, new: Int32)] = [(0, rootID)]
            while let (oldID, newID) = stack.popLast() {
                if subtreeIDs.contains(oldID) {
                    walkFresh(path(newID), under: newID)
                } else if changedIDs.contains(oldID) {
                    relist(oldID: oldID, newID: newID, stack: &stack)
                } else {
                    var child = old.firstChild[Int(oldID)]
                    while child != -1 {
                        let copied = copy(child, under: newID)
                        if old.isDirectory[Int(child)] { stack.append((child, copied)) }
                        child = old.nextSibling[Int(child)]
                    }
                }
            }
        }

        mutating func copy(_ oldID: Int32, under parent: Int32) -> Int32 {
            let i = Int(oldID)
            let id = new.appendNodeReusingName(
                old.nameIndex[i], parent: parent, isDirectory: old.isDirectory[i],
                logicalSize: old.logicalSize[i], allocatedSize: old.allocatedSize[i],
                modifiedDaysSinceEpoch: old.modifiedDay[i], createdDaysSinceEpoch: old.createdDay[i],
                flags: old.flags[i] & ~NodeFlags.apfsClone, fileID: old.fileID[i]
            )
            carrySharing(from: old, oldID, to: id)
            return id
        }

        /// The sharing row of `sourceID` in `source`, re-recorded for `newID`.
        /// Rows stay sorted because nodes are appended in id order.
        mutating func carrySharing(from source: FileTree, _ sourceID: Int32, to newID: Int32) {
            guard sharing != nil, source.flags[Int(sourceID)] & NodeFlags.apfsClone != 0,
                  let row = source.sharing.row(of: sourceID) else { return }
            new.appendSharing(node: newID, cloneID: source.sharing.cloneID[row],
                              privateBytes: source.sharing.privateBytes[row], refcount: source.sharing.refcount[row])
        }

        mutating func relist(oldID: Int32, newID: Int32, stack: inout [(old: Int32, new: Int32)]) {
            let folder = path(newID)
            relisted += 1
            freshIDs.insert(newID)
            switch BulkScan.list(directoryPath: folder, sharing: sharing) {
            case .unopened(let code):
                if code == EACCES || code == EPERM { newDenied.append(newID) }
                carriedDenied.remove(folder)
            case .listed(let entries):
                carriedDenied.remove(folder)
                var oldChildren: [Int32: Int32] = [:]   // name id → old child
                var child = old.firstChild[Int(oldID)]
                while child != -1 {
                    oldChildren[old.nameIndex[Int(child)]] = child
                    child = old.nextSibling[Int(child)]
                }
                for entry in entries {
                    let nameID = entry.name.withUnsafeBufferPointer { new.nameID(forUTF8: $0) }
                    let id = new.appendNodeReusingName(
                        nameID, parent: newID, isDirectory: entry.isDirectory,
                        logicalSize: entry.logical, allocatedSize: entry.allocated,
                        modifiedDaysSinceEpoch: entry.day, createdDaysSinceEpoch: entry.createdDay,
                        flags: entry.flags, fileID: entry.fileID
                    )
                    if sharing != nil, entry.sharesBlocks, entry.devID == rootDevID {
                        new.appendSharing(node: id, cloneID: entry.cloneID, privateBytes: entry.privateBytes,
                                          refcount: entry.cloneRefcount)
                    }
                    // Same descent rules as the walk: not across volumes, not
                    // into cloud placeholders or symlinks.
                    guard entry.isDirectory, entry.descend, entry.devID == rootDevID else { continue }
                    if let previous = oldChildren[nameID], old.isDirectory[Int(previous)] {
                        stack.append((previous, id))   // unchanged inside unless its own event says so
                    } else {
                        walkFresh(path(id), under: id)
                    }
                }
            }
        }

        /// Walks a folder with the full engine and grafts its children in.
        mutating func walkFresh(_ folder: String, under newID: Int32) {
            rewalked += 1
            freshIDs.insert(newID)
            carriedDenied = carriedDenied.filter { $0 != folder && !$0.hasPrefix(folder + "/") }
            let result = BulkScan.walk(root: URL(fileURLWithPath: folder, isDirectory: true),
                                       sharing: sharing != nil ? sharingMode : .off, progress: nil)
            let fresh = result.tree
            guard fresh.count > 1 else {
                if result.deniedDirectoryIDs.contains(0) { newDenied.append(newID) }
                return
            }
            var map = [Int32](repeating: -1, count: fresh.count)
            map[0] = newID
            for index in 1..<fresh.count {
                let parentID = map[Int(fresh.parent[index])]
                let nameID = fresh.withNameUTF8(at: fresh.nameIndex[index]) { new.nameID(forUTF8: $0) }
                map[index] = new.appendNodeReusingName(
                    nameID, parent: parentID, isDirectory: fresh.isDirectory[index],
                    logicalSize: fresh.logicalSize[index], allocatedSize: fresh.allocatedSize[index],
                    modifiedDaysSinceEpoch: fresh.modifiedDay[index], createdDaysSinceEpoch: fresh.createdDay[index],
                    flags: fresh.flags[index] & ~NodeFlags.apfsClone, fileID: fresh.fileID[index]
                )
                carrySharing(from: fresh, Int32(index), to: map[index])
                if fresh.isDirectory[index] { freshIDs.insert(map[index]) }
            }
            newDenied += result.deniedDirectoryIDs.compactMap { $0 >= 0 && Int($0) < map.count ? map[Int($0)] : nil }
        }

        /// Re-reads up to `limit` folders the update copied without looking,
        /// plus the root, and compares them to the tree.
        func spotCheck(limit: Int) -> (count: Int, mismatch: String?) {
            var candidates: [Int32] = [0]
            var copiedFolders: [Int32] = []
            for index in 1..<new.count where new.isDirectory[index] && !freshIDs.contains(Int32(index)) {
                copiedFolders.append(Int32(index))
            }
            var generator = SystemRandomNumberGenerator()
            copiedFolders.shuffle(using: &generator)
            candidates += copiedFolders.prefix(limit)
            let denied = Set(newDenied)
            var count = 0
            for id in candidates where !denied.contains(id) {
                let folder = path(id)
                if carriedDenied.contains(folder) { continue }
                guard case .listed(let entries) = BulkScan.list(directoryPath: folder) else { continue }
                count += 1
                var expected: [[UInt8]: (Bool, Int64, Int32)] = [:]
                var child = new.firstChild[Int(id)]
                while child != -1 {
                    let c = Int(child)
                    let name = new.withNameUTF8(at: new.nameIndex[c]) { Array($0) }
                    expected[name] = (new.isDirectory[c], new.isDirectory[c] ? 0 : new.logicalSize[c], new.modifiedDay[c])
                    child = new.nextSibling[c]
                }
                guard expected.count == entries.count else { return (count, folder) }
                for entry in entries {
                    // Files by size and date; folders by presence (their own
                    // size fields and dates move with their contents, which
                    // their own events cover).
                    guard let known = expected[entry.name], known.0 == entry.isDirectory,
                          entry.isDirectory || (known.1 == entry.logical && known.2 == entry.day) else {
                        return (count, folder)
                    }
                }
            }
            return (count, nil)
        }
    }
}
