import Foundation

/// A small search language over one scan (TASK-059), shared by ⌘K, the Find
/// screen and `diskmap find`:
///
///     ext:mp4 size>500MB age>1y in:downloads
///     name:*.log size>100MB -archive
///
/// Every field is already in `FileTree`; nothing touches the disk. Name tests
/// run once per *distinct* name and places are one forward pass over the
/// parent links, so no path is built for any node that is not displayed.
public struct FileQuery: Sendable, Equatable {
    public enum Comparison: String, Sendable, Equatable {
        case greater = ">", greaterOrEqual = ">=", less = "<", lessOrEqual = "<="

        func holds(_ value: Int64, _ bound: Int64) -> Bool {
            switch self {
            case .greater: return value > bound
            case .greaterOrEqual: return value >= bound
            case .less: return value < bound
            case .lessOrEqual: return value <= bound
            }
        }
    }

    public enum NodeType: String, Sendable, Equatable { case files, folders, any }

    public enum Place: String, Sendable, Equatable, CaseIterable {
        case downloads, desktop, documents, library, caches
    }

    public enum Flag: String, Sendable, Equatable, CaseIterable {
        case duplicate, hardlink, cloud
    }

    public struct Bound: Sendable, Equatable {
        public var comparison: Comparison
        public var value: Int64
    }

    /// Case-insensitive substrings every name must contain.
    public var words: [String] = []
    /// Case-insensitive substrings no name may contain (`-word`).
    public var excludedWords: [String] = []
    /// `name:` patterns. With `*`, `?` or `[` they match the whole name;
    /// without, they are substrings like a bare word.
    public var namePatterns: [String] = []
    /// Lowercased, without the dot. Any of them may match (`ext:mp4,mov`).
    public var extensions: [String] = []
    /// File-type category ids from `file-type-categories.json`, plus `media`.
    public var kinds: [String] = []
    public var sizeBounds: [Bound] = []
    /// Days since last modification.
    public var ageBounds: [Bound] = []
    /// Absolute folder paths (`path:`); any of them may contain the match.
    public var paths: [String] = []
    public var places: [Place] = []
    public var flags: [Flag] = []
    public var explicitType: NodeType?

    public init() {}

    /// Size, age, extension, kind and file flags describe files. Folder
    /// totals nest, so `size>1GB` over folders would list every ancestor of
    /// one big file; asking for folders takes an explicit `type:folder`.
    public var effectiveType: NodeType {
        if let explicitType { return explicitType }
        let describesFiles = !sizeBounds.isEmpty || !ageBounds.isEmpty || !extensions.isEmpty || !kinds.isEmpty || !flags.isEmpty
        return describesFiles ? .files : .any
    }

    public var isEmpty: Bool { self == FileQuery() }

    /// True when the text used any `key:` or comparison — the palette uses
    /// this to switch from "commands and names" to "query results".
    public var isStructured: Bool {
        var plain = FileQuery()
        plain.words = words
        return self != plain
    }

    // MARK: Parsing

    public struct Problem: Sendable, Equatable {
        public var token: String
        public var message: String
    }

    public struct Parsed: Sendable, Equatable {
        public var query: FileQuery
        /// Tokens that were understood as a key but had a bad value. They are
        /// left out of the query, so a half-typed `size>` never empties the
        /// results.
        public var problems: [Problem]
    }

    public static let keys = ["ext", "name", "path", "in", "is", "type", "kind", "size", "age"]

    /// `home` expands `~`; `root` anchors relative `path:` values.
    public static func parse(_ text: String, home: String, root: String) -> Parsed {
        var query = FileQuery()
        var problems: [Problem] = []
        for token in tokenize(text) {
            if let problem = apply(token, to: &query, home: home, root: root) {
                problems.append(Problem(token: token, message: problem))
            }
        }
        return Parsed(query: query, problems: problems)
    }

    /// Returns a problem message, or nil when the token was applied.
    private static func apply(_ raw: String, to query: inout FileQuery, home: String, root: String) -> String? {
        let token = unquoted(raw)
        let lower = token.lowercased()

        for key in ["size", "age"] where lower.hasPrefix(key) {
            var rest = Substring(lower.dropFirst(key.count))
            if rest.first == ":" { rest = rest.dropFirst() }
            guard let first = rest.first, first == ">" || first == "<" else {
                if lower.hasPrefix(key + ":") {
                    return key == "size" ? "Use size>500MB or size<10KB" : "Use age>1y (older than) or age<7d (newer than)"
                }
                continue   // "sizeable", "ageing": ordinary words
            }
            let comparison: Comparison = rest.hasPrefix(">=") ? .greaterOrEqual : rest.hasPrefix("<=") ? .lessOrEqual
                : first == ">" ? .greater : .less
            let valueText = String(rest.dropFirst(comparison.rawValue.count))
            if key == "size" {
                guard let bytes = HumanUnits.bytes(valueText) else { return "Size needs a value like 500MB, 2GB or 1.5TB" }
                query.sizeBounds.append(Bound(comparison: comparison, value: bytes))
            } else {
                guard let days = HumanUnits.days(valueText) else { return "Age needs a value like 30d, 2w, 6m or 1y" }
                query.ageBounds.append(Bound(comparison: comparison, value: Int64(days)))
            }
            return nil
        }

        if let colon = token.firstIndex(of: ":") {
            let key = token[..<colon].lowercased()
            let value = unquoted(String(token[token.index(after: colon)...]))
            if keys.contains(key) {
                guard !value.isEmpty else { return "\(key): needs a value" }
                return applyKey(key, value, to: &query, home: home, root: root)
            }
        }

        if lower.hasPrefix("-"), lower.count > 1 {
            query.excludedWords.append(String(lower.dropFirst()))
        } else if !lower.isEmpty {
            query.words.append(lower)
        }
        return nil
    }

    private static func applyKey(_ key: String, _ value: String, to query: inout FileQuery, home: String, root: String) -> String? {
        let lower = value.lowercased()
        switch key {
        case "ext":
            let list = lower.split(separator: ",").map { $0.hasPrefix(".") ? String($0.dropFirst()) : String($0) }.filter { !$0.isEmpty }
            guard !list.isEmpty else { return "ext: needs an extension, like ext:mp4" }
            query.extensions += list
        case "name":
            query.namePatterns.append(lower)
        case "kind":
            let known = Set(FileQuery.kindExtensions.keys)
            let list = lower.split(separator: ",").map(String.init)
            if let bad = list.first(where: { !known.contains($0) }) {
                return "Unknown kind \"\(bad)\" — try \(known.sorted().joined(separator: ", "))"
            }
            query.kinds += list
        case "type":
            switch lower {
            case "file", "files", "f": query.explicitType = .files
            case "dir", "dirs", "folder", "folders", "d": query.explicitType = .folders
            case "any", "all": query.explicitType = .any
            default: return "type: is file, folder or any"
            }
        case "in":
            guard let place = Place(rawValue: lower) else {
                return "in: is one of \(Place.allCases.map(\.rawValue).joined(separator: ", "))"
            }
            query.places.append(place)
        case "is":
            guard let flag = Flag(rawValue: lower) else {
                return "is: is one of \(Flag.allCases.map(\.rawValue).joined(separator: ", "))"
            }
            query.flags.append(flag)
        case "path":
            query.paths.append(absolutePath(value, home: home, root: root))
        default:
            return "Unknown key \(key):"
        }
        return nil
    }

    static func absolutePath(_ value: String, home: String, root: String) -> String {
        var path = value
        if path == "~" { path = home }
        else if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
        else if !path.hasPrefix("/") { path = (root == "/" ? "" : root) + "/" + path }
        path = (path as NSString).standardizingPath
        return path
    }

    /// Whitespace-separated, with double quotes grouping (`path:"~/My Stuff"`).
    public static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for character in text {
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
            } else if character.isWhitespace && !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func unquoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "")
    }

    /// Adds `token` to `text`, or removes it when present — the Find screen's
    /// chips are exactly this, so a chip and a typed token are one thing.
    public static func toggling(_ token: String, in text: String) -> String {
        let tokens = tokenize(text)
        if tokens.contains(where: { $0.caseInsensitiveCompare(token) == .orderedSame }) {
            return tokens.filter { $0.caseInsensitiveCompare(token) != .orderedSame }.joined(separator: " ")
        }
        return (tokens + [token]).joined(separator: " ")
    }

    public static func contains(_ token: String, in text: String) -> Bool {
        tokenize(text).contains { $0.caseInsensitiveCompare(token) == .orderedSame }
    }

    // MARK: Description

    /// Plain-language pieces of what the query means, for display beside it
    /// ("Files · larger than 500 MB · in ~/Downloads").
    public func describe(home: String) -> [String] {
        var parts: [String] = []
        switch effectiveType {
        case .files: parts.append("Files")
        case .folders: parts.append("Folders")
        case .any: parts.append("Files and folders")
        }
        for bound in sizeBounds {
            let size = HumanUnits.format(bound.value)
            switch bound.comparison {
            case .greater: parts.append("larger than \(size)")
            case .greaterOrEqual: parts.append("at least \(size)")
            case .less: parts.append("smaller than \(size)")
            case .lessOrEqual: parts.append("at most \(size)")
            }
        }
        for bound in ageBounds {
            let age = Self.describeDays(bound.value)
            switch bound.comparison {
            case .greater, .greaterOrEqual: parts.append("untouched for \(age)+")
            case .less, .lessOrEqual: parts.append("changed in the last \(age)")
            }
        }
        if !extensions.isEmpty { parts.append(extensions.map { "." + $0 }.joined(separator: " or ")) }
        if !kinds.isEmpty { parts.append(kinds.map { Self.kindLabel($0) }.joined(separator: " or ")) }
        for pattern in namePatterns { parts.append("named \(pattern)") }
        for word in words { parts.append("name contains “\(word)”") }
        for word in excludedWords { parts.append("not “\(word)”") }
        let placeNames = places.map { $0 == .caches ? "caches" : "~/" + $0.rawValue.capitalized }
            + paths.map { CanonicalPath.displayPath(absolutePath: $0, home: home) }
        if !placeNames.isEmpty { parts.append("in " + placeNames.joined(separator: " or ")) }
        for flag in flags {
            switch flag {
            case .duplicate: parts.append("duplicated")
            case .hardlink: parts.append("hard-linked")
            case .cloud: parts.append("in iCloud only")
            }
        }
        return parts
    }

    static func describeDays(_ days: Int64) -> String {
        func unit(_ n: Int64, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if days >= 365, days % 365 == 0 { return unit(days / 365, "year") }
        if days >= 30, days % 30 == 0 { return unit(days / 30, "month") }
        if days >= 7, days % 7 == 0 { return unit(days / 7, "week") }
        return unit(days, "day")
    }

    // MARK: Kinds

    /// Category id → extensions, from the same JSON as the Types chart.
    static let kindExtensions: [String: Set<String>] = {
        var map: [String: Set<String>] = [:]
        for category in FileTypeCatalog.loadBundled() { map[category.id] = category.extensions }
        map["media"] = (map["video"] ?? []).union(map["audio"] ?? []).union(map["image"] ?? [])
        return map
    }()

    static func kindLabel(_ id: String) -> String {
        id == "media" ? "Media" : FileTypeCatalog.loadBundled().first { $0.id == id }?.label ?? id
    }
}

// MARK: - Running a query

extension FileQuery {
    public enum Sort: String, Sendable, CaseIterable {
        case largest, oldest, newest
    }

    public struct Context: Sendable {
        public var home: String
        /// Files the duplicate finder has grouped; nil until it has run.
        public var duplicateFileIDs: Set<Int32>?
        public var today: Int32
        public init(home: String, duplicateFileIDs: Set<Int32>? = nil, today: Int32 = AgeMap.today()) {
            self.home = home
            self.duplicateFileIDs = duplicateFileIDs
            self.today = today
        }
    }

    public struct Result: Sendable, Equatable {
        /// The first `limit` matches in `sort` order.
        public var ids: [Int32]
        public var matchCount: Int
        /// Bytes in all matches. A folder inside another matched folder is
        /// not counted twice.
        public var matchedBytes: Int64
        /// Things the query asked for that this scan cannot answer
        /// (a path outside it, duplicates not searched yet).
        public var notes: [String]
        public var wasCancelled: Bool

        public static let empty = Result(ids: [], matchCount: 0, matchedBytes: 0, notes: [], wasCancelled: false)
    }

    public func run(
        tree: FileTree,
        root: URL,
        totals: [Int64],
        context: Context,
        sort: Sort = .largest,
        limit: Int = 500,
        isCancelled: () -> Bool = { false }
    ) -> Result {
        guard tree.count > 1, totals.count == tree.count else { return .empty }
        var notes: [String] = []

        // Places: one forward pass (parent[i] < i), no paths built.
        var placeRoots = Set<Int32>()
        var wantsCaches = false
        let rootPath = (root.path as NSString).standardizingPath
        var placePaths = paths
        for place in places {
            if place == .caches { wantsCaches = true } else { placePaths.append(context.home + "/" + place.rawValue.capitalized) }
        }
        for path in placePaths {
            switch Self.node(atPath: path, tree: tree, rootPath: rootPath) {
            case .found(let id): placeRoots.insert(id)
            case .outside: notes.append("\(CanonicalPath.displayPath(absolutePath: path, home: context.home)) is outside this scan")
            case .missing: notes.append("\(CanonicalPath.displayPath(absolutePath: path, home: context.home)) isn't in this scan")
            }
        }
        let hasPlaces = !placePaths.isEmpty || wantsCaches
        var inPlace: [Bool] = []
        if hasPlaces {
            var cacheName = [UInt8](repeating: 0, count: tree.uniqueNameCount)   // 0 unknown, 1 yes, 2 no
            inPlace = [Bool](repeating: false, count: tree.count)
            inPlace[0] = placeRoots.contains(0)
            for index in 1..<tree.count {
                let parentID = Int(tree.parent[index])
                var hit = (parentID >= 0 && parentID < index && inPlace[parentID]) || placeRoots.contains(Int32(index))
                if !hit, wantsCaches, tree.isDirectory[index] {
                    let nameID = Int(tree.nameIndex[index])
                    if cacheName[nameID] == 0 {
                        let name = tree.nameString(at: Int32(nameID)).lowercased()
                        cacheName[nameID] = (name == "caches" || name == ".cache" || name == "deriveddata") ? 1 : 2
                    }
                    hit = cacheName[nameID] == 1
                }
                inPlace[index] = hit
            }
        }

        if flags.contains(.duplicate), context.duplicateFileIDs == nil {
            notes.append("Duplicates haven't been searched in this scan yet")
        }

        // Name predicates, evaluated once per distinct name.
        let kindSet = kinds.reduce(into: Set<String>()) { $0.formUnion(Self.kindExtensions[$1] ?? []) }
        let usesName = !words.isEmpty || !excludedWords.isEmpty || !namePatterns.isEmpty || !extensions.isEmpty || !kindSet.isEmpty
        var nameVerdict = usesName ? [UInt8](repeating: 0, count: tree.uniqueNameCount) : []
        let matcher = usesName ? ASCIINameMatcher(query: self, kindSet: kindSet) : nil
        // Names are at most UInt16.max bytes (FileTree.nameLength).
        let scratch = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: matcher == nil ? 0 : Int(UInt16.max) + 1)
        defer { scratch.deallocate() }

        let type = effectiveType
        let foldersCanMatch = type != .files
        var covered: [Bool] = foldersCanMatch ? [Bool](repeating: false, count: tree.count) : []
        var top = TopK(limit: limit, before: Self.ordering(sort, tree: tree, totals: totals))
        var matchCount = 0
        var matchedBytes: Int64 = 0

        for index in 1..<tree.count {
            if index & 0xFFFF == 0, isCancelled() {
                return Result(ids: top.sorted(), matchCount: matchCount, matchedBytes: matchedBytes, notes: notes, wasCancelled: true)
            }
            let parentID = Int(tree.parent[index])
            let ancestorMatched = foldersCanMatch && parentID >= 0 && parentID < index && covered[parentID]
            guard matches(index, type: type, tree: tree, totals: totals, context: context,
                          inPlace: inPlace, hasPlaces: hasPlaces, kindSet: kindSet, usesName: usesName,
                          matcher: matcher, scratch: scratch, nameVerdict: &nameVerdict) else {
                if foldersCanMatch { covered[index] = ancestorMatched }
                continue
            }
            if foldersCanMatch { covered[index] = true }
            matchCount += 1
            if !ancestorMatched { matchedBytes += totals[index] }
            top.insert(Int32(index))
        }
        return Result(ids: top.sorted(), matchCount: matchCount, matchedBytes: matchedBytes, notes: notes, wasCancelled: false)
    }

    private func matches(
        _ index: Int, type: NodeType, tree: FileTree, totals: [Int64], context: Context,
        inPlace: [Bool], hasPlaces: Bool, kindSet: Set<String>, usesName: Bool, matcher: ASCIINameMatcher?,
        scratch: UnsafeMutableBufferPointer<UInt8>, nameVerdict: inout [UInt8]
    ) -> Bool {
        let isDirectory = tree.isDirectory[index]
        switch type {
        case .files: if isDirectory { return false }
        case .folders: if !isDirectory { return false }
        case .any: break
        }
        if hasPlaces, !inPlace[index] { return false }
        for bound in sizeBounds where !bound.comparison.holds(totals[index], bound.value) { return false }
        if !ageBounds.isEmpty {
            let day = tree.modifiedDay[index]
            guard day > 0 else { return false }
            let age = Int64(context.today - day)
            for bound in ageBounds where !bound.comparison.holds(age, bound.value) { return false }
        }
        for flag in flags {
            switch flag {
            case .duplicate:
                guard let ids = context.duplicateFileIDs, ids.contains(Int32(index)) else { return false }
            case .hardlink:
                guard tree.flags[index] & NodeFlags.hardLink != 0 else { return false }
            case .cloud:
                guard tree.flags[index] & NodeFlags.notDownloaded != 0 else { return false }
            }
        }
        if usesName {
            let nameID = Int(tree.nameIndex[index])
            if nameVerdict[nameID] == 0 {
                let fast = matcher.flatMap { m in tree.withNameUTF8(at: Int32(nameID)) { m.matches($0, scratch: scratch) } }
                let verdict = fast ?? nameMatches(tree.nameString(at: Int32(nameID)), kindSet: kindSet)
                nameVerdict[nameID] = verdict ? 1 : 2
            }
            if nameVerdict[nameID] != 1 { return false }
            // Kind and extension describe file contents; a folder called
            // "x.mp4" is not a video.
            if isDirectory, !kindSet.isEmpty || !extensions.isEmpty { return false }
        }
        return true
    }

    func nameMatches(_ name: String, kindSet: Set<String>) -> Bool {
        let lower = name.lowercased()
        for word in words where !lower.contains(word) { return false }
        for word in excludedWords where lower.contains(word) { return false }
        for pattern in namePatterns {
            if pattern.contains(where: { $0 == "*" || $0 == "?" || $0 == "[" }) {
                guard fnmatch(pattern, lower, 0) == 0 else { return false }
            } else if !lower.contains(pattern) {
                return false
            }
        }
        if !extensions.isEmpty, !extensions.contains(where: { lower.hasSuffix("." + $0) && lower.count > $0.count + 1 }) {
            return false
        }
        if !kindSet.isEmpty {
            guard let dot = lower.lastIndex(of: "."), dot != lower.startIndex,
                  kindSet.contains(String(lower[lower.index(after: dot)...])) else { return false }
        }
        return true
    }

    public enum NodeLookup: Equatable, Sendable { case found(Int32), outside, missing }

    /// Finds a folder by walking child names from the root — a handful of
    /// sibling scans, never a path per node.
    public static func node(atPath path: String, tree: FileTree, rootPath: String) -> NodeLookup {
        if path == rootPath { return .found(0) }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard path.hasPrefix(prefix) else { return .outside }
        var current: Int32 = 0
        for component in path.dropFirst(prefix.count).split(separator: "/") {
            var child = tree.firstChild[Int(current)]
            var next: Int32 = -1
            while child != -1 {
                if tree.name(of: child) == component { next = child; break }
                child = tree.nextSibling[Int(child)]
            }
            guard next != -1 else { return .missing }
            current = next
        }
        return .found(current)
    }

    /// `before(a, b)`: a ranks ahead of b.
    static func ordering(_ sort: Sort, tree: FileTree, totals: [Int64]) -> (Int32, Int32) -> Bool {
        switch sort {
        case .largest:
            return { a, b in totals[Int(a)] != totals[Int(b)] ? totals[Int(a)] > totals[Int(b)] : a < b }
        case .oldest, .newest:
            let oldest = sort == .oldest
            return { a, b in
                let da = tree.modifiedDay[Int(a)], db = tree.modifiedDay[Int(b)]
                if da != db {
                    if da == 0 { return false }   // unknown dates last either way
                    if db == 0 { return true }
                    return oldest ? da < db : da > db
                }
                return totals[Int(a)] != totals[Int(b)] ? totals[Int(a)] > totals[Int(b)] : a < b
            }
        }
    }
}

/// Keeps the best `limit` ids seen, as a heap with the weakest on top.
struct TopK {
    let limit: Int
    let before: (Int32, Int32) -> Bool
    private(set) var heap: [Int32] = []

    init(limit: Int, before: @escaping (Int32, Int32) -> Bool) {
        self.limit = limit
        self.before = before
        heap.reserveCapacity(min(limit, 4_096))
    }

    mutating func insert(_ id: Int32) {
        guard limit > 0 else { return }
        if heap.count < limit {
            heap.append(id)
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard before(heap[parent], heap[child]) else { break }   // weaker rises
                heap.swapAt(child, parent)
                child = parent
            }
        } else if let weakest = heap.first, before(id, weakest) {
            heap[0] = id
            var parent = 0
            while true {
                let left = parent * 2 + 1
                guard left < heap.count else { break }
                var weaker = left
                if left + 1 < heap.count, before(heap[left], heap[left + 1]) { weaker = left + 1 }
                guard before(heap[parent], heap[weaker]) else { break }
                heap.swapAt(parent, weaker)
                parent = weaker
            }
        }
    }

    func sorted() -> [Int32] { heap.sorted(by: before) }
}

/// Name tests on raw UTF-8 for the common case: an ASCII name and ASCII
/// needles, where lowercasing is a byte operation and substring search
/// needs no Unicode rules. Returns nil for anything else, and the caller
/// falls back to String comparison — so results never differ, only speed
/// (a home scan has ~685k distinct names; String tests cost ~1.5 s).
struct ASCIINameMatcher {
    private let words: [[UInt8]]
    private let excluded: [[UInt8]]
    private let substrings: [[UInt8]]
    private let globs: [[CChar]]
    /// Per glob, its longest literal run: a name without it cannot match,
    /// and a byte search is far cheaper than fnmatch (the same prefilter as
    /// GitIgnoreRules).
    private let globLiterals: [[UInt8]]
    private let extensions: [[UInt8]]
    private let kindExtensions: Set<[UInt8]>
    private let usesKinds: Bool
    /// A required word is non-ASCII: no ASCII name can contain it (ASCII
    /// lowercases to ASCII), so every ASCII name is a definite "no".
    private let impossibleForASCII: Bool

    init?(query: FileQuery, kindSet: Set<String>) {
        let isGlob: (String) -> Bool = { $0.contains(where: { $0 == "*" || $0 == "?" || $0 == "[" }) }
        let isASCII: (String) -> Bool = { $0.utf8.allSatisfy { $0 < 0x80 } }
        let globs = query.namePatterns.filter(isGlob)
        // A non-ASCII glob could still match an ASCII name ("[!é]*"): decline.
        guard globs.allSatisfy(isASCII) else { return nil }
        let required = query.words + query.namePatterns.filter { !isGlob($0) }
        impossibleForASCII = !required.allSatisfy(isASCII)
            || !query.extensions.allSatisfy(isASCII)
            || (!kindSet.isEmpty && !kindSet.contains(where: isASCII))
        words = query.words.filter(isASCII).map { Array($0.utf8) }
        // A non-ASCII exclusion never occurs in an ASCII name: nothing to test.
        excluded = query.excludedWords.filter(isASCII).map { Array($0.utf8) }
        substrings = query.namePatterns.filter { !isGlob($0) && isASCII($0) }.map { Array($0.utf8) }
        self.globs = globs.map { Array($0.utf8).map { CChar(bitPattern: $0) } + [0] }
        globLiterals = globs.map { Self.longestLiteral(in: $0) }
        extensions = query.extensions.filter(isASCII).map { Array(("." + $0).utf8) }
        kindExtensions = Set(kindSet.filter(isASCII).map { Array($0.utf8) })
        usesKinds = !kindSet.isEmpty
    }

    /// `scratch` must hold at least `name.count + 1` bytes; it is reused
    /// across calls so the per-name test allocates nothing.
    func matches(_ name: UnsafeBufferPointer<UInt8>, scratch: UnsafeMutableBufferPointer<UInt8>) -> Bool? {
        let count = name.count
        guard count < scratch.count else { return nil }
        for i in 0..<count {
            let byte = name[i]
            guard byte < 0x80 else { return nil }
            scratch[i] = (byte >= 65 && byte <= 90) ? byte + 32 : byte
        }
        scratch[count] = 0
        if impossibleForASCII { return false }
        let text = UnsafeBufferPointer(rebasing: scratch[0..<count])
        for word in words where !Self.contains(text, word) { return false }
        for word in excluded where Self.contains(text, word) { return false }
        for part in substrings where !Self.contains(text, part) { return false }
        for literal in globLiterals where !Self.contains(text, literal) { return false }
        if !globs.isEmpty, let base = scratch.baseAddress {
            let matched = base.withMemoryRebound(to: CChar.self, capacity: count + 1) { cName in
                globs.allSatisfy { fnmatch($0, cName, 0) == 0 }
            }
            if !matched { return false }
        }
        if !extensions.isEmpty, !extensions.contains(where: { count > $0.count && Self.hasSuffix(text, $0) }) {
            return false
        }
        if usesKinds {
            guard let dot = text.lastIndex(of: UInt8(ascii: ".")), dot > 0,
                  kindExtensions.contains(Array(text[(dot + 1)...])) else { return false }
        }
        return true
    }

    /// Convenience for tests: allocates its own scratch.
    func matches(_ name: UnsafeBufferPointer<UInt8>) -> Bool? {
        let scratch = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: name.count + 1)
        defer { scratch.deallocate() }
        return matches(name, scratch: scratch)
    }

    /// Empty when the pattern has brackets or escapes (a literal run there
    /// would need bracket parsing to be safe), so the prefilter just passes.
    static func longestLiteral(in glob: String) -> [UInt8] {
        guard !glob.contains("["), !glob.contains("\\") else { return [] }
        return glob.split(whereSeparator: { $0 == "*" || $0 == "?" })
            .max { $0.utf8.count < $1.utf8.count }
            .map { Array($0.utf8) } ?? []
    }

    static func contains(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard haystack.count >= needle.count else { return false }
        let first = needle[0]
        var i = 0
        let last = haystack.count - needle.count
        while i <= last {
            if haystack[i] == first {
                var j = 1
                while j < needle.count && haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }

    static func hasSuffix(_ text: UnsafeBufferPointer<UInt8>, _ suffix: [UInt8]) -> Bool {
        guard text.count >= suffix.count else { return false }
        let start = text.count - suffix.count
        for j in 0..<suffix.count where text[start + j] != suffix[j] { return false }
        return true
    }
}
