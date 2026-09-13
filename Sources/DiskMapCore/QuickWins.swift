import Foundation

/// Regenerable directories found in an existing scan. The pattern list is
/// data (`quick-wins-patterns.json`) so it can grow without an app
/// release. Hits are for review — nothing here deletes.
public enum QuickWins {
    public struct Patterns: Sendable, Codable, Equatable {
        public var directoryNames: [String]
        public var pathSuffixes: [String]
    }

    public struct Hit: Sendable, Equatable, Identifiable {
        public var id: Int32
        public var name: String
    }

    public static func bundledPatterns() -> Patterns {
        if let url = Bundle.module.url(forResource: "quick-wins-patterns", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Patterns.self, from: data) {
            return decoded
        }
        return Patterns(
            directoryNames: ["node_modules", ".venv", "target", ".next", "dist", "build", "DerivedData"],
            pathSuffixes: ["Library/Caches", "Library/Developer/Xcode/iOS DeviceSupport"]
        )
    }

    /// Directories whose name or path matches `patterns`. A match swallows
    /// its descendants so `dist` inside `node_modules` is not counted twice.
    public static func find(in tree: FileTree, root: URL, patterns: Patterns) -> [Hit] {
        guard tree.count > 0 else { return [] }
        let names = Set(patterns.directoryNames)
        let suffixTails = Set(patterns.pathSuffixes.map { suffixTail($0) })
        var hits: [Hit] = []

        func walk(_ id: Int32) {
            let index = Int(id)
            if id != 0, tree.isDirectory[index], matches(id, names: names, suffixTails: suffixTails, patterns: patterns, root: root, tree: tree) {
                hits.append(Hit(id: id, name: tree.name(of: id)))
                return
            }
            var child = tree.firstChild[index]
            while child != -1 {
                walk(child)
                child = tree.nextSibling[Int(child)]
            }
        }
        walk(0)
        return hits
    }

    private static func matches(
        _ id: Int32,
        names: Set<String>,
        suffixTails: Set<String>,
        patterns: Patterns,
        root: URL,
        tree: FileTree
    ) -> Bool {
        let name = tree.name(of: id)
        if names.contains(name) { return true }
        guard suffixTails.contains(name) else { return false }
        let path = tree.path(of: id, root: root).standardizedFileURL.path
        for suffix in patterns.pathSuffixes {
            let expanded = (suffix as NSString).expandingTildeInPath
            if path == expanded || path.hasSuffix("/" + expanded) { return true }
            let relative = suffix.hasPrefix("~/") ? String(suffix.dropFirst(2)) : suffix
            if path.hasSuffix("/" + relative) { return true }
        }
        return false
    }

    private static func suffixTail(_ suffix: String) -> String {
        let expanded = (suffix as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).lastPathComponent
    }
}
