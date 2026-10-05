import Foundation

/// Where cloned copies inflate the totals of a scan that did not read clone
/// facts (`SharingMode.off`, the default).
///
/// Without clone facts, a folder of APFS clones adds up every copy in full:
/// measured on a real home, WhatsApp's group container showed 70.8 GB while
/// its clones (66.75 GB in 173k copies) occupied one set of blocks, so it
/// really used about 4 GB. Reading clone facts during the walk costs +14%
/// (median), so instead this samples the finished tree:
///
/// - Systematic, byte-weighted: every `step` bytes along the files in node
///   order, the file under that point is checked with one `getattrlist`. A
///   file is checked once, however many points land on it. A few thousand
///   checks take well under a second on a home scan.
/// - Each point stands for `step` bytes. A file in a clone family of `r` adds
///   `step × (1 − 1/r)` to the estimate for every folder above it: of `r`
///   copies, one set of blocks is real.
/// - `r` counts copies anywhere on the volume, so a folder whose copies sit
///   elsewhere reads as shared too. That is still true of the disk — deleting
///   that folder frees less than its size.
///
/// The result is an estimate, and the UI says "about". A rescan with clone
/// accounting on gives the exact figure.
public struct CloneSurvey: Sendable, Equatable {
    public struct Estimate: Sendable, Equatable {
        /// Sample points inside this folder.
        public var points: Int
        /// Bytes counted more than once by clone copies (estimated).
        public var sharedBytes: Int64
    }

    /// Bytes each sample point stands for.
    public var step: Int64
    /// Files checked with `getattrlist`.
    public var filesChecked: Int
    /// Per folder, for folders that drew at least one point in a family.
    public var estimates: [Int32: Estimate]
    /// Total sample points, including those that found no clone.
    public var pointsByFolder: [Int32: Int]

    public static let empty = CloneSurvey(step: 0, filesChecked: 0, estimates: [:], pointsByFolder: [:])

    /// Points a folder needs before its estimate is worth showing.
    public static let minimumPoints = 12
    /// Below this, an estimate is noise next to the folder's size.
    public static let minimumSharedBytes: Int64 = 512 * 1024 * 1024

    /// What `node` counts in full but probably occupies once, or nil when the
    /// sample is too thin or the effect too small to say anything.
    /// `minimumFraction` of `total` must be shared for it to be worth saying.
    public func sharedBytes(of node: Int32, total: Int64, minimumFraction: Double = 0.1,
                            minimumBytes: Int64 = CloneSurvey.minimumSharedBytes) -> Int64? {
        guard let estimate = estimates[node], (pointsByFolder[node] ?? 0) >= Self.minimumPoints else { return nil }
        let shared = min(estimate.sharedBytes, max(0, total))
        guard shared >= minimumBytes, total > 0, Double(shared) / Double(total) >= minimumFraction else { return nil }
        return shared
    }

    /// Folders where clones explain the size, most inflated first. A folder
    /// is left out when one child holds most of its shared bytes — that child
    /// is the more useful answer (WhatsApp's container, not ~/Library).
    public func inflatedFolders(tree: FileTree, totals: [Int64], limit: Int = 5,
                                minimumBytes: Int64 = CloneSurvey.minimumSharedBytes) -> [(id: Int32, shared: Int64)] {
        var qualifying: [Int32: Int64] = [:]
        for id in estimates.keys where Int(id) < totals.count && Int(id) < tree.count {
            if let shared = sharedBytes(of: id, total: totals[Int(id)], minimumBytes: minimumBytes) { qualifying[id] = shared }
        }
        var largestChild: [Int32: Int64] = [:]
        for (id, shared) in qualifying {
            let up = tree.parent[Int(id)]
            if up >= 0, up != id { largestChild[up] = max(largestChild[up] ?? 0, shared) }
        }
        var picked: [(id: Int32, shared: Int64)] = []
        for (id, shared) in qualifying where Double(largestChild[id] ?? 0) < Double(shared) * 0.8 {
            picked.append((id, shared))
        }
        picked.sort { $0.shared != $1.shared ? $0.shared > $1.shared : $0.id < $1.id }
        // Keep the deepest answer per branch: drop a folder whose descendant
        // is already listed.
        var result: [(id: Int32, shared: Int64)] = []
        for candidate in picked where result.count < limit {
            let ancestors = Set(tree.ancestorIDs(of: candidate.id))
            if result.contains(where: { ancestors.contains($0.id) || tree.ancestorIDs(of: $0.id).contains(candidate.id) }) { continue }
            result.append(candidate)
        }
        return result
    }

    /// Samples `tree` (scanned from `root`, sizes `allocated`). Returns
    /// `.empty` off APFS, for a scan that already read clone facts, or when
    /// cancelled. Blocks while it reads — call it off the main actor.
    public static func run(tree: FileTree, root: URL, allocated: [Int64], points: Int = 3000,
                           isCancelled: () -> Bool = { false }) -> CloneSurvey {
        guard !tree.hasSharingInfo, tree.count > 1, allocated.count == tree.count,
              StorageSharing.isAPFS(root.path) else { return .empty }
        return sample(tree: tree, root: root, allocated: allocated, points: points, isCancelled: isCancelled) { path in
            guard let facts = StorageSharing.facts(atPath: path, trustExtended: true),
                  !facts.isDirectory, facts.linkCount <= 1 else { return nil }
            return facts.cloneRefcount
        }
    }

    /// The sampling itself, with the filesystem read injected for tests.
    /// `refcount` returns the file's clone family size, or nil when unknown;
    /// it is called from several threads at once.
    static func sample(tree: FileTree, root: URL, allocated: [Int64], points: Int,
                       isCancelled: () -> Bool = { false },
                       refcount: @Sendable (String) -> Int?) -> CloneSurvey {
        let fileTotal = (0..<tree.count).reduce(Int64(0)) { sum, i in
            tree.isDirectory[i] ? sum : sum + max(0, tree.allocatedSize[i])
        }
        guard fileTotal > 0, points > 0 else { return .empty }
        let step = max(1, fileTotal / Int64(points))

        // Which files the points land on. First point half a step in, so the
        // sample is the same every run.
        var picks: [(node: Int32, hits: Int)] = []
        picks.reserveCapacity(points)
        var next = step / 2
        var cursor: Int64 = 0
        for i in 0..<tree.count where !tree.isDirectory[i] {
            let end = cursor + max(0, tree.allocatedSize[i])
            defer { cursor = end }
            guard next < end else { continue }
            var hits = 0
            while next < end { hits += 1; next += step }
            picks.append((Int32(i), hits))
        }

        // One getattrlist per file, in parallel: on a home scan the reads
        // are mostly cold metadata, ~1 ms each one at a time.
        // Plain string joins: `path(of:root:)` builds URLs, which took
        // 0.6 s for 2,000 paths on a home scan.
        let rootPath = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
        let paths = picks.map { pick -> String in
            var names: [String] = []
            var node = pick.node
            while node > 0, names.count < 4096 {
                names.append(tree.name(of: node))
                node = tree.parent[Int(node)]
            }
            return rootPath + "/" + names.reversed().joined(separator: "/")
        }
        var families = [Int](repeating: 1, count: picks.count)
        let lanes = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
        families.withUnsafeMutableBufferPointer { out in
            let base = out.baseAddress
            DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                var k = lane
                while k < paths.count {
                    base?[k] = refcount(paths[k]) ?? 1
                    k += lanes
                }
            }
        }
        if isCancelled() { return .empty }

        var survey = CloneSurvey(step: step, filesChecked: picks.count, estimates: [:], pointsByFolder: [:])
        for (k, pick) in picks.enumerated() {
            let r = families[k]
            let shared = r > 1 ? Int64((Double(step * Int64(pick.hits)) * (1 - 1 / Double(r))).rounded()) : 0
            var folder = tree.parent[Int(pick.node)]
            var depth = 0
            while folder >= 0, depth < 4096 {
                survey.pointsByFolder[folder, default: 0] += pick.hits
                if shared > 0 {
                    var estimate = survey.estimates[folder] ?? Estimate(points: 0, sharedBytes: 0)
                    estimate.points += pick.hits
                    estimate.sharedBytes += shared
                    survey.estimates[folder] = estimate
                }
                let up = tree.parent[Int(folder)]
                if up == folder { break }
                folder = up
                depth += 1
            }
        }
        return survey
    }
}
