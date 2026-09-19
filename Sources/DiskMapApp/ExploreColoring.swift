import DiskMapCore
import SwiftUI

/// By folder / type / age colors shared by Treemap and layout canvases.
enum ExploreColoring {
    static func color(
        for id: Int32,
        in tree: FileTree,
        mode: ExploreColorMode,
        categories: [FileTypeCategory]
    ) -> Color {
        switch mode {
        case .folder: return folderColor(id: id, tree: tree)
        case .type: return typeColor(id: id, tree: tree, categories: categories)
        case .age: return ageColor(id: id, tree: tree)
        }
    }

    private static func topLevelHues(tree: FileTree) -> [Int32: Int] {
        var map: [Int32: Int] = [:]
        var child = tree.firstChild[0]
        var i = 0
        while child != -1 {
            map[child] = i
            i += 1
            child = tree.nextSibling[Int(child)]
        }
        return map
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
        let idx = Int(top)
        let palette = ["849BB8", "A795C7", "C78797", "7BA89C", "B9A071", "8FACC0", "A2A4AC"]
        let name = tree.name(of: top).lowercased()
        let hex: String
        switch name {
        case "library": hex = "A795C7"
        case "downloads": hex = "C78797"
        case "desktop", "documents": hex = "849BB8"
        case "applications": hex = "C9A078"
        default: hex = palette[abs(idx) % palette.count]
        }
        let base = DiskMapTheme.hex(hex)
        let depth = max(0, ancestorDepth(id, tree: tree) - ancestorDepth(top, tree: tree))
        return depth == 0 ? base : base.opacity(1.0 - min(0.35, Double(depth) * 0.08))
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

    private static func typeColor(id: Int32, tree: FileTree, categories: [FileTypeCategory]) -> Color {
        if tree.isDirectory[Int(id)] {
            return DiskMapTheme.folderPastels[Int(id) % DiskMapTheme.folderPastels.count].opacity(0.85)
        }
        let ext = (tree.name(of: id) as NSString).pathExtension.lowercased()
        if let cat = categories.first(where: { $0.extensions.contains(ext) }) {
            return DiskMapTheme.hex(cat.colorHex)
        }
        return DiskMapTheme.mutedLabel.opacity(0.5)
    }

    private static func ageColor(id: Int32, tree: FileTree) -> Color {
        let today = AgeMap.today()
        let bucket = AgeMap.bucket(modifiedDay: tree.modifiedDay[Int(id)], today: today)
        switch bucket {
        case .under30: return Color(hue: 0.42, saturation: 0.35, brightness: 0.78)
        case .days30to90: return Color(hue: 0.38, saturation: 0.4, brightness: 0.7)
        case .days90to365: return Color(hue: 0.12, saturation: 0.45, brightness: 0.8)
        case .oneToTwoYears: return Color(hue: 0.06, saturation: 0.55, brightness: 0.72)
        case .overTwoYears: return Color(hue: 0.02, saturation: 0.6, brightness: 0.55)
        case .unknown: return DiskMapTheme.mutedLabel.opacity(0.4)
        }
    }
}
