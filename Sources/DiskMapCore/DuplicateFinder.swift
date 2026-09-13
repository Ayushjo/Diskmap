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

struct DuplicateScanResult: Sendable, Equatable {
    var groups: [DuplicateGroup]
    var fullContentHashCalls: Int
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
        candidates: [(id: Int32, url: URL, size: Int64)]
    ) async -> [DuplicateGroup] {
        await scan(candidates).groups
    }

    /// Regular files under `root`, skipping directories, empty files, and
    /// not-downloaded iCloud placeholders (opening those would download).
    public static func candidates(in tree: FileTree, root: URL) -> [(id: Int32, url: URL, size: Int64)] {
        var result: [(id: Int32, url: URL, size: Int64)] = []
        func walk(_ id: Int32) {
            let index = Int(id)
            if index > 0 {
                let notDownloaded = tree.flags[index] & NodeFlags.notDownloaded != 0
                if !tree.isDirectory[index], !notDownloaded, tree.logicalSize[index] > 0 {
                    result.append((id, tree.path(of: id, root: root), tree.logicalSize[index]))
                }
            }
            var child = tree.firstChild[index]
            while child != -1 {
                walk(child)
                child = tree.nextSibling[Int(child)]
            }
        }
        if tree.count > 0 { walk(0) }
        return result
    }

    static func scan(
        _ candidates: [(id: Int32, url: URL, size: Int64)]
    ) async -> DuplicateScanResult {
        var bySize: [Int64: [(id: Int32, url: URL)]] = [:]
        for candidate in candidates where candidate.size > 0 {
            bySize[candidate.size, default: []].append((candidate.id, candidate.url))
        }

        var groups: [DuplicateGroup] = []
        var fullContentHashCalls = 0

        await withTaskGroup(of: DuplicateScanResult.self) { taskGroup in
            for (size, files) in bySize where files.count > 1 {
                taskGroup.addTask {
                    hashAndGroup(files: files, size: size)
                }
            }
            for await partial in taskGroup {
                groups.append(contentsOf: partial.groups)
                fullContentHashCalls += partial.fullContentHashCalls
            }
        }

        return DuplicateScanResult(groups: groups, fullContentHashCalls: fullContentHashCalls)
    }

    private static func hashAndGroup(
        files: [(id: Int32, url: URL)],
        size: Int64
    ) -> DuplicateScanResult {
        var byPartialHash: [String: [(id: Int32, url: URL)]] = [:]
        for file in files {
            guard let partial = partialHash(url: file.url, bytes: 65_536) else { continue }
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
                fullContentHashCalls += 1
                guard let full = fullHash(url: file.url) else { continue }
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

    private static func partialHash(url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes) else { return nil }
        return digest(data)
        // SHA256 stays for Milestone 2. A faster hash is a performance
        // follow-up after duplicates ship, not a correctness gap.
    }

    private static func fullHash(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return digest(data)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }
}
