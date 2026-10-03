import Foundation

/// Two snapshots of the same folder, aligned by name one level at a time.
///
/// The old flat diff listed every folder whose total changed, so one new
/// 5 GB file deep in Downloads appeared as ~, ~/Downloads, ~/Downloads/x …
/// each "+5 GB", and building it meant a path string for every folder of both
/// trees (52 s on a real 2.2M-node home). Here nothing is aligned until it is
/// looked at: the first screen needs only the root's children, and every
/// level's rows add up to their parent.
public struct SnapshotComparison: Sendable {

    public struct Entry: Sendable, Equatable, Identifiable {
        /// Path relative to the root, "" for the root itself.
        public var path: String
        public var name: String
        public var beforeID: Int32?
        public var afterID: Int32?
        public var before: Int64
        public var after: Int64
        public var isDirectory: Bool

        public var id: String { path }
        public var delta: Int64 { after - before }

        /// Nil when nothing changed.
        public var kind: SnapshotChangeKind? {
            if beforeID == nil && afterID != nil { return .added }
            if afterID == nil && beforeID != nil { return .removed }
            if delta > 0 { return .grew }
            if delta < 0 { return .shrunk }
            return nil
        }
    }

    public let before: DiskSnapshot
    public let after: DiskSnapshot
    let beforeTotals: [Int64]
    let afterTotals: [Int64]

    public init(before: DiskSnapshot, after: DiskSnapshot, basis: SizeBasis) {
        self.before = before
        self.after = after
        beforeTotals = before.tree.rollUpSizes(basis: basis)
        afterTotals = after.tree.rollUpSizes(basis: basis)
    }

    /// Paths only line up when both snapshots were taken of the same folder.
    public var rootsMatch: Bool { before.rootPath == after.rootPath }

    public var root: Entry {
        let hasBefore = before.tree.count > 0 && beforeTotals.count == before.tree.count
        let hasAfter = after.tree.count > 0 && afterTotals.count == after.tree.count
        return Entry(
            path: "", name: (after.rootPath as NSString).lastPathComponent,
            beforeID: hasBefore ? 0 : nil, afterID: hasAfter ? 0 : nil,
            before: hasBefore ? beforeTotals[0] : 0, after: hasAfter ? afterTotals[0] : 0,
            isDirectory: true
        )
    }

    public func absolutePath(of entry: Entry) -> String {
        entry.path.isEmpty ? after.rootPath : (after.rootPath == "/" ? "/" : after.rootPath + "/") + entry.path
    }

    /// Children of `entry`, matched by name, largest change first (then
    /// largest size). Unchanged children are left out unless asked for.
    public func children(of entry: Entry, includeUnchanged: Bool = false) -> [Entry] {
        guard entry.isDirectory else { return [] }
        var beforeByName: [String: Int32] = [:]
        if let id = entry.beforeID {
            var child = before.tree.firstChild[Int(id)]
            while child != -1 {
                beforeByName[before.tree.name(of: child)] = child
                child = before.tree.nextSibling[Int(child)]
            }
        }
        var result: [Entry] = []
        let prefix = entry.path.isEmpty ? "" : entry.path + "/"
        if let id = entry.afterID {
            var child = after.tree.firstChild[Int(id)]
            while child != -1 {
                let name = after.tree.name(of: child)
                let match = beforeByName.removeValue(forKey: name)
                result.append(Entry(
                    path: prefix + name, name: name, beforeID: match, afterID: child,
                    before: match.map { beforeTotals[Int($0)] } ?? 0, after: afterTotals[Int(child)],
                    isDirectory: after.tree.isDirectory[Int(child)]
                ))
                child = after.tree.nextSibling[Int(child)]
            }
        }
        for (name, id) in beforeByName {
            result.append(Entry(
                path: prefix + name, name: name, beforeID: id, afterID: nil,
                before: beforeTotals[Int(id)], after: 0, isDirectory: before.tree.isDirectory[Int(id)]
            ))
        }
        if !includeUnchanged { result.removeAll { $0.delta == 0 } }
        return result.sorted {
            abs($0.delta) != abs($1.delta) ? abs($0.delta) > abs($1.delta)
                : max($0.before, $0.after) != max($1.before, $1.after) ? max($0.before, $0.after) > max($1.before, $1.after)
                : $0.name < $1.name
        }
    }

    /// Walks `path` ("Library/Caches") down from the root; nil if either side
    /// never had it.
    public func entry(atPath path: String) -> Entry? {
        var current = root
        for component in path.split(separator: "/").map(String.init) {
            guard let next = children(of: current, includeUnchanged: true).first(where: { $0.name == component }) else {
                return nil
            }
            current = next
        }
        return current
    }

    /// Sum of the growing and of the shrinking children of `entry` — the
    /// two halves of its net change, one level down.
    public func split(of entry: Entry) -> (grew: Int64, shrank: Int64) {
        children(of: entry).reduce((grew: Int64(0), shrank: Int64(0))) { acc, child in
            child.delta > 0 ? (acc.grew + child.delta, acc.shrank) : (acc.grew, acc.shrank + child.delta)
        }
    }

    /// Where the changes actually happened. Starting at the root, descend
    /// while up to three children explain the change (≥ 80%, same direction);
    /// stop at a folder whose change is spread across many small items, at
    /// a file, or at a folder that is new or gone as a whole. Only entries
    /// that changed by at least `minimumChange` are visited, so this stays
    /// fast on millions of nodes.
    public func hotspots(minimumChange: Int64, limit: Int = 50) -> [Entry] {
        var found: [Entry] = []
        var stack = [root]
        var visited = 0
        while let entry = stack.popLast(), visited < 20_000 {
            visited += 1
            guard abs(entry.delta) >= minimumChange else { continue }
            let wholeUnit = !entry.isDirectory || entry.kind == .added || entry.kind == .removed
            if wholeUnit && !entry.path.isEmpty {
                found.append(entry)
                continue
            }
            let big = children(of: entry).filter { abs($0.delta) >= minimumChange }
            if !big.isEmpty, Self.fewExplain(entry, big) {
                stack.append(contentsOf: big)
            } else if !entry.path.isEmpty {
                found.append(entry)
            } else {
                stack.append(contentsOf: big)
            }
        }
        return Array(found.sorted { abs($0.delta) > abs($1.delta) }.prefix(limit))
    }

    /// At most three children, moving the same way as `entry`, account for
    /// 80% of its change. When it takes more (WhatsApp media growing across
    /// forty chats) the folder itself is the story, not forty rows.
    static func fewExplain(_ entry: Entry, _ big: [Entry]) -> Bool {
        let target = abs(entry.delta) * 4 / 5
        var explained: Int64 = 0
        for child in big.filter({ ($0.delta > 0) == (entry.delta > 0) }).prefix(3) {
            explained += abs(child.delta)
            if explained >= target { return true }
        }
        return false
    }

    /// A sensible floor for `hotspots`: 0.1% of the larger total, at least 10 MB.
    public var defaultMinimumChange: Int64 {
        max(10_000_000, max(root.before, root.after) / 1_000)
    }
}
