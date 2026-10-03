import Foundation
import Testing
@testable import DiskMapCore

/// TASK-077 — clone families read during the scan count once in the
/// allocated totals. Real `cp -c` clones on the real (APFS) temp volume,
/// never a mock: the facts come from the kernel.
@Suite("Clone-aware scan")
struct CloneScanTests {

    final class Fixture {
        let root: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("diskmap-clonescan-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        /// 5 × 16 KiB of distinct blocks.
        @discardableResult
        func original(_ rel: String) throws -> URL {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var payload = Data()
            for block in 0..<5 { payload.append(Data(repeating: UInt8(0x40 + block), count: 16_384)) }
            try payload.write(to: url)
            return url
        }

        @discardableResult
        func clone(_ source: String, _ rel: String) throws -> URL {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let cp = Process()
            cp.executableURL = URL(fileURLWithPath: "/bin/cp")
            cp.arguments = ["-c", root.appendingPathComponent(source).path, url.path]
            try cp.run()
            cp.waitUntilExit()
            #expect(cp.terminationStatus == 0)
            return url
        }

        /// Rewrites one block and waits for it to reach the disk, so the
        /// volume already reports the copy-on-write split.
        func edit(_ rel: String) throws {
            let handle = try FileHandle(forWritingTo: root.appendingPathComponent(rel))
            try handle.seek(toOffset: 16_384)
            try handle.write(contentsOf: Data(repeating: 0xEE, count: 16_384))
            try handle.synchronize()
            try handle.close()
        }

        func scan(_ mode: SharingMode) async -> FileTree {
            await ScanEngine().scan(root: root, sharing: mode).tree
        }
    }

    private static func node(_ tree: FileTree, _ name: String) -> Int32? {
        (0..<tree.count).first { tree.name(of: Int32($0)) == name }.map(Int32.init)
    }

    @Test func aThreeCloneFamilyCountsOnce() async throws {
        let f = try Fixture()
        let a = try f.original("a.bin")
        try f.clone("a.bin", "b.bin")
        try f.clone("a.bin", "c.bin")
        var info = stat()
        #expect(lstat(a.path, &info) == 0)
        let onDisk = Int64(info.st_blocks) * 512

        let off = await f.scan(.off)
        #expect(off.hasSharingInfo == false)
        #expect(off.sharing.isEmpty)
        #expect(off.rollUpBoth().allocated[0] == onDisk * 3, "without clone accounting every copy counts")

        let tree = await f.scan(.refcount)
        #expect(tree.hasSharingInfo)
        #expect(tree.sharing.count == 3)
        let both = tree.rollUpBoth()
        #expect(both.allocated[0] == onDisk)
        #expect(both.logical[0] == 3 * 81_920, "logical basis is what the files say, clones or not")
        #expect(tree.rollUpSizes(basis: .allocated)[0] == onDisk)
        let correction = tree.sharingCorrection()
        #expect(correction.familyCount == 1)
        #expect(correction.cloneCount == 2)
        #expect(correction.bytes == onDisk * 2)
        let b = try #require(Self.node(tree, "b.bin"))
        #expect(tree.sharingInfo(of: b)?.otherCopies == 2)
        #expect(tree.sharingInfo(of: b)?.sharedBytes == onDisk)
    }

    @Test func aFamilySplitAcrossFoldersElectsOneStableMember() async throws {
        let f = try Fixture()
        try f.original("one/a.bin")
        try f.clone("one/a.bin", "two/b.bin")
        try f.clone("one/a.bin", "three/c.bin")
        let tree = await f.scan(.refcount)
        let totals = tree.rollUpBoth().allocated
        let folders = ["one", "two", "three"].compactMap { Self.node(tree, $0) }
        let charged = folders.filter { totals[Int($0)] > 0 }
        #expect(charged.count == 1, "exactly one folder carries the family's blocks")
        #expect(totals[0] == totals[Int(charged[0])])
        // The electee is the lowest inode, whatever order the walk produced.
        let members = ["a.bin", "b.bin", "c.bin"].compactMap { Self.node(tree, $0) }
        let lowest = try #require(members.min { tree.fileID[Int($0)] < tree.fileID[Int($1)] })
        #expect(totals[Int(lowest)] > 0)
        // Same answer on a second scan.
        let again = await f.scan(.refcount)
        let againTotals = again.rollUpBoth().allocated
        let againCharged = ["one", "two", "three"].compactMap { Self.node(again, $0) }.filter { againTotals[Int($0)] > 0 }
        #expect(againCharged.map { again.name(of: $0) } == charged.map { tree.name(of: $0) })
    }

    @Test func anEditedCloneCountsInFullAndIsReported() async throws {
        let f = try Fixture()
        let a = try f.original("a.bin")
        try f.clone("a.bin", "b.bin")
        try f.clone("a.bin", "edited.bin")
        try f.edit("edited.bin")
        var info = stat()
        #expect(lstat(a.path, &info) == 0)
        let onDisk = Int64(info.st_blocks) * 512

        let tree = await f.scan(.full)
        let correction = tree.sharingCorrection()
        #expect(correction.familyCount == 1, "a and b are still one family")
        #expect(correction.partialCount == 1, "the edited copy shares blocks nobody in its family names")
        #expect(correction.partialSharedBytes == onDisk - 16_384)
        // a + b once, the edited copy in full: its shared blocks are reported, not guessed away.
        #expect(tree.rollUpBoth().allocated[0] == onDisk * 2)

        // The refcount-only request cannot see the edited copy; it counts in full there too.
        let light = await f.scan(.refcount)
        #expect(light.sharing.count == 2)
        #expect(light.rollUpBoth().allocated[0] == onDisk * 2)
    }

    @Test func aHardLinkedCloneCountsOnce() async throws {
        let f = try Fixture()
        let a = try f.original("a.bin")
        let b = try f.clone("a.bin", "b.bin")
        #expect(link(b.path, f.root.appendingPathComponent("b-link.bin").path) == 0)
        var info = stat()
        #expect(lstat(a.path, &info) == 0)
        let onDisk = Int64(info.st_blocks) * 512

        let tree = await f.scan(.refcount)
        #expect(tree.sharing.count == 3, "both names of b carry b's clone facts")
        #expect(tree.rollUpBoth().allocated[0] == onDisk)
        #expect(tree.sharingCorrection().cloneCount == 1, "b is one member however many names it has")
    }

    @Test func ordinaryFilesAddNoRows() async throws {
        let f = try Fixture()
        try f.original("a.bin")
        try Data(repeating: 7, count: 300_000).write(to: f.root.appendingPathComponent("plain.bin"))
        let tree = await f.scan(.full)
        #expect(tree.hasSharingInfo)
        #expect(tree.sharing.isEmpty)
        #expect(tree.sharingCorrection().isEmpty)
    }

    @Test func theTableSurvivesTheSnapshotCodec() async throws {
        let f = try Fixture()
        try f.original("a.bin")
        try f.clone("a.bin", "b.bin")
        let tree = await f.scan(.refcount)
        let decoded = try SnapshotCodec.decode(SnapshotCodec.encode(DiskSnapshot(rootPath: f.root.path, capturedAt: Date(), tree: tree)))
        #expect(decoded.tree.hasSharingInfo)
        #expect(decoded.tree.sharing == tree.sharing)
        #expect(decoded.tree.rollUpBoth().allocated == tree.rollUpBoth().allocated)
        let b = try #require(Self.node(decoded.tree, "b.bin"))
        #expect(decoded.tree.flags[Int(b)] & NodeFlags.apfsClone != 0)
    }

    @Test func aMalformedTableIsRejected() {
        var tree = FileTree()
        _ = tree.addNode(name: "r", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "x", parent: 0, isDirectory: false, logicalSize: 1, allocatedSize: 1, modifiedDaysSinceEpoch: 0)
        let outOfRange = SharingTable(node: [5], cloneID: [1], privateBytes: [0], refcount: [2])
        let unsorted = SharingTable(node: [1, 1], cloneID: [1, 1], privateBytes: [0, 0], refcount: [2, 2])
        #expect(tree.replaceSharing(try! #require(outOfRange), hasSharingInfo: true) == false)
        #expect(tree.replaceSharing(try! #require(unsorted), hasSharingInfo: true) == false)
        #expect(SharingTable(node: [1], cloneID: [], privateBytes: [0], refcount: [2]) == nil)
    }

    @Test func aQuickRescanKeepsTheTable() async throws {
        let f = try Fixture()
        try f.original("keep/a.bin")
        try f.clone("keep/a.bin", "keep/b.bin")
        try f.original("other/x.bin")
        let cache = ScanCache(directory: f.root.deletingLastPathComponent().appendingPathComponent("cache-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let first = await ScanEngine().scan(root: f.root, sharing: .refcount)
        let baseline = try #require(IncrementalScan.baselineAfterFullScan(root: f.root, eventIDAtStart: first.eventIDAtStart, deniedPaths: []))
        try cache.save(tree: first.tree, baseline: baseline)

        // A new clone in a changed folder; the unchanged family is copied.
        try f.clone("other/x.bin", "other/y.bin")
        guard case .updated(let update) = await IncrementalScan.update(root: f.root, cache: cache, sharing: .refcount) else {
            Issue.record("expected a quick update"); return
        }
        let full = await ScanEngine().scan(root: f.root, sharing: .refcount)
        #expect(update.tree.hasSharingInfo)
        #expect(update.tree.sharing.count == 4)
        #expect(update.tree.rollUpBoth().allocated[0] == full.tree.rollUpBoth().allocated[0])
        #expect(update.tree.sharingCorrection() == full.tree.sharingCorrection())

        // A tree saved without clone facts cannot be updated into one with them.
        guard case .fullScanNeeded(let reason) = await IncrementalScan.update(root: f.root, cache: cache, sharing: .off) else {
            Issue.record("expected a full scan when clone accounting is turned off"); return
        }
        #expect(reason.contains("clone"))
    }
}
