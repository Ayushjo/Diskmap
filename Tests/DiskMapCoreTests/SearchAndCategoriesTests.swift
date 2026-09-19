import Foundation
import Testing
@testable import DiskMapCore

struct FileSearchIndexTests {

    /// root
    /// ├─ src/ (dir)
    /// │  ├─ main.swift (file, 300)
    /// │  └─ index.html (file, 100)
    /// ├─ docs/ (dir)
    /// │  └─ main_notes.md (file, 200)
    /// └─ MAINFRAME (file, 50) — same needle, different case
    private func makeTree() -> (FileTree, [Int64: Int32]) {
        var tree = FileTree()
        var ids: [Int64: Int32] = [:]
        let root = tree.addNode(name: "root", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        ids[0] = root
        let src = tree.addNode(name: "src", parent: root, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        ids[1] = src
        ids[2] = tree.addNode(name: "main.swift", parent: src, isDirectory: false, logicalSize: 300, allocatedSize: 300, modifiedDaysSinceEpoch: 0)
        ids[3] = tree.addNode(name: "index.html", parent: src, isDirectory: false, logicalSize: 100, allocatedSize: 100, modifiedDaysSinceEpoch: 0)
        let docs = tree.addNode(name: "docs", parent: root, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        ids[4] = docs
        ids[5] = tree.addNode(name: "main_notes.md", parent: docs, isDirectory: false, logicalSize: 200, allocatedSize: 200, modifiedDaysSinceEpoch: 0)
        ids[6] = tree.addNode(name: "MAINFRAME", parent: root, isDirectory: false, logicalSize: 50, allocatedSize: 50, modifiedDaysSinceEpoch: 0)
        return (tree, ids)
    }

    @Test func substringMatchIsCaseInsensitiveAndRankedBySize() {
        let (tree, ids) = makeTree()
        let totals = tree.rollUpSizes()
        let index = FileSearchIndex(tree: tree)

        let result = index.search("main", in: tree, totals: totals)

        // main.swift (300) > main_notes.md (200) > MAINFRAME (50)
        #expect(result.ids == [ids[2]!, ids[5]!, ids[6]!])
        #expect(result.totalMatches == 3)
        #expect(result.matchedNames == 3)
    }

    @Test func kindFilterSplitsFilesAndFolders() {
        let (tree, ids) = makeTree()
        let totals = tree.rollUpSizes()
        let index = FileSearchIndex(tree: tree)

        let files = index.search("main", in: tree, totals: totals, kind: .files)
        #expect(files.ids == [ids[2]!, ids[5]!, ids[6]!])

        // "s" matches folder names src and docs; kind applies to the node
        // itself. Ranked by rolled-up size: src (400) > docs (200).
        let folders = index.search("s", in: tree, totals: totals, kind: .folders)
        #expect(folders.ids == [ids[1]!, ids[4]!])
    }

    @Test func limitCapsResultsButNotTheCount() {
        let (tree, ids) = makeTree()
        let totals = tree.rollUpSizes()
        let index = FileSearchIndex(tree: tree)

        let result = index.search("main", in: tree, totals: totals, limit: 1)
        #expect(result.ids == [ids[2]!])
        #expect(result.totalMatches == 3)
    }

    @Test func emptyQueryAndWrongTotalsReturnEmpty() {
        let (tree, _) = makeTree()
        let index = FileSearchIndex(tree: tree)
        #expect(index.search("  ", in: tree, totals: tree.rollUpSizes()).ids.isEmpty)
        #expect(index.search("x", in: tree, totals: []).ids.isEmpty)
    }

    @Test func sameNameInTwoDirectoriesFansOut() {
        var tree = FileTree()
        let root = tree.addNode(name: "root", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let a = tree.addNode(name: "a", parent: root, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let b = tree.addNode(name: "b", parent: root, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        // Interned once — two nodes, one name-table entry.
        let x1 = tree.addNode(name: "report.csv", parent: a, isDirectory: false, logicalSize: 10, allocatedSize: 10, modifiedDaysSinceEpoch: 0)
        let x2 = tree.addNode(name: "report.csv", parent: b, isDirectory: false, logicalSize: 20, allocatedSize: 20, modifiedDaysSinceEpoch: 0)

        let index = FileSearchIndex(tree: tree)
        let result = index.search("report", in: tree, totals: tree.rollUpSizes())
        #expect(Set(result.ids) == [x1, x2])
        #expect(result.matchedNames == 1)
    }
}

struct QuickWinsCategoryTests {

    @Test func bundledCategoriesCoverTheOldFlatList() {
        let flat = QuickWins.bundledPatterns()
        #expect(flat.directoryNames.contains("node_modules"))
        #expect(flat.directoryNames.contains("DerivedData"))
        #expect(flat.pathSuffixes.contains { $0.contains("iOS DeviceSupport") })
        // New developer buckets made it in.
        #expect(flat.directoryNames.contains("__pycache__"))
        #expect(flat.directoryNames.contains(".dart_tool"))
        #expect(flat.pathSuffixes.contains { $0.contains(".gradle") })
    }

    @Test func findCategorizedAttributesEachHitOnce() {
        var tree = FileTree()
        let root = tree.addNode(name: "home", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let proj = tree.addNode(name: "proj", parent: root, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let modules = tree.addNode(name: "node_modules", parent: proj, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        // dist inside node_modules is swallowed by the module match.
        _ = tree.addNode(name: "dist", parent: modules, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let venv = tree.addNode(name: ".venv", parent: proj, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)

        let hits = QuickWins.findCategorized(
            in: tree,
            root: URL(fileURLWithPath: "/tmp/home", isDirectory: true),
            categories: QuickWins.bundledCategories()
        )
        let byID = Dictionary(uniqueKeysWithValues: hits.map { ($0.id, $0) })
        #expect(byID.count == 2)
        #expect(byID[modules]?.categoryID == "node")
        #expect(byID[venv]?.categoryID == "python")
    }
}

struct AgeMapFilesTests {

    @Test func filesReturnsOnlyFilesInTheBucketLargestFirst() {
        var tree = FileTree()
        let today = AgeMap.today()
        let root = tree.addNode(name: "root", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let recent = tree.addNode(name: "recent", parent: root, isDirectory: false, logicalSize: 10, allocatedSize: 10, modifiedDaysSinceEpoch: today - 1)
        let oldSmall = tree.addNode(name: "old_small", parent: root, isDirectory: false, logicalSize: 5, allocatedSize: 5, modifiedDaysSinceEpoch: today - 800)
        let oldBig = tree.addNode(name: "old_big", parent: root, isDirectory: false, logicalSize: 99, allocatedSize: 99, modifiedDaysSinceEpoch: today - 900)
        // A directory modified long ago must not leak into file results.
        _ = tree.addNode(name: "old_dir", parent: root, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: today - 900)

        let files = AgeMap.files(
            in: tree, totals: tree.rollUpSizes(), today: today, bucket: .overTwoYears
        )
        #expect(files == [oldBig, oldSmall])
        #expect(!files.contains(recent))
    }
}
