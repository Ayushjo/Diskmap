import Foundation

/// Regenerable directories found in an existing scan. The pattern list is
/// data (`quick-wins-patterns.json`) so it can grow without an app
/// release. Hits are for review — nothing here deletes.
public enum QuickWins {
    public struct Patterns: Sendable, Codable, Equatable {
        public var directoryNames: [String]
        public var pathSuffixes: [String]
    }

    /// A themed bucket of patterns — e.g. "JavaScript / Node.js" — so the
    /// Developer page can group hits and explain per ecosystem why the
    /// data comes back.
    public struct Category: Sendable, Codable, Equatable, Identifiable {
        public var id: String
        /// Header shown above the group.
        public var title: String
        /// Why items in this bucket are safe to stage.
        public var note: String
        public var directoryNames: [String]
        public var pathSuffixes: [String]

        public init(id: String, title: String, note: String, directoryNames: [String], pathSuffixes: [String]) {
            self.id = id
            self.title = title
            self.note = note
            self.directoryNames = directoryNames
            self.pathSuffixes = pathSuffixes
        }
    }

    public struct Hit: Sendable, Equatable, Identifiable {
        public var id: Int32
        public var name: String
        /// `Category.id` of the bucket that matched. Nil through the flat
        /// `find(patterns:)` API.
        public var categoryID: String?

        public init(id: Int32, name: String, categoryID: String? = nil) {
            self.id = id
            self.name = name
            self.categoryID = categoryID
        }
    }

    /// On-disk shape of `quick-wins-patterns.json`. The categorized form
    /// is `{"categories": [...]}`; a flat `{"directoryNames": ...,
    /// "pathSuffixes": ...}` file still decodes as a single category so
    /// an older user-edited list keeps working.
    private struct PatternFile: Codable {
        var categories: [Category]?
        var directoryNames: [String]?
        var pathSuffixes: [String]?
    }

    public static func bundledCategories() -> [Category] {
        if let url = Bundle.module.url(forResource: "quick-wins-patterns", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(PatternFile.self, from: data) {
            if let categories = file.categories { return categories }
            return [Category(
                id: "quick-wins",
                title: "Quick Wins",
                note: "",
                directoryNames: file.directoryNames ?? [],
                pathSuffixes: file.pathSuffixes ?? []
            )]
        }
        return fallbackCategories()
    }

    /// Union of every category — the flat Quick Wins page catches the
    /// same set the grouped Developer page reports.
    public static func bundledPatterns() -> Patterns {
        let categories = bundledCategories()
        return Patterns(
            directoryNames: categories.flatMap(\.directoryNames),
            pathSuffixes: categories.flatMap(\.pathSuffixes)
        )
    }

    private static func fallbackCategories() -> [Category] {
        [Category(
            id: "quick-wins",
            title: "Quick Wins",
            note: "",
            directoryNames: ["node_modules", ".venv", "target", ".next", "dist", "build", "DerivedData"],
            pathSuffixes: ["Library/Caches", "Library/Developer/Xcode/iOS DeviceSupport"]
        )]
    }

    /// Directories whose name or path matches `patterns`. A match swallows
    /// its descendants so `dist` inside `node_modules` is not counted twice.
    public static func find(in tree: FileTree, root: URL, patterns: Patterns) -> [Hit] {
        findCategorized(in: tree, root: root, categories: [
            Category(
                id: "quick-wins",
                title: "Quick Wins",
                note: "",
                directoryNames: patterns.directoryNames,
                pathSuffixes: patterns.pathSuffixes
            ),
        ]).map { Hit(id: $0.id, name: $0.name) }
    }

    /// One walk over the tree attributing each hit to the first category
    /// that claims it — categories apply in order, so put the most
    /// specific first. Names resolve against the interned name table
    /// once per unique string (a `node_modules` seen ten thousand times
    /// is one lookup), not once per directory.
    public static func findCategorized(in tree: FileTree, root: URL, categories: [Category]) -> [Hit] {
        guard tree.count > 0 else { return [] }

        var nameToCategory: [String: Int] = [:]
        var tailToRules: [String: [(category: Int, suffix: String)]] = [:]
        for (index, category) in categories.enumerated() {
            for name in category.directoryNames where nameToCategory[name] == nil {
                nameToCategory[name] = index
            }
            for suffix in category.pathSuffixes {
                tailToRules[suffixTail(suffix), default: []].append((category: index, suffix: suffix))
            }
        }

        let nameTable = tree.nameTable
        var categoryByNameID = [Int32](repeating: -1, count: nameTable.count)
        var rulesByNameID: [Int32: [(category: Int, suffix: String)]] = [:]
        rulesByNameID.reserveCapacity(tailToRules.count)
        for (offset, name) in nameTable.enumerated() {
            if let category = nameToCategory[name] {
                categoryByNameID[offset] = Int32(category)
            }
            if let rules = tailToRules[name] {
                rulesByNameID[Int32(offset)] = rules
            }
        }

        var hits: [Hit] = []
        func walk(_ id: Int32) {
            let index = Int(id)
            if id != 0, tree.isDirectory[index] {
                let nameID = tree.nameIndex[index]
                var match: Int32 = -1
                if categoryByNameID[Int(nameID)] >= 0 {
                    match = categoryByNameID[Int(nameID)]
                } else if let rules = rulesByNameID[nameID] {
                    // A path build is O(depth) string work, so it runs only
                    // for names that could end a listed suffix.
                    let path = tree.path(of: id, root: root).standardizedFileURL.path
                    for rule in rules where matchesSuffix(path: path, suffix: rule.suffix) {
                        match = Int32(rule.category)
                        break
                    }
                }
                if match >= 0 {
                    hits.append(Hit(id: id, name: tree.name(of: id), categoryID: categories[Int(match)].id))
                    return
                }
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

    private static func matchesSuffix(path: String, suffix: String) -> Bool {
        let expanded = (suffix as NSString).expandingTildeInPath
        if path == expanded || path.hasSuffix("/" + expanded) { return true }
        let relative = suffix.hasPrefix("~/") ? String(suffix.dropFirst(2)) : suffix
        return path.hasSuffix("/" + relative)
    }

    private static func suffixTail(_ suffix: String) -> String {
        let expanded = (suffix as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).lastPathComponent
    }
}
