import Foundation
import Testing
@testable import DiskMapApp
@testable import DiskMapCore

/// `ScanModel` lives in the app target, which had no tests at all before
/// TASK-041. These cover the per-screen catalog caches it owns.
@MainActor
@Suite("ScanModel caches")
struct ScanModelCacheTests {

    /// A real, non-empty Old Downloads catalog to use as a sentinel.
    static func sentinelOldDownloads() -> OldDownloadsCatalogResult {
        var tree = FileTree()
        let root = tree.addNode(name: "Users", parent: -1, isDirectory: true,
                                logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1000)
        let user = tree.addNode(name: "alex", parent: root, isDirectory: true,
                                logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1000)
        let dl = tree.addNode(name: "Downloads", parent: user, isDirectory: true,
                              logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1000)
        _ = tree.addNode(name: "Dune.mkv", parent: dl, isDirectory: false,
                         logicalSize: 5_000_000_000, allocatedSize: 5_000_000_000,
                         modifiedDaysSinceEpoch: 100)
        return OldDownloadsCatalog.build(
            tree: tree,
            root: URL(fileURLWithPath: "/Users", isDirectory: true),
            totals: tree.rollUpBoth().allocated,
            today: 1000
        )
    }

    /// TASK-041: the guard's else-branch in `refreshDeveloperCache` also
    /// cleared `cachedOldDownloads`, so opening Developer Storage before
    /// totals were ready silently emptied the Old Downloads screen.
    @Test func refreshingDeveloperCacheWithoutATreeLeavesOldDownloadsAlone() {
        let model = ScanModel()
        let sentinel = Self.sentinelOldDownloads()
        #expect(!sentinel.candidates.isEmpty, "sentinel must be non-empty to prove anything")
        model.cachedOldDownloads = sentinel

        model.refreshDeveloperCache()       // no tree → guard else-branch

        #expect(model.cachedOldDownloads == sentinel)
        #expect(model.cachedDeveloper == .empty)
    }

    /// TASK-039: a scan with an unreadable folder must say so, with the
    /// folder's path, instead of silently reporting short totals.
    @Test func scanRecordsUnreadableFoldersWithReadablePaths() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskmap-denied-\(UUID().uuidString)")
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appendingPathComponent("inside.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }

        let model = ScanModel()
        await model.scan(root)
        #expect(model.deniedDirectoryIDs.count == 1)
        let examples = model.deniedDirectoryExamples()
        #expect(examples.count == 1)
        #expect(examples.first?.hasSuffix("/locked") == true)
    }
}
