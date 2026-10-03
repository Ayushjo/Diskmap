import Foundation
import Testing
@testable import DiskMapCore

@Suite("Biggest Folders composition + insight")
struct FolderInsightTests {
    @Test func subtreeTotalsOnlyCountDescendants() {
        var tree = FileTree()
        _ = tree.addNode(name: "root", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let movies = tree.addNode(name: "Movies", parent: 0, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "Dune.mkv", parent: movies, isDirectory: false, logicalSize: 1000, allocatedSize: 1000, modifiedDaysSinceEpoch: 10)
        let docs = tree.addNode(name: "Documents", parent: 0, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "notes.pdf", parent: docs, isDirectory: false, logicalSize: 50, allocatedSize: 50, modifiedDaysSinceEpoch: 10)
        let both = tree.rollUpBoth()
        let categories = [
            FileTypeCategory(id: "video", label: "Videos", colorHex: "#000", extensions: ["mkv"]),
            FileTypeCategory(id: "docs", label: "Documents", colorHex: "#111", extensions: ["pdf"]),
        ]
        let underMovies = FileTypeCatalog.totals(under: movies, in: tree, sizes: both.allocated, categories: categories)
        #expect(underMovies.count == 1)
        #expect(underMovies[0].categoryID == "video")
        #expect(underMovies[0].bytes == 1000)

        let underDocs = FileTypeCatalog.totals(under: docs, in: tree, sizes: both.allocated, categories: categories)
        #expect(underDocs.count == 1)
        #expect(underDocs[0].categoryID == "docs")
        #expect(underDocs[0].bytes == 50)

        let largest = FileTypeCatalog.largestFiles(under: movies, in: tree, sizes: both.allocated, limit: 3)
        #expect(largest.count == 1)
        #expect(largest[0].name == "Dune.mkv")
    }

    @Test func folderInsightBuildsCompositionAndCounts() {
        var tree = FileTree()
        _ = tree.addNode(name: "Home", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let downloads = tree.addNode(name: "Downloads", parent: 0, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "setup.dmg", parent: downloads, isDirectory: false, logicalSize: 200, allocatedSize: 200, modifiedDaysSinceEpoch: 5)
        _ = tree.addNode(name: "old.zip", parent: downloads, isDirectory: false, logicalSize: 80, allocatedSize: 80, modifiedDaysSinceEpoch: 1)
        let both = tree.rollUpBoth()
        let counts = tree.rollUpDescendantCounts()
        let categories = [
            FileTypeCategory(id: "disk", label: "Disk Images", colorHex: "#00f", extensions: ["dmg"]),
            FileTypeCategory(id: "archive", label: "Archives", colorHex: "#f80", extensions: ["zip"]),
        ]
        let insight = FolderInsight.build(
            nodeID: downloads,
            tree: tree,
            root: URL(fileURLWithPath: "/Users/test", isDirectory: true),
            totals: both.allocated,
            fileCounts: counts.files,
            folderCounts: counts.folders,
            categories: categories,
            today: 400
        )
        #expect(insight != nil)
        guard let insight else { return }
        #expect(insight.bytes == 280)
        #expect(insight.fileCount == 2)
        #expect(insight.composition.count == 2)
        #expect(insight.largestFiles.first?.name == "setup.dmg")
        #expect(insight.whyLarge.lowercased().contains("disk") || insight.whyLarge.lowercased().contains("archive"))
        // old.zip day=1 → age ~399 days (<365? 400-1=399 > 365) so reviewable includes old.zip at least
        #expect(insight.reviewableBytes >= 80)
    }

    @Test func protectedFolderHasZeroReviewable() {
        var tree = FileTree()
        _ = tree.addNode(name: "root", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let system = tree.addNode(name: "System", parent: 0, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "kernel", parent: system, isDirectory: false, logicalSize: 500, allocatedSize: 500, modifiedDaysSinceEpoch: 1)
        let both = tree.rollUpBoth()
        let counts = tree.rollUpDescendantCounts()
        let insight = FolderInsight.build(
            nodeID: system,
            tree: tree,
            root: URL(fileURLWithPath: "/", isDirectory: true),
            totals: both.allocated,
            fileCounts: counts.files,
            folderCounts: counts.folders,
            categories: [],
            today: 2000
        )
        #expect(insight != nil)
        #expect(insight?.safety.level == .protected)
        #expect(insight?.reviewableBytes == 0)
    }
}
