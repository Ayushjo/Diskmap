import Foundation

/// Where bytes live and what removing them means — ported from the Windows
/// build's `StorageClassifier` (docs/MAC-FIXES-FROM-WINDOWS.md §3).
public enum StorageClassifier {

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
