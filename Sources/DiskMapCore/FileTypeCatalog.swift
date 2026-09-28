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
        guard tree.count == sizes.count, categories.count < Int(Int16.max) else { return [] }
        // Names are interned (~900k distinct across ~2.2M files on a home
        // scan), so resolve each distinct name's category once, and map
        // extensions through a dictionary instead of scanning the category
        // list per file. First category to claim an extension wins, exactly
        // as `categories.first(where:)` did. 0.6 s of first-paint time before.
        var extensionToCategory: [String: Int16] = [:]
        for (index, category) in categories.enumerated() {
            for ext in category.extensions where extensionToCategory[ext] == nil {
                extensionToCategory[ext] = Int16(index)
            }
        }
        let unresolved: Int16 = -2, uncategorised: Int16 = -1
        var categoryForName = [Int16](repeating: unresolved, count: tree.uniqueNameCount)
        var bytesByIndex = [Int64](repeating: 0, count: categories.count)
        for id in 0..<tree.count where !tree.isDirectory[id] {
            let nameID = Int(tree.nameIndex[id])
            guard nameID >= 0, nameID < categoryForName.count else { continue }
            var category = categoryForName[nameID]
            if category == unresolved {
                let ext = (tree.name(of: Int32(id)) as NSString).pathExtension.lowercased()
                category = ext.isEmpty ? uncategorised : (extensionToCategory[ext] ?? uncategorised)
                categoryForName[nameID] = category
            }
            if category >= 0 { bytesByIndex[Int(category)] += sizes[id] }
        }
        var byID: [String: Int64] = [:]
        for (index, category) in categories.enumerated() where bytesByIndex[index] != 0 {
            byID[category.id, default: 0] += bytesByIndex[index]
        }
        return categories.compactMap { cat in
            let bytes = byID[cat.id] ?? 0
            guard bytes > 0 else { return nil }
            return FileTypeTotals(categoryID: cat.id, label: cat.label, colorHex: cat.colorHex, bytes: bytes)
        }
        .sorted { $0.bytes > $1.bytes }
    }


    /// Same as `totals(in:sizes:categories:)` but only files under `nodeID` (inclusive of files that are the node itself).
    public static func totals(
        under nodeID: Int32,
        in tree: FileTree,
        sizes: [Int64],
        categories: [FileTypeCategory]
    ) -> [FileTypeTotals] {
        guard tree.count == sizes.count,
              nodeID >= 0,
              Int(nodeID) < tree.count else { return [] }
        var byID: [String: Int64] = [:]
        var stack: [Int32] = [nodeID]
        while let id = stack.popLast() {
            let index = Int(id)
            if !tree.isDirectory[index] {
                let name = tree.name(of: id)
                let ext = (name as NSString).pathExtension.lowercased()
                if !ext.isEmpty, let cat = categories.first(where: { $0.extensions.contains(ext) }) {
                    byID[cat.id, default: 0] += sizes[index]
                }
            } else {
                var child = tree.firstChild[index]
                while child != -1 {
                    stack.append(child)
                    child = tree.nextSibling[Int(child)]
                }
            }
        }
        return categories.compactMap { cat in
            let bytes = byID[cat.id] ?? 0
            guard bytes > 0 else { return nil }
            return FileTypeTotals(categoryID: cat.id, label: cat.label, colorHex: cat.colorHex, bytes: bytes)
        }
        .sorted { $0.bytes > $1.bytes }
    }

    /// Largest files under a folder node, capped.
    public static func largestFiles(
        under nodeID: Int32,
        in tree: FileTree,
        sizes: [Int64],
        limit: Int = 5
    ) -> [(id: Int32, name: String, bytes: Int64)] {
        guard tree.count == sizes.count, nodeID >= 0, Int(nodeID) < tree.count, limit > 0 else { return [] }
        var files: [(Int32, Int64)] = []
        var stack: [Int32] = [nodeID]
        while let id = stack.popLast() {
            let index = Int(id)
            if !tree.isDirectory[index] {
                let bytes = sizes[index]
                if bytes > 0 { files.append((id, bytes)) }
            } else {
                var child = tree.firstChild[index]
                while child != -1 {
                    stack.append(child)
                    child = tree.nextSibling[Int(child)]
                }
            }
        }
        files.sort { $0.1 > $1.1 }
        if files.count > limit { files = Array(files.prefix(limit)) }
        return files.map { (id: $0.0, name: tree.name(of: $0.0), bytes: $0.1) }
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
