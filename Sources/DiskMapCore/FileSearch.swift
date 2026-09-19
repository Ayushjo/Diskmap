import Foundation

/// Find-as-you-type name search over a scanned `FileTree`.
///
/// Names are interned in the tree, so matching runs once per unique name
/// (~10⁵ entries) instead of once per node (~10⁶+). At build time a
/// counting sort groups node ids by name id, so a keystroke only touches
/// the nodes whose interned name actually matched — there is no per-node
/// string work in the query path.
///
/// Ranking keeps the top `limit` by `totals` without sorting the whole
/// match set: a bounded insert into at most `limit` entries, skipping
/// anything at or under the current cutoff once the list is full.
public struct FileSearchIndex: Sendable {

    public enum KindFilter: String, Sendable, CaseIterable, Identifiable {
        case all = "All"
        case folders = "Folders"
        case files = "Files"

        public var id: String { rawValue }
    }

    public struct Result: Sendable, Equatable {
        /// Matching node ids, highest `totals` first, capped at `limit`.
        public var ids: [Int32]
        /// All matching nodes before the cap — `ids` are the biggest of these.
        public var totalMatches: Int
        /// Distinct interned names that matched.
        public var matchedNames: Int

        public static let empty = Result(ids: [], totalMatches: 0, matchedNames: 0)
    }

    /// `nameTable` lowercased once at build instead of per keystroke.
    private let loweredNames: [String]
    /// Node ids grouped by name id: `nodes[offsets[n]..<offsets[n + 1]]`.
    private let nodes: [Int32]
    private let offsets: [Int]
    private let nodeCount: Int

    public init(tree: FileTree) {
        nodeCount = tree.count
        loweredNames = tree.nameTable.map { $0.lowercased() }

        var counts = [Int](repeating: 0, count: tree.nameTable.count)
        for nameID in tree.nameIndex { counts[Int(nameID)] += 1 }
        var offsets = [Int](repeating: 0, count: counts.count + 1)
        for index in counts.indices { offsets[index + 1] = offsets[index] + counts[index] }
        var cursor = offsets
        var nodes = [Int32](repeating: -1, count: tree.nameIndex.count)
        for (index, nameID) in tree.nameIndex.enumerated() {
            nodes[cursor[Int(nameID)]] = Int32(index)
            cursor[Int(nameID)] += 1
        }
        self.offsets = offsets
        self.nodes = nodes
    }

    /// Nodes whose interned name contains `query` (case-insensitive),
    /// ranked by `totals` and capped at `limit`. Empty or whitespace
    /// queries match nothing. The index and `tree`/`totals` must describe
    /// the same scan — sizes are trusted by node id.
    public func search(
        _ query: String,
        in tree: FileTree,
        totals: [Int64],
        kind: KindFilter = .all,
        limit: Int = 300
    ) -> Result {
        let needle = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, limit > 0, nodeCount == tree.count, totals.count == tree.count else {
            return .empty
        }

        var best: [(id: Int32, size: Int64)] = []
        best.reserveCapacity(limit + 1)
        var cutoff = Int64.min
        var totalMatches = 0
        var matchedNames = 0

        for nameID in loweredNames.indices where loweredNames[nameID].contains(needle) {
            let before = totalMatches
            for position in offsets[nameID]..<offsets[nameID + 1] {
                let id = nodes[position]
                let index = Int(id)
                switch kind {
                case .folders where !tree.isDirectory[index]: continue
                case .files where tree.isDirectory[index]: continue
                case .all, .folders, .files: break
                }
                totalMatches += 1
                let size = totals[index]
                if best.count == limit, size <= cutoff { continue }
                insert(&best, id: id, size: size, limit: limit)
                cutoff = best.last?.size ?? Int64.min
            }
            // A name whose nodes are all filtered out doesn't count.
            if totalMatches > before { matchedNames += 1 }
        }

        return Result(ids: best.map(\.id), totalMatches: totalMatches, matchedNames: matchedNames)
    }

    /// Sorted-descending insert into a list capped at `limit`.
    private func insert(_ best: inout [(id: Int32, size: Int64)], id: Int32, size: Int64, limit: Int) {
        var lo = 0
        var hi = best.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if best[mid].size >= size { lo = mid + 1 } else { hi = mid }
        }
        best.insert((id: id, size: size), at: lo)
        if best.count > limit { best.removeLast() }
    }
}
