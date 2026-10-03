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
        #expect(snap.categoryMode == .home)
    }

    // MARK: - TASK-076 categories for any root

    private func file(_ tree: inout FileTree, _ name: String, _ parent: Int32, _ size: Int64) {
        _ = tree.addNode(name: name, parent: parent, isDirectory: false, logicalSize: size, allocatedSize: size, modifiedDaysSinceEpoch: 0)
    }

    private func folder(_ tree: inout FileTree, _ name: String, _ parent: Int32) -> Int32 {
        tree.addNode(name: name, parent: parent, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
    }

    @Test func aDownloadsFolderIsSplitByFileType() {
        var tree = FileTree()
        _ = folder(&tree, "Downloads", -1)
        file(&tree, "talk.mp4", 0, 1_000)
        file(&tree, "backup.zip", 0, 300)
        file(&tree, "invoice.pdf", 0, 200)
        file(&tree, "mystery.xyz", 0, 50)
        let nested = folder(&tree, "Trip", 0)
        file(&tree, "clip.mov", nested, 100)
        let both = tree.rollUpBoth()
        let snap = AnalysisSnapshot.build(
            tree: tree, root: URL(fileURLWithPath: "/Volumes/Archive/Downloads", isDirectory: true),
            allocated: both.allocated, logical: both.logical
        )
        #expect(snap.categoryMode == .folder)
        #expect(snap.categories.map(\.key) == ["type:video", "type:archive", "type:document", "other"])
        #expect(snap.categories.map(\.bytes) == [1_100, 300, 200, 50])
        #expect(snap.categories.first?.fileKind == "video")
        #expect(snap.categories.first?.colorHex != nil)
        #expect(snap.categories.reduce(0) { $0 + $1.bytes } == both.allocated[0])
        let story = StorageNarrator.stories(from: snap, limit: 10).first { $0.kind == .category }
        #expect(story?.title == "Video is 67% of this folder")
    }

    @Test func passedFileTypesAreUsedAsGiven() {
        var tree = FileTree()
        _ = folder(&tree, "Projects", -1)
        file(&tree, "a.mp4", 0, 10)
        let both = tree.rollUpBoth()
        let given = [FileTypeTotals(categoryID: "video", label: "Video", colorHex: "#123456", bytes: 7)]
        let snap = AnalysisSnapshot.build(
            tree: tree, root: URL(fileURLWithPath: "/tmp/Projects", isDirectory: true),
            allocated: both.allocated, logical: both.logical, fileTypes: given
        )
        #expect(snap.categories.map(\.bytes) == [7, 3])
        #expect(snap.categories.first?.colorHex == "#123456")
    }

    @Test func theWholeDiskKeepsTheNameMapping() {
        var tree = FileTree()
        _ = folder(&tree, "Macintosh HD", -1)
        file(&tree, "x", folder(&tree, "System", 0), 400)
        file(&tree, "y", folder(&tree, "Users", 0), 300)
        file(&tree, "z", folder(&tree, "Applications", 0), 200)
        let both = tree.rollUpBoth()
        let snap = AnalysisSnapshot.build(
            tree: tree, root: URL(fileURLWithPath: "/", isDirectory: true),
            allocated: both.allocated, logical: both.logical
        )
        #expect(snap.categoryMode == .wholeDisk)
        #expect(Set(snap.categories.map(\.key)) == ["system", "documents", "applications"])
        #expect(snap.categories.allSatisfy { $0.fileKind == nil })
    }

    @Test func aHomeShapedFolderElsewhereIsStillAHome() {
        var tree = FileTree()
        _ = folder(&tree, "olduser", -1)
        _ = folder(&tree, "Library", 0)
        _ = folder(&tree, "Desktop", 0)
        #expect(CategoryMode.detect(tree: tree, root: URL(fileURLWithPath: "/Volumes/Backup/olduser"), home: "/Users/me") == .home)
        #expect(CategoryMode.detect(tree: tree, root: URL(fileURLWithPath: "/Users/me/"), home: "/Users/me") == .home)
        var plain = FileTree()
        _ = folder(&plain, "Code", -1)
        _ = folder(&plain, "Library", 0)
        #expect(CategoryMode.detect(tree: plain, root: URL(fileURLWithPath: "/Users/me/Code"), home: "/Users/me") == .folder)
    }

    @Test func otherNeverLeadsTheStory() {
        var tree = FileTree()
        _ = folder(&tree, "me", -1)
        file(&tree, "x", folder(&tree, "Library", 0), 10)
        file(&tree, "y", folder(&tree, "Downloads", 0), 20)
        file(&tree, "z", folder(&tree, "Stuff", 0), 900)
        let both = tree.rollUpBoth()
        let snap = AnalysisSnapshot.build(
            tree: tree, root: URL(fileURLWithPath: "/Volumes/B/me", isDirectory: true),
            allocated: both.allocated, logical: both.logical
        )
        let story = StorageNarrator.stories(from: snap, limit: 10).first { $0.kind == .category }
        #expect(story?.title == "Downloads leads this scan")
    }

    /// Real fixture: a hard-linked video counts once, so the type rows still
    /// add up to the scanned total.
    @Test func realFolderWithAHardLinkSumsToTheScan() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskmap-types-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("film.mp4")
        try Data(repeating: 1, count: 300_000).write(to: video)
        #expect(link(video.path, root.appendingPathComponent("film-again.mp4").path) == 0)
        try Data(repeating: 2, count: 40_000).write(to: root.appendingPathComponent("notes.txt"))
        try Data(repeating: 3, count: 9_000).write(to: root.appendingPathComponent("blob.unknownext"))

        let tree = await ScanEngine().scan(root: root).tree
        let both = tree.rollUpBoth()
        let snap = AnalysisSnapshot.build(tree: tree, root: root, allocated: both.allocated, logical: both.logical)
        #expect(snap.categoryMode == .folder)
        #expect(snap.categories.reduce(0) { $0 + $1.bytes } == both.allocated[0])
        #expect(snap.categories.first?.key == "type:video")
        #expect(snap.categories.contains { $0.key == "other" })
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

    // MARK: - TASK-040 volume reconciliation

    private func snapshot(used: UInt64?, scannedOnDisk: Int64) -> AnalysisSnapshot {
        var snap = AnalysisSnapshot.empty
        snap.scannedOnDiskBytes = scannedOnDisk
        if let used {
            snap.volume = VolumeStats(volumeName: "T", totalBytes: used * 2, freeBytes: used, usedBytes: used)
        }
        return snap
    }

    @Test func reconciliationReportsTheGap() throws {
        let rec = try #require(snapshot(used: 1_000, scannedOnDisk: 600).reconciliation)
        #expect(rec.unaccountedBytes == 400)
        #expect(!rec.scannedExceedsUsed)
        #expect(abs(rec.coverageFraction - 0.6) < 0.0001)
    }

    /// Clones listed once per copy can push the scan past "used"; the gap must
    /// clamp to 0 and say why, never go negative.
    @Test func reconciliationNeverGoesNegative() throws {
        let rec = try #require(snapshot(used: 1_000, scannedOnDisk: 1_300).reconciliation)
        #expect(rec.unaccountedBytes == 0)
        #expect(rec.scannedExceedsUsed)
        #expect(rec.coverageFraction == 1)
    }

    @Test func noVolumeMeansNoReconciliation() {
        #expect(snapshot(used: nil, scannedOnDisk: 600).reconciliation == nil)
    }

    /// The comparison is on-disk to on-disk even when the UI shows logical sizes.
    @Test func reconciliationUsesAllocatedWhateverTheBasis() {
        var tree = FileTree()
        _ = tree.addNode(name: "root", parent: -1, isDirectory: true,
                         logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "sparse.img", parent: 0, isDirectory: false,
                         logicalSize: 10_000, allocatedSize: 1_000, modifiedDaysSinceEpoch: 1)
        let both = tree.rollUpBoth()
        let snap = AnalysisSnapshot.build(
            tree: tree, root: URL(fileURLWithPath: NSTemporaryDirectory()),
            allocated: both.allocated, logical: both.logical, basis: .logical
        )
        #expect(snap.scannedBytes == 10_000)
        #expect(snap.scannedOnDiskBytes == 1_000)
    }
}
