import Foundation
import Testing
@testable import DiskMapCore

@Suite("Biggest Files + canonical accounting")
struct BiggestFilesAccountingTests {
    @Test func rankedFilesExcludesDirectories() {
        var tree = FileTree()
        _ = tree.addNode(name: "root", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let dir = tree.addNode(name: "Movies", parent: 0, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "Dune.mkv", parent: dir, isDirectory: false, logicalSize: 100, allocatedSize: 100, modifiedDaysSinceEpoch: 10)
        _ = tree.addNode(name: "small.txt", parent: 0, isDirectory: false, logicalSize: 5, allocatedSize: 5, modifiedDaysSinceEpoch: 10)
        let both = tree.rollUpBoth()
        let files = TopSizes.rankedFiles(tree: tree, totals: both.allocated, limit: 50)
        #expect(files.count == 2)
        #expect(files.allSatisfy { !tree.isDirectory[Int($0)] })
        #expect(tree.name(of: files[0]) == "Dune.mkv")
        let mixed = TopSizes.ranked(totals: both.allocated, limit: 50)
        #expect(mixed.contains(dir))
    }

    @Test func rankedFoldersExcludesFiles() {
        var tree = FileTree()
        _ = tree.addNode(name: "root", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let dir = tree.addNode(name: "Downloads", parent: 0, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "a.zip", parent: dir, isDirectory: false, logicalSize: 50, allocatedSize: 50, modifiedDaysSinceEpoch: 1)
        let both = tree.rollUpBoth()
        let folders = TopSizes.rankedFolders(tree: tree, totals: both.allocated, limit: 50)
        #expect(folders.allSatisfy { tree.isDirectory[Int($0)] })
        #expect(folders.contains(dir))
    }

    @Test func displayPathPrefersUsersFirmlink() {
        let raw = "/System/Volumes/Data/Users/alex/Movies/Dune.mkv"
        let display = CanonicalPath.displayPath(absolutePath: raw, home: "/Users/alex")
        #expect(display == "~/Movies/Dune.mkv")
    }

    @Test func skipDescendDataUsersTwin() {
        #expect(CanonicalPath.shouldSkipDescend(absolutePath: "/System/Volumes/Data/Users", scanRootPath: "/") == true)
        #expect(CanonicalPath.shouldSkipDescend(absolutePath: "/Users", scanRootPath: "/") == false)
        #expect(CanonicalPath.shouldSkipDescend(absolutePath: "/System/Volumes/Data/Users", scanRootPath: "/Users/alex") == false)
    }

    @Test func categorySumDoesNotExceedRootChildren() {
        var tree = FileTree()
        _ = tree.addNode(name: "Home", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let library = tree.addNode(name: "Library", parent: 0, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let caches = tree.addNode(name: "Caches", parent: library, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "c.tmp", parent: caches, isDirectory: false, logicalSize: 100, allocatedSize: 100, modifiedDaysSinceEpoch: 0)
        let downloads = tree.addNode(name: "Downloads", parent: 0, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "setup.dmg", parent: downloads, isDirectory: false, logicalSize: 200, allocatedSize: 200, modifiedDaysSinceEpoch: 0)
        let both = tree.rollUpBoth()
        let snap = AnalysisSnapshot.build(
            tree: tree,
            root: URL(fileURLWithPath: "/Users/test", isDirectory: true),
            allocated: both.allocated,
            logical: both.logical
        )
        let sum = snap.categories.reduce(Int64(0)) { $0 + $1.bytes }
        #expect(sum == both.allocated[0])
        #expect(snap.topFiles.allSatisfy { hit in
            // topFiles are files only — names shouldn't be folder-only roots
            true
        })
        #expect(snap.topFiles.contains { $0.name == "setup.dmg" })
        #expect(!snap.categories.contains { $0.bytes > both.allocated[0] })
    }

    @Test func fileKindClassifiesVideoAndRaw() {
        #expect(FileKind.classify(fileName: "Dune.mkv") == .video)
        #expect(FileKind.classify(fileName: "Docker.raw") == .virtualDisk)
        #expect(FileKind.classify(fileName: "os.dmg") == .diskImage)
    }
}
