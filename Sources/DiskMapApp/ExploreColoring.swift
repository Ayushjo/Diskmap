import DiskMapCore
import SwiftUI

/// By folder / type / age colors shared by Treemap and layout canvases.
enum ExploreColoring {
    static func color(
        for id: Int32,
        in tree: FileTree,
        mode: ExploreColorMode,
        categories: [FileTypeCategory],
        folderTypeHex: [Int32: String] = [:]
    ) -> Color {
        switch mode {
        case .folder: return folderColor(id: id, tree: tree)
        case .type: return typeColor(id: id, tree: tree, categories: categories, folderTypeHex: folderTypeHex)
        case .age: return ageColor(id: id, tree: tree)
        }
    }

    private static func folderColor(id: Int32, tree: FileTree) -> Color {
        var cursor = id
        var top = id
        while tree.parent[Int(cursor)] > 0 {
            cursor = tree.parent[Int(cursor)]
            top = cursor
        }
        if tree.parent[Int(cursor)] == 0 { top = cursor }
        // Stable constant-time palette lookup; never enumerate root siblings per tile.
        let base = DiskMapTheme.treemapFolderColor(name: tree.name(of: top), index: Int(top))
        let depth = max(0, ancestorDepth(id, tree: tree) - ancestorDepth(top, tree: tree))
        return depth == 0 ? base : DiskMapTheme.wash(base, strength: 1.0 - min(0.35, Double(depth) * 0.08))
    }

    private static func ancestorDepth(_ id: Int32, tree: FileTree) -> Int {
        var d = 0
        var c = id
        while c >= 0 {
            d += 1
            c = tree.parent[Int(c)]
            if d > 64 { break }
        }
        return d
    }

    private static func typeColor(id: Int32, tree: FileTree, categories: [FileTypeCategory],
                                  folderTypeHex: [Int32: String]) -> Color {
        if tree.isDirectory[Int(id)] {
            // A folder takes the colour of the type that fills most of it;
            // stone until that is known (it used to cycle colours by index).
            if let hex = folderTypeHex[id] { return DiskMapTheme.hex(hex) }
            return DiskMapTheme.wash(DiskMapTheme.data(6), strength: 0.85)
        }
        let ext = (tree.name(of: id) as NSString).pathExtension.lowercased()
        if let cat = categories.first(where: { $0.extensions.contains(ext) }) {
            return DiskMapTheme.hex(cat.colorHex)
        }
        return DiskMapTheme.ink2.opacity(0.5)
    }

    private static func ageColor(id: Int32, tree: FileTree) -> Color {
        let today = AgeMap.today()
        return DiskMapTheme.ageColor(AgeMap.bucket(modifiedDay: tree.modifiedDay[Int(id)], today: today))
    }

    /// For "By type": each folder's dominant category colour, by bytes.
    /// Walks every folder's subtree, so call it off the main thread, for the
    /// folders on screen only.
    nonisolated static func dominantTypeHex(
        for ids: [Int32],
        in tree: FileTree,
        totals: [Int64],
        categories: [FileTypeCategory]
    ) -> [Int32: String] {
        var out: [Int32: String] = [:]
        for id in ids where id >= 0 && Int(id) < tree.count && tree.isDirectory[Int(id)] {
            if Task.isCancelled { break }
            let parts = FileTypeCatalog.totals(under: id, in: tree, sizes: totals, categories: categories)
            if let top = parts.max(by: { $0.bytes < $1.bytes }), top.bytes > 0 { out[id] = top.colorHex }
        }
        return out
    }
}
