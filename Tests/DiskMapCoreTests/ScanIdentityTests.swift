import Foundation
import Testing
@testable import DiskMapCore

/// TASK-036 — the scan now records file identity. Before this, `FileTree` was
/// path-only, so nothing downstream could tell two names for one inode apart.
/// Offsets are measured by the `AttrProbe` target; these tests are the
/// behavioural guard that the measured layout is actually being read correctly.
@Suite("Scan identity")
struct ScanIdentityTests {

    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskmap-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The whole point of the ticket: a real inode number reaches `FileTree`.
    /// A wrong offset would surface here as 0 or as garbage that disagrees
    /// with `lstat`.
    @Test func scanRecordsFileIDMatchingLstat() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("payload.bin")
        try Data(repeating: 0x5A, count: 3_333).write(to: file)

        var st = stat()
        #expect(lstat(file.path, &st) == 0)
        let expectedInode = UInt64(st.st_ino)

        let result = await ScanEngine().scan(root: root)
        let tree = result.tree

        var found: UInt64?
        for id in 0..<Int32(tree.count) where tree.name(of: id) == "payload.bin" {
            found = tree.fileID[Int(id)]
        }
        #expect(found == expectedInode)
        #expect(found != 0)
        // Sizes must still be read correctly after every offset moved.
        for id in 0..<Int32(tree.count) where tree.name(of: id) == "payload.bin" {
            #expect(tree.logicalSize[Int(id)] == 3_333)
        }
    }

    /// Two names, one inode. Both nodes carry the same fileID and both are
    /// flagged, which is what TASK-037's rollup correction keys on.
    /// `NodeFlags.hardLink` was declared but never set before this ticket.
    @Test func hardLinkedFilesShareFileIDAndAreFlagged() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let original = root.appendingPathComponent("original.bin")
        try Data(repeating: 0x11, count: 2_048).write(to: original)
        let second = root.appendingPathComponent("second-name.bin")
        #expect(link(original.path, second.path) == 0)

        let result = await ScanEngine().scan(root: root)
        let tree = result.tree

        var ids: [Int32] = []
        for id in 0..<Int32(tree.count) {
            let name = tree.name(of: id)
            if name == "original.bin" || name == "second-name.bin" { ids.append(id) }
        }
        #expect(ids.count == 2)

        let fileIDs = Set(ids.map { tree.fileID[Int($0)] })
        #expect(fileIDs.count == 1, "both names must resolve to one inode")
        #expect(fileIDs.first != 0)

        for id in ids {
            #expect(tree.flags[Int(id)] & NodeFlags.hardLink != 0)
        }
        #expect(result.hardLinkCount == 2)
    }

    /// A file with one name must NOT be flagged — otherwise the rollup
    /// correction would walk every node on the volume.
    @Test func ordinaryFileIsNotFlaggedAsHardLink() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x22, count: 512).write(to: root.appendingPathComponent("solo.bin"))

        let result = await ScanEngine().scan(root: root)
        let tree = result.tree
        for id in 0..<Int32(tree.count) where tree.name(of: id) == "solo.bin" {
            #expect(tree.flags[Int(id)] & NodeFlags.hardLink == 0)
        }
        #expect(result.hardLinkCount == 0)
    }

    /// Directories must never be flagged. ATTR_DIR_LINKCOUNT is requested only
    /// to keep the record layout symmetric and reads 1 on APFS regardless of
    /// child count (docs/perf-results/attr-probe.txt), so trusting it would be
    /// a bug either way.
    @Test func directoriesAreNeverFlaggedAsHardLinks() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("parent")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for i in 0..<4 {
            try FileManager.default.createDirectory(
                at: nested.appendingPathComponent("child\(i)"), withIntermediateDirectories: true)
        }

        let result = await ScanEngine().scan(root: root)
        let tree = result.tree
        for id in 0..<Int32(tree.count) where tree.isDirectory[Int(id)] {
            #expect(tree.flags[Int(id)] & NodeFlags.hardLink == 0)
        }
    }

    /// A scan of a plain directory has nothing to skip. The counter existing
    /// and reading 0 is what tells Overview the totals are complete.
    @Test func ordinaryScanSkipsNoMounts() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x33, count: 64).write(to: root.appendingPathComponent("a.bin"))

        let result = await ScanEngine().scan(root: root)
        #expect(result.crossMountSkipCount == 0)
    }

    /// The home scan must not pay for firmlink-twin detection it can never hit.
    @Test func firmlinkTwinCheckOnlyAppliesToSystemRoots() {
        #expect(CanonicalPath.mayContainFirmlinkTwins(scanRootPath: "/") == true)
        #expect(CanonicalPath.mayContainFirmlinkTwins(scanRootPath: "/System/Volumes") == true)
        #expect(CanonicalPath.mayContainFirmlinkTwins(scanRootPath: "/System/Volumes/Data") == true)
        #expect(CanonicalPath.mayContainFirmlinkTwins(scanRootPath: NSHomeDirectory()) == false)
        #expect(CanonicalPath.mayContainFirmlinkTwins(scanRootPath: "/Users/alex") == false)
        #expect(CanonicalPath.mayContainFirmlinkTwins(scanRootPath: "/Volumes/External") == false)
    }

    /// The optimisation must not change behaviour: wherever the cheap gate
    /// says "possible", the real check still decides.
    @Test func firmlinkGateNeverHidesARealSkip() {
        let twins = CanonicalPath.dataVolumeFirmlinkSuffixes
        for path in twins {
            #expect(CanonicalPath.shouldSkipDescend(absolutePath: path, scanRootPath: "/") == true)
            #expect(CanonicalPath.mayContainFirmlinkTwins(scanRootPath: "/") == true)
        }
    }
}

/// TASK-036 — the snapshot format carries identity from v3 on, and older
/// files on disk must keep opening.
@Suite("Snapshot identity round-trip")
struct SnapshotIdentityTests {

    private func sampleTree() -> FileTree {
        var tree = FileTree()
        _ = tree.addNode(name: "root", parent: -1, isDirectory: true,
                         logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "a.bin", parent: 0, isDirectory: false,
                         logicalSize: 100, allocatedSize: 100, modifiedDaysSinceEpoch: 5,
                         createdDaysSinceEpoch: 4, flags: NodeFlags.hardLink, fileID: 987_654_321)
        _ = tree.addNode(name: "b.bin", parent: 0, isDirectory: false,
                         logicalSize: 100, allocatedSize: 100, modifiedDaysSinceEpoch: 5,
                         createdDaysSinceEpoch: 4, flags: NodeFlags.hardLink, fileID: 987_654_321)
        return tree
    }

    @Test func fileIDSurvivesEncodeDecode() throws {
        let snapshot = DiskSnapshot(rootPath: "/tmp/x", capturedAt: Date(), tree: sampleTree())
        let decoded = try SnapshotCodec.decode(SnapshotCodec.encode(snapshot))
        #expect(decoded.tree.count == 3)
        #expect(decoded.tree.fileID[1] == 987_654_321)
        #expect(decoded.tree.fileID[2] == 987_654_321)
        #expect(decoded.tree.flags[1] & NodeFlags.hardLink != 0)
    }

    /// A v3 writer must still produce something the header reader accepts —
    /// `readHeader` has its own version gate, separate from `decode`'s.
    @Test func headerReadsCurrentVersion() throws {
        let snapshot = DiskSnapshot(rootPath: "/tmp/y", capturedAt: Date(), tree: sampleTree())
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskmap-hdr-\(UUID().uuidString).dmap")
        defer { try? FileManager.default.removeItem(at: url) }
        try SnapshotCodec.encode(snapshot).write(to: url)
        let header = try SnapshotStore.readHeader(from: url)
        #expect(header.rootPath == "/tmp/y")
    }

    /// Guard the compatibility promise directly: a payload whose version byte
    /// says v2 (no fileID array) still decodes, with identity reading 0.
    @Test func versionTwoPayloadStillDecodesWithUnknownIdentity() throws {
        // Build a v2 body by hand: same field order as v3 minus the fileID run.
        var tree = FileTree()
        _ = tree.addNode(name: "root", parent: -1, isDirectory: true,
                         logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "old.bin", parent: 0, isDirectory: false,
                         logicalSize: 42, allocatedSize: 42, modifiedDaysSinceEpoch: 7)

        var data = Data("DMAP".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func i32(_ v: Int32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func i64(_ v: Int64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func str(_ s: String) { let b = Array(s.utf8); u32(UInt32(b.count)); data.append(contentsOf: b) }

        u32(2)                              // version 2
        i64(Int64(Date().timeIntervalSince1970))
        str("/tmp/legacy")
        i32(Int32(tree.count))
        i32(Int32(tree.uniqueNameCount))
        tree.nameIndex.forEach(i32); tree.parent.forEach(i32)
        tree.firstChild.forEach(i32); tree.nextSibling.forEach(i32)
        tree.logicalSize.forEach(i64); tree.allocatedSize.forEach(i64)
        tree.modifiedDay.forEach(i32); tree.createdDay.forEach(i32)
        data.append(contentsOf: tree.isDirectory.map { $0 ? UInt8(1) : 0 })
        data.append(contentsOf: tree.flags)
        // no fileID run in v2
        for name in tree.nameTable { str(name) }

        let decoded = try SnapshotCodec.decode(data)
        #expect(decoded.rootPath == "/tmp/legacy")
        #expect(decoded.tree.count == 2)
        #expect(decoded.tree.fileID.count == 2)
        #expect(decoded.tree.fileID.allSatisfy { $0 == 0 })
        #expect(decoded.tree.logicalSize[1] == 42)
    }
}
