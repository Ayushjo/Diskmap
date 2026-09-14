import Foundation
import Testing
@testable import DiskMapCore

@Suite("AnalysisSnapshot")
struct AnalysisSnapshotTests {
    @Test func categoriesFromHomeLikeTree() {
        var tree = FileTree()
        let root = tree.addNode(name: "Home", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        #expect(root == 0)
        let library = tree.addNode(name: "Library", parent: 0, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let caches = tree.addNode(name: "Caches", parent: library, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "c.tmp", parent: caches, isDirectory: false, logicalSize: 100, allocatedSize: 100, modifiedDaysSinceEpoch: 0)
        let downloads = tree.addNode(name: "Downloads", parent: 0, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "setup.dmg", parent: downloads, isDirectory: false, logicalSize: 200, allocatedSize: 200, modifiedDaysSinceEpoch: 0)
        let npm = tree.addNode(name: ".npm", parent: 0, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "pkg", parent: npm, isDirectory: false, logicalSize: 50, allocatedSize: 50, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "big.mkv", parent: 0, isDirectory: false, logicalSize: 500, allocatedSize: 500, modifiedDaysSinceEpoch: 0)
        let both = tree.rollUpBoth()
        let snap = AnalysisSnapshot.build(
            tree: tree,
            root: URL(fileURLWithPath: "/Users/test", isDirectory: true),
            allocated: both.allocated,
            logical: both.logical,
            quickWins: []
        )
        #expect(!snap.categories.isEmpty)
        #expect(snap.categories.contains { $0.key == "downloads" && $0.bytes == 200 })
        #expect(snap.categories.contains { $0.key == "developer" && $0.bytes == 50 })
        #expect(snap.categories.contains { $0.key == "caches" && $0.bytes == 100 })
        #expect(snap.topFiles.first?.name == "big.mkv")
    }

    @Test func safetyNpmIsSafeWithReason() {
        let a = SafetyClassifier.assess(path: "/Users/x/.npm", name: ".npm", isDirectory: true)
        #expect(a.level == .safe)
        #expect(!a.reason.isEmpty)
    }

    @Test func safetySystemIsProtected() {
        let a = SafetyClassifier.assess(path: "/System/Library", name: "Library", isDirectory: true)
        #expect(a.level == .protected)
    }

    @Test func unknownDefaultsToReview() {
        let a = SafetyClassifier.assess(path: "/Users/x/WeirdStuff", name: "WeirdStuff", isDirectory: true)
        #expect(a.level == .review)
    }
}
