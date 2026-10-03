import Foundation

extension StorageSharing {
    /// What a finished scan knows, handed to the cleanup queue so staging a
    /// folder can be measured from the tree instead of walked again
    /// (TASK-082).
    public struct ScanContext: Sendable {
        public var tree: FileTree
        public var rootPath: String
        /// The tree is current up to this FSEvents id.
        public var eventID: UInt64
        public var volumeUUID: String?
        /// Folders the scan could not open.
        public var deniedIDs: Set<Int32>
        /// A file the caller owns, for `FSEventHistory.waitForPendingEvents`.
        public var barrierMarker: URL?
        public var capturedAt: Date

        public init(tree: FileTree, rootPath: String, eventID: UInt64, volumeUUID: String?, deniedIDs: Set<Int32>,
                    barrierMarker: URL?, capturedAt: Date) {
            self.tree = tree
            self.rootPath = rootPath
            self.eventID = eventID
            self.volumeUUID = volumeUUID
            self.deniedIDs = deniedIDs
            self.barrierMarker = barrierMarker
            self.capturedAt = capturedAt
        }
    }

    /// Files the tree cannot vouch for, asked about one by one. Past this a
    /// walk is the better tool.
    public static let seededFlaggedLimit = 5_000

    /// `profile(atPath:)` for a folder, computed from the scan tree — equal
    /// to what the walk would return, or nil when that cannot be promised:
    /// - the folder is not in the tree, or is a file (the walk of one file is
    ///   already one call);
    /// - anything under it changed since the scan (FSEvents, after a barrier),
    ///   the volume's event history was reset, or the replay timed out;
    /// - on APFS, the scan did not read every sharing fact (`.full`): with
    ///   less, an edited clone looks like a plain file and its shared blocks
    ///   would count as freed — an overestimate, the wrong direction;
    /// - more than `flaggedLimit` files need asking about, or a cloud-only
    ///   folder sits inside (the walk handles those as it always has).
    /// Plain files and clones are added from the tree (a `.full` scan read
    /// what the walk reads for them); hard links, cloud placeholders and
    /// files whose allocated size the scan had to estimate get a real
    /// `facts(atPath:)` call each — the tree holds no link count.
    ///
    /// The figure is the scan's, for a folder FSEvents says is unchanged. A
    /// file here cloned or hard-linked from *another* folder after the scan
    /// raises no event here; every scan-based number shares that window.
    public static func seededProfile(context: ScanContext, path: String,
                                     flaggedLimit: Int = seededFlaggedLimit) -> Profile? {
        if case .measured(let profile) = seededMeasurement(context: context, path: path, flaggedLimit: flaggedLimit) {
            return profile
        }
        return nil
    }

    /// `seededProfile`, with the reason when the tree cannot answer.
    public enum SeededOutcome: Sendable {
        case measured(Profile)
        case walkNeeded(String)
    }

    public static func seededMeasurement(context: ScanContext, path: String,
                                         flaggedLimit: Int = seededFlaggedLimit) -> SeededOutcome {
        let tree = context.tree
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard case .found(let node) = FileQuery.node(atPath: standardized, tree: tree, rootPath: context.rootPath),
              Int(node) < tree.count, tree.isDirectory[Int(node)] else { return .walkNeeded("not a folder in the scan") }
        let apfs = isAPFS(standardized)
        if apfs && tree.sharingMode != .full { return .walkNeeded("the scan did not read every sharing fact") }

        // Gather the subtree first, so nothing is measured past a limit.
        var plainAllocated: Int64 = 0
        var plainCount = 0
        var flagged: [Int32] = []
        var cloneFacts: [FileFacts] = []
        var leafFolders: [Int32] = []
        var complete = true
        var stack: [Int32] = [node]
        // The tree does not hold a link count, a cloud file's local bytes, or
        // the real allocation behind an estimate: those are asked about.
        let askFlags = NodeFlags.hardLink | NodeFlags.notDownloaded | NodeFlags.allocatedEstimated
        var rootInfo = stat()
        guard lstat(standardized, &rootInfo) == 0 else { return .walkNeeded("the folder is gone") }
        while let current = stack.popLast() {
            let index = Int(current)
            if tree.isDirectory[index] {
                if tree.flags[index] & NodeFlags.notDownloaded != 0 { return .walkNeeded("a cloud-only folder inside") }
                if context.deniedIDs.contains(current) { complete = false }
                var child = tree.firstChild[index]
                if child == -1, current != node { leafFolders.append(current) }
                while child != -1 {
                    stack.append(child)
                    child = tree.nextSibling[Int(child)]
                }
            } else if tree.flags[index] & askFlags != 0 {
                flagged.append(current)
                if flagged.count > flaggedLimit { return .walkNeeded("more than \(flaggedLimit) files to ask about") }
            } else if tree.flags[index] & NodeFlags.apfsClone != 0 {
                // A `.full` scan read exactly what the walk reads for a clone
                // (PRIVATESIZE, CLONEID, CLONE_REFCNT) on this device.
                guard let row = tree.sharing.row(of: current) else { return .walkNeeded("a clone without its facts") }
                cloneFacts.append(FileFacts(
                    device: Int32(rootInfo.st_dev), inode: tree.fileID[index], isDirectory: false, linkCount: 1,
                    allocated: tree.allocatedSize[index], privateSize: max(0, tree.sharing.privateBytes[row]),
                    cloneID: tree.sharing.cloneID[row], cloneRefcount: Int(tree.sharing.refcount[row])))
            } else {
                plainCount += 1
                plainAllocated += tree.allocatedSize[index]
            }
        }

        // Nothing under the folder may have changed since the scan.
        if let changed = changeSinceScan(standardized, context: context) { return .walkNeeded(changed) }

        var profile = Profile()
        profile.isComplete = complete
        profile.fileCount = plainCount
        profile.allocatedBytes = plainAllocated
        profile.ownedBytes = plainAllocated
        // The walk reads PRIVATESIZE on APFS, and a plain file's equals its
        // allocated size — the same sum, with the same flag.
        if apfs && plainCount > 0 { profile.usesFilesystemAccounting = true }
        let root = URL(fileURLWithPath: context.rootPath, isDirectory: true)
        for facts in cloneFacts { profile.add(facts) }
        for id in flagged {
            guard let facts = facts(atPath: tree.path(of: id, root: root).path, trustExtended: apfs) else {
                return .walkNeeded("a file changed or vanished")
            }
            profile.add(facts)
        }
        // An empty-looking folder can be another volume's mount point, which
        // the scan recorded but did not enter; the walk calls that incomplete.
        for id in leafFolders {
            var info = stat()
            guard lstat(tree.path(of: id, root: root).path, &info) == 0 else { return .walkNeeded("a folder vanished") }
            if info.st_dev != rootInfo.st_dev { profile.isComplete = false }
        }
        return .measured(profile)
    }

    /// `seededProfile` on a dedicated thread: the event replay blocks.
    public static func seededProfileOffPool(context: ScanContext, path: String) async -> Profile? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Profile?, Never>) in
            BulkScan.startScanThread(name: "DiskMap.cleanup.seeded") {
                continuation.resume(returning: seededProfile(context: context, path: path))
            }
        }
    }

    /// Nil when nothing under `path` changed since the scan; otherwise why.
    private static func changeSinceScan(_ path: String, context: ScanContext) -> String? {
        let realPath = FSEventHistory.realPath(path)
        guard let uuid = FSEventHistory.volumeUUID(forPath: realPath), uuid == context.volumeUUID else {
            return "the volume's change history is not the scan's"
        }
        if let marker = context.barrierMarker, !FSEventHistory.waitForPendingEvents(marker: marker) {
            return "pending changes did not settle"
        }
        guard FSEventHistory.currentEventID() >= context.eventID,
              let changes = FSEventHistory.changes(since: context.eventID, realPath: realPath, timeout: 5) else {
            return "the change history did not answer"
        }
        if let reason = changes.fullRescanReason { return reason }
        let count = changes.directories.count + changes.subtrees.count
        return count == 0 ? nil : "\(count) folder\(count == 1 ? "" : "s") changed since the scan"
    }
}
