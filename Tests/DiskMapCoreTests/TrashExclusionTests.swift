import Foundation
import Testing
@testable import DiskMapCore

/// What is already in the Trash is never a finding (docs/MAC-FIXES-FROM-WINDOWS.md
/// §3.3: the Windows build counted 28 GB of node_modules in the Recycle Bin).
@Suite("Trash is not a finding")
struct TrashExclusionTests {
    private static func tree() -> (FileTree, URL) {
        var tree = FileTree()
        func dir(_ name: String, _ parent: Int32) -> Int32 {
            tree.addNode(name: name, parent: parent, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 100)
        }
        func file(_ name: String, _ parent: Int32, _ bytes: Int64, day: Int32 = 100) {
            _ = tree.addNode(name: name, parent: parent, isDirectory: false, logicalSize: bytes, allocatedSize: bytes,
                             modifiedDaysSinceEpoch: day)
        }
        let root = dir("Users", -1)
        let user = dir("alex", root)
        let trash = dir(".Trash", user)
        let proj = dir("proj", trash)
        file("index.js", dir("node_modules", proj), 300_000_000)
        file("old.mkv", trash, 4_000_000_000)
        let downloads = dir("Downloads", trash)
        file("setup.dmg", downloads, 900_000_000)
        // The same things outside the Trash, which must still be found.
        let live = dir("live", user)
        file("index.js", dir("node_modules", live), 200_000_000)
        file("movie.mkv", dir("Movies", user), 3_000_000_000)
        return (tree, URL(fileURLWithPath: "/Users", isDirectory: true))
    }

    @Test func isSystemHoldingRecognisesTheTrashAndFriends() {
        #expect(StorageClassifier.isSystemHolding("/Users/a/.Trash/x/node_modules"))
        #expect(StorageClassifier.isSystemHolding("/Volumes/Ext/.Trashes/501/file"))
        #expect(StorageClassifier.isSystemHolding("/.Spotlight-V100/Store-V2"))
        #expect(StorageClassifier.isSystemHolding("/private/var/vm/sleepimage"))
        #expect(!StorageClassifier.isSystemHolding("/Users/a/Trash notes/x"))
        #expect(!StorageClassifier.isSystemHolding("/Users/a/code/node_modules"))
    }

    @Test func noCatalogListsWhatIsInTheTrash() {
        let (tree, root) = Self.tree()
        let totals = tree.rollUpBoth().allocated
        func inTrash(_ path: String) -> Bool { path.contains("/.Trash") }

        let dev = DeveloperCatalog.build(tree: tree, root: root, totals: totals)
        #expect(!dev.items.contains { inTrash($0.absolutePath) })
        #expect(dev.items.contains { $0.absolutePath == "/Users/alex/live/node_modules" })

        let quick = QuickWins.find(in: tree, root: root, patterns: QuickWins.bundledPatterns())
        #expect(!quick.contains { inTrash(tree.path(of: $0.id, root: root).path) })

        let forgotten = ForgottenFiles.candidates(tree: tree, root: root, totals: totals, today: 2_000)
        #expect(!forgotten.contains { inTrash(tree.path(of: $0.id, root: root).path) })

        let media = MediaCatalog.build(tree: tree, root: root, totals: totals, today: 2_000)
        #expect(!media.candidates.contains { inTrash($0.absolutePath) })
        #expect(media.candidates.contains { $0.name == "movie.mkv" })

        let downloads = OldDownloadsCatalog.build(tree: tree, root: root, totals: totals, today: 2_000)
        #expect(!downloads.candidates.contains { inTrash($0.absolutePath) })
    }
}
