import Foundation
import Testing
@testable import DiskMapCore

/// TASK-061 — an incremental update must produce the tree a full walk would,
/// or refuse and say why.
@Suite("Incremental scan")
struct IncrementalScanTests {

    final class Fixture {
        let root: URL
        let cache: ScanCache
        init() throws {
            let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("diskmap-incr-\(UUID().uuidString)")
            root = base.appendingPathComponent("root")
            cache = ScanCache(directory: base.appendingPathComponent("cache"))
            for (rel, bytes) in [("a/one.bin", 10_000), ("a/b/two.bin", 20_000), ("a/b/c/three.bin", 30_000),
                                 ("keep/k1.txt", 500), ("keep/deep/k2.txt", 700), ("gone/x.bin", 4_000),
                                 ("top.txt", 100)] {
                try put(rel, bytes)
            }
        }
        deinit { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        func put(_ rel: String, _ bytes: Int) throws {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 9, count: bytes).write(to: url)
        }

        /// A full walk, saved as the baseline an app scan would leave.
        func fullScanAndSave() async throws -> ScanEngine.Result {
            let result = await ScanEngine().scan(root: root)
            let baseline = try #require(IncrementalScan.baselineAfterFullScan(
                root: root, eventIDAtStart: result.eventIDAtStart,
                deniedPaths: result.deniedDirectoryIDs.map { result.tree.path(of: $0, root: root).path }))
            try cache.save(tree: result.tree, baseline: baseline)
            return result
        }
    }

    /// Everything a node records, keyed by path — order-independent.
    static func signature(_ tree: FileTree, root: URL) -> [String: String] {
        var map: [String: String] = [:]
        for index in 1..<tree.count {
            let id = Int32(index)
            map[tree.path(of: id, root: root).path] = [
                tree.isDirectory[index] ? "d" : "f", "\(tree.logicalSize[index])", "\(tree.allocatedSize[index])",
                "\(tree.modifiedDay[index])", "\(tree.createdDay[index])", "\(tree.flags[index])", "\(tree.fileID[index])",
            ].joined(separator: " ")
        }
        return map
    }

    @Test func updateMatchesAFullWalkAfterEveryKindOfChange() async throws {
        let f = try Fixture()
        _ = try await f.fullScanAndSave()

        try f.put("a/b/new.bin", 12_345)                                              // created
        try Data(repeating: 1, count: 99_999).write(to: f.root.appendingPathComponent("a/one.bin"))  // grown
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("gone"))   // folder deleted
        try f.put("fresh/deeper/still/file.bin", 5_000)                               // new subtree
        try FileManager.default.moveItem(at: f.root.appendingPathComponent("a/b/c"),
                                         to: f.root.appendingPathComponent("keep/moved-c"))   // moved
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("top.txt"))    // file deleted

        let outcome = await IncrementalScan.update(root: f.root, cache: f.cache)
        guard case .updated(let update) = outcome else {
            Issue.record("expected an update, got \(outcome)")
            return
        }
        let full = await ScanEngine().scan(root: f.root)
        #expect(Self.signature(update.tree, root: f.root) == Self.signature(full.tree, root: f.root))
        #expect(update.tree.rollUpBoth().allocated[0] == full.tree.rollUpBoth().allocated[0])
        #expect(update.changedDirectories > 0)
        #expect(update.baseline.incrementalRuns == 1)
        // Structural invariant every consumer relies on.
        #expect((1..<update.tree.count).allSatisfy { update.tree.parent[$0] < Int32($0) })
    }

    @Test func nothingChangedMeansNothingRelisted() async throws {
        let f = try Fixture()
        let first = try await f.fullScanAndSave()
        let outcome = await IncrementalScan.update(root: f.root, cache: f.cache)
        guard case .updated(let update) = outcome else {
            Issue.record("expected an update, got \(outcome)")
            return
        }
        #expect(update.rewalkedSubtrees == 0)
        #expect(Self.signature(update.tree, root: f.root) == Self.signature(first.tree, root: f.root))
    }

    @Test func updatesChainFromTheSavedBaseline() async throws {
        let f = try Fixture()
        _ = try await f.fullScanAndSave()
        try f.put("keep/second.txt", 800)
        guard case .updated(let first) = await IncrementalScan.update(root: f.root, cache: f.cache) else {
            Issue.record("first update refused"); return
        }
        try f.cache.save(tree: first.tree, baseline: first.baseline)
        try f.put("a/third.txt", 900)
        guard case .updated(let second) = await IncrementalScan.update(root: f.root, cache: f.cache) else {
            Issue.record("second update refused"); return
        }
        #expect(second.baseline.incrementalRuns == 2)
        #expect(second.baseline.fullScanAt == first.baseline.fullScanAt)
        let full = await ScanEngine().scan(root: f.root)
        #expect(Self.signature(second.tree, root: f.root) == Self.signature(full.tree, root: f.root))
    }

    /// The app's Rescan: start from the tree in memory, not the cache file.
    @Test func updatesFromAnInMemoryBase() async throws {
        let f = try Fixture()
        let full = await ScanEngine().scan(root: f.root)
        let baseline = try #require(IncrementalScan.baselineAfterFullScan(root: f.root, eventIDAtStart: full.eventIDAtStart, deniedPaths: []))
        // Nothing saved to the cache at all: only the in-memory base exists.
        try f.put("keep/added.txt", 321)
        let outcome = await IncrementalScan.update(root: f.root, cache: f.cache,
                                                   base: .init(tree: full.tree, baseline: baseline))
        guard case .updated(let update) = outcome else { Issue.record("expected an update, got \(outcome)"); return }
        let fresh = await ScanEngine().scan(root: f.root)
        #expect(Self.signature(update.tree, root: f.root) == Self.signature(fresh.tree, root: f.root))
        // A base for another folder is ignored, never applied.
        let other = ScanCache.Baseline(rootPath: "/elsewhere", eventID: 1, volumeUUID: baseline.volumeUUID,
                                       fullScanAt: Date(), updatedAt: Date(), incrementalRuns: 0, deniedPaths: [])
        guard case .fullScanNeeded = await IncrementalScan.update(root: f.root, cache: f.cache,
                                                                   base: .init(tree: full.tree, baseline: other)) else {
            Issue.record("a base for another root must not be used"); return
        }
    }

    @Test func refusesWithoutABaselineOrAfterReset() async throws {
        let f = try Fixture()
        guard case .fullScanNeeded(let none) = await IncrementalScan.update(root: f.root, cache: f.cache) else {
            Issue.record("no baseline must mean a full walk"); return
        }
        #expect(none.contains("no earlier scan"))
        _ = try await f.fullScanAndSave()
        f.cache.invalidate(rootPath: f.root.path)
        guard case .fullScanNeeded(let reset) = await IncrementalScan.update(root: f.root, cache: f.cache) else {
            Issue.record("a changed volume id must mean a full walk"); return
        }
        #expect(reset.contains("reset"))
    }

    @Test func policyForcesPeriodicFullWalks() async throws {
        let f = try Fixture()
        _ = try await f.fullScanAndSave()
        var policy = IncrementalScan.Policy()
        policy.maxIncrementalRuns = 0
        guard case .fullScanNeeded(let byCount) = await IncrementalScan.update(root: f.root, cache: f.cache, policy: policy) else {
            Issue.record("run limit ignored"); return
        }
        #expect(byCount.contains("periodic"))
        let later = Date().addingTimeInterval(8 * 86_400)
        guard case .fullScanNeeded(let byAge) = await IncrementalScan.update(root: f.root, cache: f.cache, now: later) else {
            Issue.record("age limit ignored"); return
        }
        #expect(byAge.contains("week"))
    }

    /// A change FSEvents never reported (simulated by a baseline whose event
    /// id is already past it) must be caught by the spot check, not trusted.
    @Test func spotCheckCatchesAChangeWithNoEvent() async throws {
        let f = try Fixture()
        let result = await ScanEngine().scan(root: f.root)
        try f.put("keep/deep/unreported.bin", 3_000)
        try await Task.sleep(nanoseconds: 300_000_000)
        let baseline = try #require(IncrementalScan.baselineAfterFullScan(
            root: f.root, eventIDAtStart: FSEventHistory.currentEventID(), deniedPaths: []))
        try f.cache.save(tree: result.tree, baseline: baseline)
        var policy = IncrementalScan.Policy()
        policy.spotChecks = 1_000   // every folder in the fixture
        guard case .fullScanNeeded(let reason) = await IncrementalScan.update(root: f.root, cache: f.cache, policy: policy) else {
            Issue.record("an unreported change slipped through"); return
        }
        #expect(reason.contains("spot check"))
    }

    /// A folder the full walk could not open stays reported after an
    /// update that never touched it, and clears once it becomes readable.
    @Test func unreadableFoldersCarryAcrossUpdates() async throws {
        let f = try Fixture()
        let secret = f.root.appendingPathComponent("keep/secret")
        try FileManager.default.createDirectory(at: secret, withIntermediateDirectories: true)
        try Data([1]).write(to: secret.appendingPathComponent("hidden.bin"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: secret.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: secret.path) }
        let full = try await f.fullScanAndSave()
        #expect(full.deniedDirectoryIDs.count == 1)

        try f.put("a/unrelated.txt", 10)
        guard case .updated(let update) = await IncrementalScan.update(root: f.root, cache: f.cache) else {
            Issue.record("update refused"); return
        }
        #expect(update.deniedDirectoryIDs.map { update.tree.path(of: $0, root: f.root).path } == [secret.path])
        try f.cache.save(tree: update.tree, baseline: update.baseline)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: secret.path)
        try f.put("keep/secret/now-visible.bin", 10)
        guard case .updated(let second) = await IncrementalScan.update(root: f.root, cache: f.cache) else {
            Issue.record("second update refused"); return
        }
        #expect(second.deniedDirectoryIDs.isEmpty)
        let fresh = await ScanEngine().scan(root: f.root)
        #expect(Self.signature(second.tree, root: f.root) == Self.signature(fresh.tree, root: f.root))
    }

    @Test func eventPathsNormalise() {
        #expect(FSEventHistory.normalized("/System/Volumes/Data/Users/x/") == "/Users/x")
        #expect(FSEventHistory.normalized("/") == "/")
        #expect(FSEventHistory.realPath("/var") == "/private/var")
    }

    /// Regression: the first name interned into a tree decoded from a
    /// snapshot used to loop forever (the rebuilt intern table was sized for
    /// 1 024 names, not the hundreds of thousands already present).
    @Test func addingToADecodedTreeTerminates() throws {
        var tree = FileTree()
        let root = tree.addNode(name: "r", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        for i in 0..<5_000 {
            tree.addNode(name: "n\(i)", parent: root, isDirectory: false, logicalSize: 1, allocatedSize: 1, modifiedDaysSinceEpoch: 1)
        }
        var decoded = try SnapshotCodec.decode(SnapshotCodec.encode(DiskSnapshot(rootPath: "/r", capturedAt: Date(), tree: tree))).tree
        let added = decoded.addNode(name: "brand-new", parent: 0, isDirectory: false, logicalSize: 1, allocatedSize: 1, modifiedDaysSinceEpoch: 1)
        #expect(decoded.name(of: added) == "brand-new")
        let reused = decoded.addNode(name: "n42", parent: 0, isDirectory: false, logicalSize: 1, allocatedSize: 1, modifiedDaysSinceEpoch: 1)
        #expect(decoded.nameIndex[Int(reused)] == tree.nameIndex[43], "existing names are found, not duplicated")
    }
}
