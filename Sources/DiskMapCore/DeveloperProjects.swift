import Foundation

/// What it costs to get a developer folder back after deleting it (TASK-052).
/// This, not size, is the decision a developer actually makes.
public enum RebuildCost: String, Sendable, Equatable, CaseIterable, Comparable {
    /// Regenerated automatically and offline the next time the tool runs.
    case free
    /// An offline rebuild: CPU time, no network.
    case cheap
    /// Re-downloaded from a registry or vendor.
    case networked
    /// Re-downloaded, and the project has no lockfile: reinstalling may not
    /// reproduce what is there now.
    case networkedUnpinned

    public var title: String {
        switch self {
        case .free: return "Free to rebuild"
        case .cheap: return "Rebuilds offline"
        case .networked: return "Re-downloads"
        case .networkedUnpinned: return "Re-downloads · no lockfile"
        }
    }

    public var explanation: String {
        switch self {
        case .free: return "Regenerated automatically, offline, the next time the tool runs."
        case .cheap: return "Rebuilt from your source on the next build — takes CPU time, no network."
        case .networked: return "Downloaded again from a package registry on the next install."
        case .networkedUnpinned:
            return "Downloaded again on the next install — and this project has no lockfile, so the versions you get may not match what is installed now."
        }
    }

    private var rank: Int { RebuildCost.allCases.firstIndex(of: self) ?? 0 }
    public static func < (lhs: RebuildCost, rhs: RebuildCost) -> Bool { lhs.rank < rhs.rank }
}

/// Answers project questions from the scan tree alone: which folder is the
/// project (nearest manifest), whether a lockfile exists, where the git
/// repository starts. Child names of each folder are read once and cached,
/// since many hits share ancestors.
struct ProjectLocator {
    let tree: FileTree
    let manifestNames: Set<String>
    let manifestSuffixes: [String]
    private(set) var childNamesCache: [Int32: Set<String>] = [:]

    init(tree: FileTree, manifestNames: Set<String>, manifestSuffixes: [String]) {
        self.tree = tree
        self.manifestNames = manifestNames
        self.manifestSuffixes = manifestSuffixes
    }

    mutating func childNames(of id: Int32) -> Set<String> {
        if let cached = childNamesCache[id] { return cached }
        var names = Set<String>()
        var child = tree.firstChild[Int(id)]
        while child != -1 {
            names.insert(tree.name(of: child))
            child = tree.nextSibling[Int(child)]
        }
        childNamesCache[id] = names
        return names
    }

    /// The manifest that makes `id` a project root, if any.
    mutating func manifest(in id: Int32) -> String? {
        let names = childNames(of: id)
        if let hit = names.first(where: { manifestNames.contains($0) }) {
            // Deterministic when a folder has several (package.json + Cargo.toml).
            return names.filter { manifestNames.contains($0) }.min() ?? hit
        }
        return names.filter { name in manifestSuffixes.contains { name.hasSuffix($0) } }.min()
    }

    /// Nearest folder at or above `start` that holds a manifest, never going
    /// above the scan root (node 0). Starts from a hit's parent; hits nested
    /// inside another hit were already dropped, so the walk does not begin
    /// inside someone else's dependency folder.
    mutating func projectRoot(from start: Int32) -> (id: Int32, manifest: String)? {
        var current = start
        var steps = 0
        while current >= 0, steps < 64 {
            if let manifest = manifest(in: current) { return (current, manifest) }
            if current == 0 { return nil }
            current = tree.parent[Int(current)]
            steps += 1
        }
        return nil
    }

    /// Nearest folder at or above `start` containing `.git` (a folder or a
    /// worktree/submodule file).
    mutating func repositoryRoot(from start: Int32) -> Int32? {
        var current = start
        var steps = 0
        while current >= 0, steps < 64 {
            if childNames(of: current).contains(".git") { return current }
            if current == 0 { return nil }
            current = tree.parent[Int(current)]
            steps += 1
        }
        return nil
    }

    /// First lockfile found in `from` or any folder above it, up to and
    /// including `stopAt` (the repository root) or the scan root. Workspace
    /// managers (pnpm, yarn, npm workspaces) keep one lockfile at the top.
    mutating func lockfile(named candidates: [String], from: Int32, stopAt: Int32?) -> String? {
        var current = from
        var steps = 0
        while current >= 0, steps < 64 {
            let names = childNames(of: current)
            if let hit = candidates.first(where: { names.contains($0) }) { return hit }
            if current == stopAt || current == 0 { return nil }
            current = tree.parent[Int(current)]
            steps += 1
        }
        return nil
    }
}
