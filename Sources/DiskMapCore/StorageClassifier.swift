import Foundation

/// What removing something means, from fine to never.
public enum CleanupAdvice: String, Sendable, Equatable, Codable {
    /// Regenerable, or plainly the user's own to decide.
    case fine
    /// Comes back by re-downloading or rebuilding, at a cost.
    case review
    /// Moving it to the Trash breaks something (Docker, a VM, an app, a
    /// browser profile, a repository's history): ask first, say what to do instead.
    case warn
    /// macOS manages it: never offered for cleanup.
    case never

    /// Warn and never are skipped by bulk adds (MAC-FIXES-FROM-WINDOWS §3.2).
    public var isRisky: Bool { self == .warn || self == .never }
}

/// One of the storage categories every byte of a scan falls into.
public struct StorageClass: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var colorHex: String
    public var blurb: String
}

/// Where a path belongs and what removing it means.
public struct StorageVerdict: Sendable, Equatable {
    public var storageClass: StorageClass
    public var advice: CleanupAdvice
    /// Why removing it is risky, or what to check first.
    public var note: String?
    /// The right way to get the space back.
    public var instead: String?
}

/// Where bytes live and what removing them means — ported from the Windows
/// build's `StorageClassifier` (docs/MAC-FIXES-FROM-WINDOWS.md §3). Rules are
/// data: `storage-categories.json` (AGENTS.md rule 6).
///
/// A rule matches a folder path. A *claim* takes the whole folder; an *area*
/// sets the default category for everything below and keeps looking, so
/// `~/Documents/code/app/node_modules` is still Dependencies. First matching
/// rule wins. `rollup` walks the tree once and credits every byte to exactly
/// one category, so the categories sum to the scan.
public enum StorageClassifier {

    // MARK: Model

    enum Anchor: Equatable { case root, home, anywhere }

    struct Glob: Equatable {
        let parts: [String]   // split on "*"; ["x"] is an exact name
        let isAny: Bool       // "?"

        init(_ raw: String) {
            isAny = raw == "?"
            parts = raw.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        }

        var exact: String? { !isAny && parts.count == 1 ? parts[0] : nil }

        func matches(_ name: String) -> Bool {
            if isAny { return true }
            if parts.count == 1 { return name == parts[0] }
            guard let first = parts.first, let last = parts.last,
                  name.count >= first.count + last.count,
                  name.hasPrefix(first), name.hasSuffix(last) else { return false }
            var rest = name.dropFirst(first.count).dropLast(last.count)
            for middle in parts.dropFirst().dropLast() where !middle.isEmpty {
                guard let range = rest.range(of: middle) else { return false }
                rest = rest[range.upperBound...]
            }
            return true
        }
    }

    struct Rule {
        let anchor: Anchor
        let segments: [Glob]
        let classIndex: Int
        let claim: Bool
        let advice: CleanupAdvice
        let note: String?

        /// `path` is canonical, lower-cased segments from the disk root.
        func matches(_ path: ArraySlice<String>) -> Bool {
            let n = segments.count
            switch anchor {
            case .root:
                guard path.count == n else { return false }
                return zip(segments, path).allSatisfy { $0.matches($1) }
            case .home:
                guard path.count == n + 2, path.first == "users" else { return false }
                return zip(segments, path.dropFirst(2)).allSatisfy { $0.matches($1) }
            case .anywhere:
                guard path.count >= n else { return false }
                return zip(segments, path.suffix(n)).allSatisfy { $0.matches($1) }
            }
        }
    }

    struct FileRule {
        let classIndex: Int
        let advice: CleanupAdvice
        let note: String?
    }

    struct Table {
        var classes: [StorageClass] = []
        var notes: [String: (note: String, instead: String?)] = [:]
        var rules: [Rule] = []
        /// Rules whose last segment is an exact name, by that name; the rest
        /// are checked against every folder.
        var byLastName: [String: [Int]] = [:]
        var globRules: [Int] = []
        var filesByName: [String: FileRule] = [:]
        var filesByExtension: [String: FileRule] = [:]
        var otherIndex = 0
        /// File or folder names that make their folder a project.
        var projectMarkers: Set<String> = []
        var projectsIndex: Int?
        /// Areas in which a project marker turns a folder into a project.
        var markerAreas: Set<Int> = []

        func firstMatch(_ path: ArraySlice<String>) -> Int? {
            guard let last = path.last else { return nil }
            var best: Int?
            for index in byLastName[last] ?? [] where best.map({ index < $0 }) ?? true {
                if rules[index].matches(path) { best = index; break }
            }
            for index in globRules where best.map({ index < $0 }) ?? true {
                if rules[index].matches(path) { best = index; break }
            }
            return best
        }

        func fileRule(named name: String) -> FileRule? {
            if let rule = filesByName[name] { return rule }
            let ext = (name as NSString).pathExtension
            return ext.isEmpty ? nil : filesByExtension[ext]
        }

        func verdict(_ classIndex: Int, _ advice: CleanupAdvice, _ noteKey: String?) -> StorageVerdict {
            let note = noteKey.flatMap { notes[$0] }
            return StorageVerdict(storageClass: classes[classIndex], advice: advice, note: note?.note, instead: note?.instead)
        }
    }

    // MARK: Loading

    private struct File: Decodable {
        struct Class: Decodable { var id: String; var title: String; var color: String; var blurb: String }
        struct Note: Decodable { var note: String; var instead: String? }
        struct RuleEntry: Decodable { var pattern: String; var `class`: String; var kind: String; var advice: String; var note: String? }
        struct FileEntry: Decodable {
            var names: [String]?; var extensions: [String]?
            var `class`: String; var advice: String; var note: String?
        }
        var classes: [Class]
        var notes: [String: Note]
        var rules: [RuleEntry]
        var fileRules: [FileEntry]
        var projectMarkers: [String]?
    }

    /// A malformed file yields an empty table (everything is Other) rather
    /// than a crash; rules naming an unknown class or advice are dropped.
    static func loadTable(from data: Data? = nil) -> Table {
        let bytes = data ?? DiskMapResources.url(forResource: "storage-categories", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
        var table = Table()
        guard let bytes, let file = try? JSONDecoder().decode(File.self, from: bytes) else {
            table.classes = [StorageClass(id: "other", title: "Other", colorHex: "#A2A4AC", blurb: "")]
            return table
        }
        table.classes = file.classes.map { StorageClass(id: $0.id, title: $0.title, colorHex: "#" + $0.color, blurb: $0.blurb) }
        if !table.classes.contains(where: { $0.id == "other" }) {
            table.classes.append(StorageClass(id: "other", title: "Other", colorHex: "#A2A4AC", blurb: ""))
        }
        table.otherIndex = table.classes.firstIndex { $0.id == "other" } ?? 0
        table.projectMarkers = Set((file.projectMarkers ?? []).map { $0.lowercased() })
        table.projectsIndex = table.classes.firstIndex { $0.id == "projects" }
        table.markerAreas = Set(["other", "documents", "downloads"].compactMap { id in table.classes.firstIndex { $0.id == id } })
        table.notes = file.notes.mapValues { ($0.note, $0.instead) }
        let classIndex = Dictionary(table.classes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        for entry in file.rules {
            guard let cls = classIndex[entry.class], let advice = CleanupAdvice(rawValue: entry.advice),
                  entry.kind == "claim" || entry.kind == "area" else { continue }
            let pattern = entry.pattern.lowercased()
            let anchor: Anchor = pattern.hasPrefix("/") ? .root : pattern.hasPrefix("~/") ? .home : .anywhere
            let body = anchor == .root ? String(pattern.dropFirst()) : anchor == .home ? String(pattern.dropFirst(2)) : pattern
            let segments = body.split(separator: "/").map { Glob(String($0)) }
            guard !segments.isEmpty else { continue }
            let index = table.rules.count
            table.rules.append(Rule(anchor: anchor, segments: segments, classIndex: cls,
                                    claim: entry.kind == "claim", advice: advice, note: entry.note))
            if let last = segments.last?.exact { table.byLastName[last, default: []].append(index) } else { table.globRules.append(index) }
        }
        for entry in file.fileRules {
            guard let cls = classIndex[entry.class], let advice = CleanupAdvice(rawValue: entry.advice) else { continue }
            let rule = FileRule(classIndex: cls, advice: advice, note: entry.note)
            for name in entry.names ?? [] { table.filesByName[name.lowercased()] = rule }
            for ext in entry.extensions ?? [] { table.filesByExtension[ext.lowercased()] = rule }
        }
        return table
    }

    static let table = loadTable()

    // MARK: Public API

    /// Every category, in display order.
    public static var classes: [StorageClass] { table.classes }

    public static func storageClass(id: String) -> StorageClass? { table.classes.first { $0.id == id } }

    /// Categories that are developer storage, for Overview's stories.
    public static let developerClassIDs: Set<String> = ["projects", "deps", "devtools", "pkgcache", "vms", "ai"]

    /// Lower-cased segments from the disk root, with the Data volume's
    /// firmlinked prefix removed (`/System/Volumes/Data/Users/x` is `/Users/x`).
    static func canonicalSegments(_ path: String) -> [String] {
        var segments = path.lowercased().split(separator: "/").map(String.init)
        if segments.count > 3, segments[0] == "system", segments[1] == "volumes", segments[2] == "data" {
            segments.removeFirst(3)
        }
        return segments
    }

    /// Where one path belongs. Folders only look at folder rules; a file
    /// also gets its name or extension rule, which beats an area but never
    /// a claim (a `.vmdk` inside Docker's folder is Docker's).
    public static func classify(path: String, isDirectory: Bool) -> StorageVerdict {
        let t = table
        let segments = canonicalSegments(path)
        let folderDepth = isDirectory ? segments.count : segments.count - 1
        var area: Rule?
        if folderDepth >= 1 {
            for depth in 1...folderDepth {
                guard let index = t.firstMatch(segments[0..<depth]) else { continue }
                let rule = t.rules[index]
                if rule.claim { return t.verdict(rule.classIndex, rule.advice, rule.note) }
                area = rule
            }
        }
        if !isDirectory, let name = segments.last, let file = t.fileRule(named: name) {
            return t.verdict(file.classIndex, file.advice, file.note)
        }
        if let area { return t.verdict(area.classIndex, area.advice, area.note) }
        return t.verdict(t.otherIndex, .fine, nil)
    }

    /// One category's share of a scan, and its biggest single node (for
    /// "show me" — Overview opens Visualize there).
    public struct ClassTotal: Sendable, Equatable {
        public var storageClass: StorageClass
        public var bytes: Int64
        public var largestNode: Int32?
    }

    /// Every byte of `tree` credited to exactly one category, largest first,
    /// Other last. One depth-first pass; file rules resolve once per unique
    /// name.
    /// `rootIsHome`: the scan root is a home folder even if it is not under
    /// /Users (a backup at /Volumes/B/me), so `~/` rules apply to it.
    public static func rollup(tree: FileTree, root: URL, totals: [Int64], rootIsHome: Bool = false) -> [ClassTotal] {
        let t = table
        guard tree.count > 0, totals.count == tree.count else { return [] }
        var bytes = [Int64](repeating: 0, count: t.classes.count)
        var largest = [(node: Int32, size: Int64)?](repeating: nil, count: t.classes.count)
        func credit(_ cls: Int, _ size: Int64, _ node: Int32) {
            bytes[cls] += size
            if (largest[cls]?.size ?? -1) < size { largest[cls] = (node, size) }
        }

        // The scan root itself may sit inside a claim or an area.
        var segments = canonicalSegments(root.path)
        if rootIsHome, !(segments.count == 2 && segments[0] == "users") {
            segments = ["users", root.lastPathComponent.lowercased()]
        }
        var startArea = t.otherIndex
        var rootClaim: Int?
        if !segments.isEmpty {
            for depth in 1...segments.count {
                guard let index = t.firstMatch(segments[0..<depth]) else { continue }
                if t.rules[index].claim { rootClaim = t.rules[index].classIndex; break }
                startArea = t.rules[index].classIndex
            }
        }
        if let rootClaim {
            credit(rootClaim, totals[0], 0)
        } else {
            // File rule per unique name: -2 unresolved, -1 none.
            var fileClass = [Int16](repeating: -2, count: tree.uniqueNameCount)
            func isProject(_ folder: Int32) -> Bool {
                var child = tree.firstChild[Int(folder)]
                while child != -1 {
                    if t.projectMarkers.contains(tree.name(of: child).lowercased())
                        || tree.name(of: child).lowercased().hasSuffix(".xcodeproj") { return true }
                    child = tree.nextSibling[Int(child)]
                }
                return false
            }
            func walk(_ node: Int32, area: Int) {
                var child = tree.firstChild[Int(node)]
                while child != -1 {
                    let c = Int(child)
                    let size = totals[c]
                    if size > 0 {
                        if tree.isDirectory[c] {
                            segments.append(tree.name(of: child).lowercased())
                            if let index = t.firstMatch(segments[...]) {
                                let rule = t.rules[index]
                                if rule.claim { credit(rule.classIndex, size, child) } else { walk(child, area: rule.classIndex) }
                            } else if let projects = t.projectsIndex, t.markerAreas.contains(area), isProject(child) {
                                // ~/Rust/Relay with a Cargo.toml is code, wherever it lives.
                                walk(child, area: projects)
                            } else {
                                walk(child, area: area)
                            }
                            segments.removeLast()
                        } else {
                            let nameID = Int(tree.nameIndex[c])
                            var cls = area
                            if nameID >= 0, nameID < fileClass.count {
                                if fileClass[nameID] == -2 {
                                    fileClass[nameID] = t.fileRule(named: tree.name(of: child).lowercased()).map { Int16($0.classIndex) } ?? -1
                                }
                                if fileClass[nameID] >= 0 { cls = Int(fileClass[nameID]) }
                            }
                            credit(cls, size, child)
                        }
                    }
                    child = tree.nextSibling[c]
                }
            }
            // A file scanned as the root has no children: it is its own total.
            if tree.isDirectory[0] { walk(0, area: startArea) } else { credit(startArea, totals[0], 0) }
        }

        return t.classes.indices.compactMap { i -> ClassTotal? in
            guard bytes[i] > 0 else { return nil }
            return ClassTotal(storageClass: t.classes[i], bytes: bytes[i], largestNode: largest[i]?.node)
        }
        .sorted {
            if ($0.storageClass.id == "other") != ($1.storageClass.id == "other") { return $1.storageClass.id == "other" }
            return $0.bytes > $1.bytes
        }
    }

    // MARK: System-held folders

    /// Folder names the system keeps for itself: the Trash, Spotlight's
    /// index, the FSEvents log, document versions. Nothing inside them is a
    /// finding — `node_modules` already in the Trash is not developer storage
    /// (the Windows build counted 28 GB of them in `$Recycle.Bin`).
    static let systemHoldingNames: Set<String> = [
        ".trash", ".trashes", ".spotlight-v100", ".fseventsd", ".documentrevisions-v100",
    ]

    /// True when `path` is inside (or is) one of those folders, or the swap
    /// and sleep image folder.
    public static func isSystemHolding(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.hasPrefix("/private/var/vm") || lower.hasPrefix("/system/volumes/vm") { return true }
        return lower.split(separator: "/").contains { systemHoldingNames.contains(String($0)) }
    }

    /// Per node: inside a system-holding folder. One pass over the tree with
    /// no path building, for catalogs that walk every node.
    public static func systemHoldingFlags(tree: FileTree, root: URL) -> [Bool] {
        tree.folderChainFlags(rootMatches: isSystemHolding(root.path)) {
            systemHoldingNames.contains($0.lowercased())
        }
    }
}
