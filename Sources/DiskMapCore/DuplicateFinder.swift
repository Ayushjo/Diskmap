import Foundation
import CryptoKit

public struct DuplicateGroup: Sendable, Equatable {
    public let hash: String
    public let fileIDs: [Int32]
    public let sizeEach: Int64
    /// True when every file shares one physical extent map. Deleting one
    /// copy does not free `sizeEach` — the blocks stay until the last
    /// copy in this group is gone.
    public let sharesStorage: Bool

    public init(hash: String, fileIDs: [Int32], sizeEach: Int64, sharesStorage: Bool) {
        self.hash = hash
        self.fileIDs = fileIDs
        self.sizeEach = sizeEach
        self.sharesStorage = sharesStorage
    }

    /// Bytes a later confirm would actually free. Content copies each
    /// occupy their own blocks. Shared extents count once, and only when
    /// every copy in the group is being deleted.
    public func reclaimableBytes(deleting selected: Set<Int32>) -> Int64 {
        let removing = fileIDs.filter { selected.contains($0) }
        guard !removing.isEmpty, sizeEach > 0 else { return 0 }
        if sharesStorage {
            return removing.count == fileIDs.count ? sizeEach : 0
        }
        return sizeEach * Int64(removing.count)
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
        progress: (@Sendable (_ examined: Int, _ candidates: Int) -> Void)? = nil
    ) async throws -> [(id: Int32, url: URL, size: Int64)] {
        let worker = Task.detached(priority: .userInitiated) {
            try cancellableCandidates(in: tree, root: root, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func cancellableCandidates(
        in tree: FileTree,
        root: URL,
        progress: (@Sendable (_ examined: Int, _ candidates: Int) -> Void)?
    ) throws -> [(id: Int32, url: URL, size: Int64)] {
        var result: [(id: Int32, url: URL, size: Int64)] = []
        guard tree.count > 0 else { return result }
        var stack: [Int32] = [0]
        var examined = 0
        while let id = stack.popLast() {
            if examined & 2_047 == 0 {
                try Task.checkCancellation()
                progress?(examined, result.count)
            }
            let index = Int(id)
            if index > 0 {
                let notDownloaded = tree.flags[index] & NodeFlags.notDownloaded != 0
                if !tree.isDirectory[index], !notDownloaded, tree.logicalSize[index] > 0 {
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
            for cluster in partitioned.clusters {
                groups.append(DuplicateGroup(
                    hash: "shared-extents",
                    fileIDs: cluster.map(\.id).sorted(),
                    sizeEach: size,
                    sharesStorage: true
                ))
            }
            var byFullHash: [String: [Int32]] = [:]
            for file in partitioned.needsFullHash {
                try Task.checkCancellation()
                fullContentHashCalls += 1
                guard let full = try fullHash(url: file.url) else { continue }
                byFullHash[full, default: []].append(file.id)
            }
            for (hash, ids) in byFullHash where ids.count > 1 {
                groups.append(DuplicateGroup(
                    hash: hash,
                    fileIDs: ids.sorted(),
                    sizeEach: size,
                    sharesStorage: false
                ))
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
