import Foundation
import CryptoKit

public struct DuplicateGroup: Sendable, Equatable {
    public let hash: String
    public let fileIDs: [Int32]
    public let sizeEach: Int64
    /// Members that are APFS clones of each other (sorted ids, two or more
    /// each). A clone set is ONE physical copy: its blocks stay until every
    /// member is gone. Files in no set occupy their own blocks.
    public let cloneSets: [[Int32]]

    /// True when every file shares one physical extent map. Deleting one
    /// copy does not free `sizeEach` — the blocks stay until the last
    /// copy in this group is gone.
    public var sharesStorage: Bool {
        cloneSets.count == 1 && cloneSets[0].count == fileIDs.count
    }

    /// Distinct sets of blocks among the copies.
    public var physicalCopies: Int {
        fileIDs.count - cloneSets.reduce(0) { $0 + $1.count - 1 }
    }

    public init(hash: String, fileIDs: [Int32], sizeEach: Int64, cloneSets: [[Int32]]) {
        self.hash = hash
        self.fileIDs = fileIDs
        self.sizeEach = sizeEach
        self.cloneSets = cloneSets.map { $0.sorted() }.filter { $0.count > 1 }.sorted { $0[0] < $1[0] }
    }

    public init(hash: String, fileIDs: [Int32], sizeEach: Int64, sharesStorage: Bool) {
        self.init(hash: hash, fileIDs: fileIDs, sizeEach: sizeEach, cloneSets: sharesStorage ? [fileIDs] : [])
    }

    /// The clone set `id` belongs to, or nil when it has its own blocks.
    public func cloneSet(of id: Int32) -> [Int32]? {
        cloneSets.first { $0.contains(id) }
    }

    /// Physical copies: each clone set, then each file on its own.
    private var physicalSets: [[Int32]] {
        let cloned = Set(cloneSets.joined())
        return cloneSets + fileIDs.filter { !cloned.contains($0) }.map { [$0] }
    }

    /// Bytes a later confirm would actually free. Content copies each
    /// occupy their own blocks. Shared extents count once, and only when
    /// every member of that clone set is being deleted.
    public func reclaimableBytes(deleting selected: Set<Int32>) -> Int64 {
        guard sizeEach > 0 else { return 0 }
        let freed = physicalSets.filter { set in set.allSatisfy(selected.contains) }.count
        return sizeEach * Int64(freed)
    }

    /// Same rule on the on-disk basis the treemap and cleanup queue use
    /// (TASK-038). `sizeEach` is the LOGICAL size because that is the matching
    /// key — two files can only be byte-identical if their lengths match —
    /// but what deleting frees is allocated space, which differs for
    /// compressed or sparse files. Callers showing a reclaim figure should use
    /// this with `tree.allocatedSize`.
    public func reclaimableBytes(deleting selected: Set<Int32>, onDisk: (Int32) -> Int64) -> Int64 {
        physicalSets.reduce(Int64(0)) { total, set in
            guard set.allSatisfy(selected.contains) else { return total }
            return total + max(0, set.map(onDisk).max() ?? 0)
        }
    }

    /// Oldest modified day, then lowest id. That file stays unchecked so
    /// a one-click stage keeps one original.
    public func defaultKeeperID(modifiedDay: (Int32) -> Int32) -> Int32? {
        fileIDs.min { lhs, rhs in
            let leftDay = modifiedDay(lhs)
            let rightDay = modifiedDay(rhs)
            if leftDay != rightDay { return leftDay < rightDay }
            return lhs < rhs
        }
    }
}


public enum DuplicateScanPhase: String, Sendable, Equatable {
    case idle
    case preparing
    case collecting
    case grouping
    case hashing
    case assembling
    case complete
    case noResults
    case cancelled
    case failed

    public var title: String {
        switch self {
        case .idle: return "Ready"
        case .preparing: return "Preparing duplicate search…"
        case .collecting: return "Collecting candidate files…"
        case .grouping: return "Grouping by size…"
        case .hashing: return "Hashing colliding files…"
        case .assembling: return "Assembling duplicate groups…"
        case .complete: return "Finished"
        case .noResults: return "No duplicates found"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        }
    }
}

public struct DuplicateScanResult: Sendable, Equatable {
    public var groups: [DuplicateGroup]
    public var fullContentHashCalls: Int
}

/// Three-phase duplicate detection, cheapest checks first:
///
///   1. Group by exact logical size.
///   2. Within a size group, hash only the first 64 KB.
///   3. Only for files that still collide, hash full content —
///      unless `CloneDetector.areLikelyClones` says they share a full
///      extent map. That check is the packed `F_LOG2PHYS_EXT` map from
///      TASK-005, not a first-block offset. A clone overwritten past the
///      64 KB window still collides on the partial hash and must be
///      hashed; a first-extent match would have grouped it as identical.
public enum DuplicateFinder {

    public static func findDuplicates(
        candidates: [(id: Int32, url: URL, size: Int64)],
        progress: (@Sendable (DuplicateScanPhase, Int, Int) -> Void)? = nil
    ) async throws -> [DuplicateGroup] {
        try await scan(candidates, progress: progress).groups
    }

    /// Regular files under `root`, skipping directories, empty files, and
    /// not-downloaded iCloud placeholders (opening those would download).
    public static func candidates(in tree: FileTree, root: URL) -> [(id: Int32, url: URL, size: Int64)] {
        (try? cancellableCandidates(in: tree, root: root, progress: nil)) ?? []
    }

    /// Builds candidate paths away from the main actor and cooperates with
    /// cancellation during very large tree walks.
    public static func candidatesAsync(
        in tree: FileTree,
        root: URL,
        collidingSizesOnly: Bool = true,
        progress: (@Sendable (_ examined: Int, _ candidates: Int) -> Void)? = nil
    ) async throws -> [(id: Int32, url: URL, size: Int64)] {
        let worker = Task.detached(priority: .userInitiated) {
            try cancellableCandidates(in: tree, root: root, collidingSizesOnly: collidingSizesOnly, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// `candidates` restricted to sizes occurring at least twice — the
    /// files that can actually collide (PR #16). `tree.path` is O(depth)
    /// string work per node, so building it only for size-colliding files
    /// skips nearly all of it on a real scan. Produces the same groups as
    /// running `scan` over `candidates`.
    public static func sizeCollidingCandidates(in tree: FileTree, root: URL) -> [(id: Int32, url: URL, size: Int64)] {
        (try? cancellableCandidates(in: tree, root: root, collidingSizesOnly: true, progress: nil)) ?? []
    }

    private static func isCandidate(_ index: Int, in tree: FileTree) -> Bool {
        !tree.isDirectory[index]
            && tree.flags[index] & NodeFlags.notDownloaded == 0
            && tree.logicalSize[index] > 0
    }

    private static func cancellableCandidates(
        in tree: FileTree,
        root: URL,
        collidingSizesOnly: Bool = false,
        progress: (@Sendable (_ examined: Int, _ candidates: Int) -> Void)?
    ) throws -> [(id: Int32, url: URL, size: Int64)] {
        var result: [(id: Int32, url: URL, size: Int64)] = []
        guard tree.count > 0 else { return result }
        // Size pre-pass (PR #16): a size seen once cannot be a duplicate. It
        // counts every name, so two names of one inode may still pass here;
        // the inode check below then keeps one of them, which is harmless.
        var countsBySize: [Int64: Int] = [:]
        if collidingSizesOnly {
            for index in 1..<tree.count where isCandidate(index, in: tree) {
                countsBySize[tree.logicalSize[index], default: 0] += 1
            }
        }
        var stack: [Int32] = [0]
        var examined = 0
        // Two names of one hard-linked inode are the same file, not a copy:
        // they hash identically and used to be offered as duplicates, but
        // deleting either frees nothing. Keep one name per inode (TASK-038).
        var seenLinkedInodes = Set<UInt64>()
        while let id = stack.popLast() {
            if examined & 2_047 == 0 {
                try Task.checkCancellation()
                progress?(examined, result.count)
            }
            let index = Int(id)
            if index > 0, isCandidate(index, in: tree),
               !collidingSizesOnly || countsBySize[tree.logicalSize[index], default: 0] > 1 {
                let isLinked = tree.flags[index] & NodeFlags.hardLink != 0 && tree.fileID[index] != 0
                if !isLinked || seenLinkedInodes.insert(tree.fileID[index]).inserted {
                    result.append((id, tree.path(of: id, root: root), tree.logicalSize[index]))
                }
            }
            var children: [Int32] = []
            var child = tree.firstChild[index]
            while child != -1 {
                children.append(child)
                child = tree.nextSibling[Int(child)]
            }
            stack.append(contentsOf: children.reversed())
            examined += 1
        }
        try Task.checkCancellation()
        progress?(examined, result.count)
        return result
    }

    public static func scan(
        _ candidates: [(id: Int32, url: URL, size: Int64)],
        progress: (@Sendable (DuplicateScanPhase, Int, Int) -> Void)? = nil
    ) async throws -> DuplicateScanResult {
        progress?(.grouping, 0, 0)
        var bySize: [Int64: [(id: Int32, url: URL)]] = [:]
        for candidate in candidates where candidate.size > 0 {
            try Task.checkCancellation()
            bySize[candidate.size, default: []].append((candidate.id, candidate.url))
        }

        let colliding = bySize.filter { $0.value.count > 1 }
        let totalBuckets = colliding.count
        progress?(.hashing, 0, totalBuckets)

        var groups: [DuplicateGroup] = []
        var fullContentHashCalls = 0
        var done = 0

        try await withThrowingTaskGroup(of: DuplicateScanResult.self) { taskGroup in
            for (size, files) in colliding {
                taskGroup.addTask {
                    try Task.checkCancellation()
                    return try hashAndGroup(files: files, size: size)
                }
            }
            for try await partial in taskGroup {
                try Task.checkCancellation()
                groups.append(contentsOf: partial.groups)
                fullContentHashCalls += partial.fullContentHashCalls
                done += 1
                progress?(.hashing, done, totalBuckets)
            }
        }

        progress?(.complete, totalBuckets, totalBuckets)
        return DuplicateScanResult(groups: groups, fullContentHashCalls: fullContentHashCalls)
    }

    private static func hashAndGroup(
        files: [(id: Int32, url: URL)],
        size: Int64
    ) throws -> DuplicateScanResult {
        var byPartialHash: [String: [(id: Int32, url: URL)]] = [:]
        for file in files {
            try Task.checkCancellation()
            guard let partial = try partialHash(url: file.url, bytes: 65_536) else { continue }
            byPartialHash[partial, default: []].append(file)
        }

        var groups: [DuplicateGroup] = []
        var fullContentHashCalls = 0
        for (_, collision) in byPartialHash where collision.count > 1 {
            let partitioned = partitionClones(collision)
            // Only one clone family and nothing else: identical by their
            // extent maps, no hashing needed.
            if partitioned.needsFullHash.isEmpty, partitioned.clusters.count == 1, let cluster = partitioned.clusters.first {
                groups.append(DuplicateGroup(hash: "shared-extents", fileIDs: cluster.map(\.id).sorted(),
                                             sizeEach: size, cloneSets: [cluster.map(\.id)]))
                continue
            }
            // Otherwise hash one member per clone family (they share blocks,
            // so contents) and every other file, and group by contents: a
            // family and a plain copy of the same file are one group. Kept
            // apart, the plain copies were reported without the family, and
            // copies in different families never met at all.
            var byFullHash: [String: (ids: [Int32], sets: [[Int32]])] = [:]
            let units: [[(id: Int32, url: URL)]] = partitioned.clusters + partitioned.needsFullHash.map { [$0] }
            for unit in units {
                try Task.checkCancellation()
                guard let representative = unit.first else { continue }
                fullContentHashCalls += 1
                guard let full = try fullHash(url: representative.url) else { continue }
                var entry = byFullHash[full] ?? ([], [])
                entry.ids += unit.map(\.id)
                if unit.count > 1 { entry.sets.append(unit.map(\.id)) }
                byFullHash[full] = entry
            }
            for (hash, entry) in byFullHash where entry.ids.count > 1 {
                groups.append(DuplicateGroup(hash: hash, fileIDs: entry.ids.sorted(), sizeEach: size, cloneSets: entry.sets))
            }
        }
        return DuplicateScanResult(groups: groups, fullContentHashCalls: fullContentHashCalls)
    }

    /// Full extent-map matches become clone groups and never reach
    /// `fullHash`. Everyone else, including a clone that has been
    /// written since, is hashed.
    private static func partitionClones(
        _ files: [(id: Int32, url: URL)]
    ) -> (clusters: [[(id: Int32, url: URL)]], needsFullHash: [(id: Int32, url: URL)]) {
        var remaining = files
        var clusters: [[(id: Int32, url: URL)]] = []
        var needsFullHash: [(id: Int32, url: URL)] = []
        while let seed = remaining.first {
            remaining.removeFirst()
            var cluster = [seed]
            var rest: [(id: Int32, url: URL)] = []
            for other in remaining {
                if CloneDetector.areLikelyClones(seed.url.path, other.url.path) {
                    cluster.append(other)
                } else {
                    rest.append(other)
                }
            }
            remaining = rest
            if cluster.count > 1 {
                clusters.append(cluster)
            } else {
                needsFullHash.append(seed)
            }
        }
        return (clusters, needsFullHash)
    }

    /// First-pass filter only. MD5 is fine here because colliding files still
    /// go through streaming SHA256 before they become a duplicate group.
    private static func partialHash(url: URL, bytes: Int) throws -> String? {
        try Task.checkCancellation()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes) else { return nil }
        try Task.checkCancellation()
        return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Streaming SHA256 — same digest as hashing a full `Data`, without
    /// holding the whole file in a contiguous buffer.
    private static func fullHash(url: URL) throws -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1024 * 1024
        while true {
            try Task.checkCancellation()
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkSize)
            } catch {
                return nil
            }
            // `read(upToCount:)` returns nil at EOF — that is success, not failure.
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
