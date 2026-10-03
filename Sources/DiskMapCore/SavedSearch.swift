import Foundation

/// A Find query kept in the sidebar (TASK-081). Stored as JSON in the app's
/// preferences; nothing here touches the disk beyond that.
public struct SavedSearch: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var query: String
    public var sort: String

    public init(id: UUID = UUID(), name: String, query: String, sort: FileQuery.Sort = .largest) {
        self.id = id
        self.name = name
        self.query = query
        self.sort = sort.rawValue
    }

    public var fileSort: FileQuery.Sort { FileQuery.Sort(rawValue: sort) ?? .largest }
}

public enum SavedSearches {
    /// Each one costs a pass over the tree after every scan.
    public static let limit = 20

    public struct Total: Sendable, Equatable {
        public var count: Int
        public var bytes: Int64
    }

    /// Offered in Find's empty state, never added on their own.
    public static let starters: [(name: String, query: String)] = [
        ("Old installers", "ext:dmg,pkg,zip age>30d in:downloads"),
        ("Big videos", "kind:video size>1GB"),
        ("Logs", "name:*.log size>50MB"),
    ]

    public static func decode(_ json: String?) -> [SavedSearch] {
        guard let data = json?.data(using: .utf8), let list = try? JSONDecoder().decode([SavedSearch].self, from: data) else { return [] }
        return Array(list.prefix(limit))
    }

    public static func encode(_ list: [SavedSearch]) -> String {
        guard let data = try? JSONEncoder().encode(Array(list.prefix(limit))) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The query's plain-language meaning, short enough for a sidebar row
    /// ("Videos · larger than 1 GB").
    public static func defaultName(for text: String, home: String, root: String) -> String {
        let parsed = FileQuery.parse(text, home: home, root: root)
        let parts = parsed.query.describe(home: home)
        // "Files" alone says nothing; drop it when something follows.
        let useful = parts.count > 1 && (parts.first == "Files" || parts.first == "Files and folders") ? Array(parts.dropFirst()) : parts
        var name = useful.joined(separator: " · ")
        if name.isEmpty { name = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let first = name.first { name = first.uppercased() + name.dropFirst() }
        return name.count > 40 ? String(name.prefix(39)) + "…" : name
    }

    /// Match count and bytes for every saved search over one scan.
    public static func totals(_ list: [SavedSearch], tree: FileTree, root: URL, totals: [Int64],
                              context: FileQuery.Context, isCancelled: () -> Bool = { false }) -> [UUID: Total] {
        var result: [UUID: Total] = [:]
        for search in list.prefix(limit) {
            if isCancelled() { break }
            let parsed = FileQuery.parse(search.query, home: context.home, root: root.path)
            let run = parsed.query.run(tree: tree, root: root, totals: totals, context: context, limit: 0, isCancelled: isCancelled)
            guard !run.wasCancelled else { break }
            result[search.id] = Total(count: run.matchCount, bytes: run.matchedBytes)
        }
        return result
    }
}
