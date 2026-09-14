import Foundation

public struct FileTypeCategory: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var colorHex: String
    public var extensions: Set<String>
}

public struct FileTypeTotals: Sendable, Equatable {
    public var categoryID: String
    public var label: String
    public var colorHex: String
    public var bytes: Int64
}

public enum FileTypeCatalog {
    public static func loadBundled() -> [FileTypeCategory] {
        guard let url = Bundle.module.url(forResource: "file-type-categories", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(File.self, from: data) else {
            return []
        }
        return decoded.categories.map {
            FileTypeCategory(
                id: $0.id,
                label: $0.label,
                colorHex: $0.color,
                extensions: Set($0.extensions.map { $0.lowercased() })
            )
        }
    }

    /// Sum allocated (or provided) sizes for regular files, grouped by extension category.
    public static func totals(
        in tree: FileTree,
        sizes: [Int64],
        categories: [FileTypeCategory]
    ) -> [FileTypeTotals] {
        guard tree.count == sizes.count else { return [] }
        var byID: [String: Int64] = [:]
        for id in 0..<tree.count where !tree.isDirectory[id] {
            let name = tree.name(of: Int32(id))
            let ext = (name as NSString).pathExtension.lowercased()
            guard !ext.isEmpty, let cat = categories.first(where: { $0.extensions.contains(ext) }) else { continue }
            byID[cat.id, default: 0] += sizes[id]
        }
        return categories.compactMap { cat in
            let bytes = byID[cat.id] ?? 0
            guard bytes > 0 else { return nil }
            return FileTypeTotals(categoryID: cat.id, label: cat.label, colorHex: cat.colorHex, bytes: bytes)
        }
        .sorted { $0.bytes > $1.bytes }
    }

    private struct File: Decodable {
        var categories: [Cat]
    }
    private struct Cat: Decodable {
        var id: String
        var label: String
        var color: String
        var extensions: [String]
    }
}
