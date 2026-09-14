import Foundation
import Testing
@testable import DiskMapCore

struct ProcessMemoryTests {
    @Test func taskInfoReturnsResidentAndPeak() throws {
        let snapshot = try #require(ProcessMemory.current())
        #expect(snapshot.residentBytes > 0)
        #expect(snapshot.peakResidentBytes >= snapshot.residentBytes)
        #expect(snapshot.virtualBytes >= snapshot.residentBytes)
    }
}

struct ScanDecisionTests {
    @Test func symlinkIsSkippedAndNotDescended() {
        let decision = ScanEngine.decide(
            isDirectory: false,
            isSymbolicLink: true,
            logicalSize: 10,
            allocatedSize: 4096,
            isUbiquitous: false,
            downloadingStatusNotDownloaded: false
        )
        #expect(decision.include == false)
        #expect(decision.skipDescendants == true)
    }

    /// Replays a captured resourceValues snapshot. CI has no iCloud
    /// account, so this must not touch a live file.
    @Test func evictedUbiquitousItemKeepsLogicalSizeAndZeroAllocated() throws {
        let snapshot = try EvictedItemSnapshot.loadFixture()
        #expect(snapshot.sfDataless == true)
        #expect(snapshot.stBlocks == 0)
        #expect(snapshot.downloadingStatus == "NSURLUbiquitousItemDownloadingStatusNotDownloaded")

        let decision = snapshot.decision()
        #expect(decision.include == true)
        #expect(decision.notDownloaded == true)
        #expect(decision.logicalSize == snapshot.fileSize)
        #expect(decision.allocatedSize == snapshot.totalFileAllocatedSize)
        #expect(decision.skipDescendants == snapshot.isDirectory)
    }

    @Test func evictedDirectoryIsRecordedButNotDescended() {
        let decision = ScanEngine.decide(
            isDirectory: true,
            isSymbolicLink: false,
            logicalSize: 0,
            allocatedSize: 0,
            isUbiquitous: true,
            downloadingStatusNotDownloaded: true
        )
        #expect(decision.include == true)
        #expect(decision.notDownloaded == true)
        #expect(decision.skipDescendants == true)
    }

    @Test func downloadedUbiquitousItemIsNotFlagged() {
        let decision = ScanEngine.decide(
            isDirectory: false,
            isSymbolicLink: false,
            logicalSize: 100,
            allocatedSize: 4096,
            isUbiquitous: true,
            downloadingStatusNotDownloaded: false
        )
        #expect(decision.notDownloaded == false)
        #expect(decision.allocatedSize == 4096)
        #expect(decision.skipDescendants == false)
    }

    /// Extra local check. GitHub Actions macOS runners are not signed into
    /// iCloud, so this must skip instead of failing when no dataless file
    /// is around. The checked-in fixture is what CI actually runs.
    @Test func liveEvictedFileMatchesDecisionIfPresent() throws {
        guard let file = LiveEvictedFileFinder.firstDatalessFile() else {
            // Graceful skip: GitHub Actions macOS runners are not signed into
            // iCloud. A failed assertion here would break CI. The checked-in
            // fixture is the required coverage.
            return
        }
        let values = try file.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemDownloadRequestedKey,
        ])
        #expect(values.ubiquitousItemDownloadRequested != true)
        let decision = ScanEngine.decide(values)
        #expect(decision.notDownloaded == true)
        #expect(decision.logicalSize == Int64(values.fileSize ?? 0))
        #expect(decision.allocatedSize == Int64(values.totalFileAllocatedSize ?? 0))
    }
}

struct FileTreeStorageTests {
    @Test func packedStrideMatchesStoredFields() {
        let stride = MemoryLayout<Int32>.stride * 5
            + MemoryLayout<Int64>.stride * 2
            + MemoryLayout<Bool>.stride
            + MemoryLayout<UInt8>.stride
        #expect(FileTree.packedNodeStride == stride)
    }

    /// Analytical packed-array size at the home-scan node count from
    /// TASK-002 (1,657,572). This is the floor the arrays can be, not RSS.
    @Test func packedBytesAtHomeScanNodeCount() {
        let nodes = 1_657_572
        #expect(FileTree.packedNodeBytesExact(nodeCount: nodes) == nodes * FileTree.packedNodeStride)
    }

    @Test func compactDropsSpareCapacityWithoutLosingLinks() {
        var tree = FileTree()
        let root = tree.addNode(name: "root", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        for i in 0..<1000 {
            _ = tree.addNode(name: "f\(i % 17)", parent: root, isDirectory: false, logicalSize: Int64(i), allocatedSize: Int64(i), modifiedDaysSinceEpoch: 0)
        }
        let before = tree.storageFootprint()
        #expect(before.packedNodeBytesReserved > before.packedNodeBytesExact)

        tree.compact()
        let after = tree.storageFootprint()
        let slackBefore = before.packedNodeBytesReserved - before.packedNodeBytesExact
        let slackAfter = after.packedNodeBytesReserved - after.packedNodeBytesExact
        #expect(slackAfter < slackBefore)
        #expect(slackAfter * 8 < slackBefore, "compact should drop doubling slack, not just a few bytes")
        #expect(after.nodeCount == before.nodeCount)
        #expect(tree.parent[Int(1)] == root)
        #expect(tree.name(of: 1) == "f0")
        #expect(tree.logicalSize[500] == 499)
    }
}

private struct EvictedItemSnapshot: Decodable {
    var isDirectory: Bool
    var isSymbolicLink: Bool
    var fileSize: Int64
    var totalFileAllocatedSize: Int64
    var isUbiquitousItem: Bool
    var downloadingStatus: String
    var stBlocks: Int64
    var sfDataless: Bool

    func decision() -> ScanEngine.ItemDecision {
        ScanEngine.decide(
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            logicalSize: fileSize,
            allocatedSize: totalFileAllocatedSize,
            isUbiquitous: isUbiquitousItem,
            downloadingStatusNotDownloaded: downloadingStatus == "NSURLUbiquitousItemDownloadingStatusNotDownloaded"
        )
    }

    static func loadFixture() throws -> EvictedItemSnapshot {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/evicted-ubiquitous-item.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(EvictedItemSnapshot.self, from: data)
    }
}

/// Shallow look under iCloud Drive. Does not create or evict anything.
/// Returns nil when iCloud isn't present so CI skips.
private enum LiveEvictedFileFinder {
    private static let sfDataless: UInt32 = 0x40000000

    static func firstDatalessFile() -> URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return nil }
        for name in names where !name.hasPrefix(".") {
            let url = root.appendingPathComponent(name)
            if isDatalessFile(url) { return url }
        }
        return nil
    }

    private static func isDatalessFile(_ url: URL) -> Bool {
        var st = stat()
        guard url.path.withCString({ lstat($0, &st) }) == 0 else { return false }
        let isFile = (st.st_mode & S_IFMT) == S_IFREG
        return isFile && (st.st_flags & sfDataless) != 0
    }
}

struct ScanEngineFixtureTests {
    @Test func fixtureCoversPermissionDeniedSymlinkAndBrokenSymlink() async throws {
        let fixture = try ScanFixture()
        defer { fixture.tearDown() }

        let result = await ScanEngine().scan(root: fixture.root)
        let tree = result.tree

        #expect(result.itemCount > 0)
        #expect(result.residentBytesAfterEnumeratorRelease != nil)
        #expect(result.peakResidentBytesDuringWalk > 0)
        #expect(result.elapsedSeconds >= 0)

        let nested = try #require(tree.node(named: "nested.txt", parentNamed: "inner"))
        #expect(tree.parent[Int(nested)] == tree.node(named: "inner", parentNamed: "outer"))

        let afterLink = try #require(tree.node(named: "after-link.txt", parentNamed: "inner"))
        #expect(tree.parent[Int(afterLink)] == tree.node(named: "inner", parentNamed: "outer"))

        let sibling = try #require(tree.node(named: "sibling.txt", parentNamed: "outer"))
        #expect(tree.parent[Int(sibling)] == tree.node(named: "outer", parentNamed: fixture.root.lastPathComponent))

        #expect(tree.node(named: "points-at-nested", parentNamed: "inner") == nil)
        #expect(tree.node(named: "broken-link", parentNamed: fixture.root.lastPathComponent) == nil)

        let denied = try #require(tree.node(named: "denied", parentNamed: fixture.root.lastPathComponent))
        #expect(tree.isDirectory[Int(denied)])
        #expect(tree.firstChild[Int(denied)] == -1, "chmod 000 directory must not contribute children")
        #expect(tree.node(named: "secret.txt", parentNamed: "denied") == nil)

        let visible = try #require(tree.node(named: "visible.txt", parentNamed: fixture.root.lastPathComponent))
        let visibleURL = fixture.root.appendingPathComponent("visible.txt")
        let visibleValues = try visibleURL.resourceValues(forKeys: [
            .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey,
        ])
        #expect(tree.logicalSize[Int(visible)] == Int64(visibleValues.fileSize ?? -1))
        #expect(tree.allocatedSize[Int(visible)] == Int64(visibleValues.totalFileAllocatedSize ?? -1))
        let day = Int32((visibleValues.contentModificationDate ?? .distantPast).timeIntervalSince1970 / 86400)
        #expect(tree.modifiedDay[Int(visible)] == day)
        // A constructed evicted placeholder is not part of this fixture.
        // SF_DATALESS is not settable from userspace, and evictUbiquitousItem
        // on a file this process created failed with NSFileProviderError -2008.
        // The decision is replayed from Tests/Fixtures/evicted-ubiquitous-item.json.
    }
}

/// Built under a temp directory, not checked in: git does not preserve
/// mode 000, and a leftover unreadable directory would break later scans
/// of the repo. `tearDown` restores permissions before deleting.
private struct ScanFixture {
    let root: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskMap-scan-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root

        let outer = root.appendingPathComponent("outer", isDirectory: true)
        let inner = outer.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: inner.appendingPathComponent("nested.txt"))
        try FileManager.default.createSymbolicLink(
            at: inner.appendingPathComponent("points-at-nested"),
            withDestinationURL: inner.appendingPathComponent("nested.txt")
        )
        try Data("after".utf8).write(to: inner.appendingPathComponent("after-link.txt"))
        try Data("sib".utf8).write(to: outer.appendingPathComponent("sibling.txt"))

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("broken-link"),
            withDestinationURL: root.appendingPathComponent("does-not-exist")
        )

        let denied = root.appendingPathComponent("denied", isDirectory: true)
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: denied.appendingPathComponent("secret.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)

        try Data("seen".utf8).write(to: root.appendingPathComponent("visible.txt"))
    }

    func tearDown() {
        let denied = root.appendingPathComponent("denied")
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denied.path)
        try? FileManager.default.removeItem(at: root)
    }
}

extension FileTree {
    func node(named name: String, parentNamed parentName: String) -> Int32? {
        for id in 0..<Int32(count) where self.name(of: id) == name {
            let parentID = parent[Int(id)]
            if parentID == -1 { continue }
            if self.name(of: parentID) == parentName { return id }
        }
        return nil
    }
}


struct SyntheticScanStressTests {
    /// Builds a bushy tree that stresses the publisher queue without needing
    /// a multi-million-file home folder in CI.
    @Test func bushyTreeScanCompletesWithExpectedNodeCount() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("diskmap-stress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 40 dirs × 25 files = 1000 files + 40 dirs + root ≈ 1041 nodes.
        for d in 0..<40 {
            let dir = root.appendingPathComponent(String(format: "d%02d", d), isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in 0..<25 {
                let file = dir.appendingPathComponent(String(format: "f%02d.txt", f))
                try Data("x".utf8).write(to: file)
            }
        }

        let result = await ScanEngine().scan(root: root)
        #expect(result.itemCount >= 1000)
        #expect(result.tree.count >= 1041)
        let both = result.tree.rollUpBoth()
        #expect(both.logical[0] >= 1000)
        #expect(both.allocated[0] >= 1000)
        #expect(result.elapsedSeconds >= 0)
    }
}

struct ExternalVolumeScanTests {
    /// Optional smoke: if /Volumes has a user-mounted volume, scan one level
    /// deep enough to prove BulkScan does not hang. Skips cleanly otherwise.
    @Test func mountedVolumeScanDoesNotHangWhenPresent() async throws {
        let volumes = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isVolumeKey]
        guard let kids = try? FileManager.default.contentsOfDirectory(
            at: volumes,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }

        let candidate = kids.first { url in
            let name = url.lastPathComponent
            guard name != "Macintosh HD" else { return false }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return values?.isDirectory == true
        }
        guard let target = candidate else { return }

        // Bound the walk: scan the volume root only through ScanEngine; if it
        // takes absurdly long the test runner will surface it. We only assert
        // the call returns and records the root.
        let result = await ScanEngine().scan(root: target)
        #expect(result.tree.count >= 1)
        #expect(result.itemCount >= 0)
    }
}


struct EdgeCaseRobustnessTests {
    /// Builds a disposable tree: combining-Unicode name, deep path, chmod 000
    /// directory, identical non-clone copies. Confirms scan + CloneDetector
    /// fallback + DuplicateFinder grouping without hanging.
    @Test func unicodeDeepDeniedAndIndependentCopies() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("diskmap-edge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let combining = "cafe\u{0301}.txt"
        try "combining\n".write(to: root.appendingPathComponent(combining), atomically: true, encoding: .utf8)

        var deep = root.appendingPathComponent("deep", isDirectory: true)
        for i in 1...25 {
            deep = deep.appendingPathComponent("d\(i)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try "leaf\n".write(to: deep.appendingPathComponent("leaf.txt"), atomically: true, encoding: .utf8)

        let denied = root.appendingPathComponent("denied/secret", isDirectory: true)
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        try "secret\n".write(to: denied.appendingPathComponent("hidden.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)

        let dups = root.appendingPathComponent("dups", isDirectory: true)
        try FileManager.default.createDirectory(at: dups, withIntermediateDirectories: true)
        let payload = Data("same-bytes-payload-for-hash\n".utf8)
        try payload.write(to: dups.appendingPathComponent("a.bin"))
        try payload.write(to: dups.appendingPathComponent("b.bin"))

        let a = dups.appendingPathComponent("a.bin").path
        let b = dups.appendingPathComponent("b.bin").path
        #expect(CloneDetector.areLikelyClones(a, b) == false)

        let result = await ScanEngine().scan(root: root)
        #expect(result.itemCount > 20)
        var sawCombining = false
        var sawLeaf = false
        var sawSecret = false
        for id in 0..<Int32(result.tree.count) {
            let name = result.tree.name(of: id)
            if name.unicodeScalars.contains(where: { $0.value == 0x0301 }) { sawCombining = true }
            if name == "leaf.txt" { sawLeaf = true }
            if name == "secret" { sawSecret = true }
        }
        #expect(sawCombining)
        #expect(sawLeaf)
        #expect(sawSecret)

        let groups = await DuplicateFinder.findDuplicates(
            candidates: DuplicateFinder.candidates(in: result.tree, root: root)
        )
        #expect(groups.contains { !$0.sharesStorage && $0.fileIDs.count == 2 })
    }

    /// Optional: when `/Volumes/DiskMapExFAT` is mounted (see
    /// `scripts/make-exfat-fixture.sh`), confirm CloneDetector returns false
    /// and a scan does not hang.
    @Test func exFATVolumeCloneDetectorFailsCleanlyWhenPresent() async throws {
        // Prefer RAM-disk fixture from scripts/make-exfat-fixture.sh (/Volumes/DISKMAP).
        let candidates = [
            URL(fileURLWithPath: "/Volumes/DISKMAP", isDirectory: true),
            URL(fileURLWithPath: "/Volumes/DiskMapExFAT", isDirectory: true),
        ]
        var vol: URL?
        for candidate in candidates {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                vol = candidate
                break
            }
        }
        guard let vol else { return } // skip — no fixture volume
        let a = vol.appendingPathComponent("edge-cases/dups/a.bin")
        let b = vol.appendingPathComponent("edge-cases/dups/b.bin")
        if FileManager.default.fileExists(atPath: a.path), FileManager.default.fileExists(atPath: b.path) {
            #expect(CloneDetector.areLikelyClones(a.path, b.path) == false)
        }
        let result = await ScanEngine().scan(root: vol.appendingPathComponent("edge-cases", isDirectory: true))
        #expect(result.itemCount > 0)
        #expect(result.elapsedSeconds < 120)
    }
}

