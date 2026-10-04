import Foundation
import Testing
@testable import DiskMapCore

/// TASK-037 — rollups must not charge the same inode twice. Before this, a
/// file reachable under N names contributed N times to every ancestor total,
/// the treemap area, and every staging sum derived from them.
@Suite("Hard-link aware rollups")
struct HardLinkRollupTests {

    /// Two names for one 100-byte inode under one parent: the parent holds
    /// 100, not 200, and the tree stays internally consistent (children sum
    /// to parent) so treemap layout does not overflow its rect.
    @Test func twoNamesForOneInodeAreChargedOnce() {
        var tree = FileTree()
        _ = tree.addNode(name: "root", parent: -1, isDirectory: true,
                         logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let a = tree.addNode(name: "a.bin", parent: 0, isDirectory: false,
                             logicalSize: 100, allocatedSize: 100, modifiedDaysSinceEpoch: 1,
                             flags: NodeFlags.hardLink, fileID: 77)
        let b = tree.addNode(name: "b.bin", parent: 0, isDirectory: false,
                             logicalSize: 100, allocatedSize: 100, modifiedDaysSinceEpoch: 1,
                             flags: NodeFlags.hardLink, fileID: 77)

        let both = tree.rollUpBoth()
        #expect(both.allocated[0] == 100)
        #expect(both.logical[0] == 100)
        // "a.bin" sorts before "b.bin", so it is the elected name.
        #expect(both.allocated[Int(a)] == 100)
        #expect(both.allocated[Int(b)] == 0)
        // Internal consistency: the parent equals the sum of its children.
        #expect(both.allocated[0] == both.allocated[Int(a)] + both.allocated[Int(b)])
    }

    /// The same correction must apply across folders, which is where the
    /// double count used to be most misleading.
    @Test func namesInDifferentFoldersAreChargedOnce() {
        var tree = FileTree()
        _ = tree.addNode(name: "root", parent: -1, isDirectory: true,
                         logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let alpha = tree.addNode(name: "alpha", parent: 0, isDirectory: true,
                                 logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let beta = tree.addNode(name: "beta", parent: 0, isDirectory: true,
                                logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "big.bin", parent: alpha, isDirectory: false,
                         logicalSize: 4_000, allocatedSize: 4_096, modifiedDaysSinceEpoch: 1,
                         flags: NodeFlags.hardLink, fileID: 99)
        _ = tree.addNode(name: "big.bin", parent: beta, isDirectory: false,
                         logicalSize: 4_000, allocatedSize: 4_096, modifiedDaysSinceEpoch: 1,
                         flags: NodeFlags.hardLink, fileID: 99)

        let both = tree.rollUpBoth()
        #expect(both.allocated[0] == 4_096)
        // "alpha/big.bin" < "beta/big.bin", so alpha carries the bytes.
        #expect(both.allocated[Int(alpha)] == 4_096)
        #expect(both.allocated[Int(beta)] == 0)
    }

    /// A multiply-linked file whose other name lives OUTSIDE the scan root is
    /// not double-counted within this tree, so it must keep its full size.
    /// Suppressing it would under-report real disk usage.
    @Test func singleNameInTreeKeepsFullSizeEvenWhenFlagged() {
        var tree = FileTree()
        _ = tree.addNode(name: "root", parent: -1, isDirectory: true,
                         logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let only = tree.addNode(name: "linked-elsewhere.bin", parent: 0, isDirectory: false,
                                logicalSize: 500, allocatedSize: 512, modifiedDaysSinceEpoch: 1,
                                flags: NodeFlags.hardLink, fileID: 1_234)

        let both = tree.rollUpBoth()
        #expect(both.allocated[Int(only)] == 512)
        #expect(both.allocated[0] == 512)
        #expect(tree.hardLinkCorrection().isEmpty)
    }

    /// Distinct inodes that merely happen to be the same size must not be
    /// collapsed — that would be the clone case, which needs extent
    /// comparison, not identity, and is handled at the cleanup boundary.
    @Test func distinctInodesAreNotCollapsed() {
        var tree = FileTree()
        _ = tree.addNode(name: "root", parent: -1, isDirectory: true,
                         logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "x.bin", parent: 0, isDirectory: false,
                         logicalSize: 100, allocatedSize: 100, modifiedDaysSinceEpoch: 1,
                         flags: NodeFlags.hardLink, fileID: 1)
        _ = tree.addNode(name: "y.bin", parent: 0, isDirectory: false,
                         logicalSize: 100, allocatedSize: 100, modifiedDaysSinceEpoch: 1,
                         flags: NodeFlags.hardLink, fileID: 2)

        #expect(tree.rollUpBoth().allocated[0] == 200)
    }

    /// Trees with no identity (a v1/v2 snapshot, or any test fixture built
    /// without fileID) must behave exactly as before.
    @Test func treesWithoutIdentityAreUnchanged() {
        var tree = FileTree()
        _ = tree.addNode(name: "root", parent: -1, isDirectory: true,
                         logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "a.bin", parent: 0, isDirectory: false,
                         logicalSize: 100, allocatedSize: 100, modifiedDaysSinceEpoch: 1)
        _ = tree.addNode(name: "b.bin", parent: 0, isDirectory: false,
                         logicalSize: 100, allocatedSize: 100, modifiedDaysSinceEpoch: 1)
        #expect(tree.rollUpBoth().allocated[0] == 200)
        #expect(tree.hardLinkCorrection().isEmpty)
    }

    /// The explanatory figure Overview will show.
    @Test func correctionReportsWhatWasDeduplicated() {
        var tree = FileTree()
        _ = tree.addNode(name: "root", parent: -1, isDirectory: true,
                         logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        for name in ["a.bin", "b.bin", "c.bin"] {
            _ = tree.addNode(name: name, parent: 0, isDirectory: false,
                             logicalSize: 1_000, allocatedSize: 1_024, modifiedDaysSinceEpoch: 1,
                             flags: NodeFlags.hardLink, fileID: 42)
        }
        let correction = tree.hardLinkCorrection()
        #expect(correction.inodeCount == 1)
        #expect(correction.duplicateNameCount == 2)      // 3 names, 1 charged
        #expect(correction.allocatedBytes == 2_048)
        #expect(correction.logicalBytes == 2_000)
        #expect(tree.rollUpBoth().allocated[0] == 1_024)
    }

    /// Election must not depend on node id or sibling order, because both
    /// fall out of scan thread interleaving. Same content inserted in the
    /// opposite order must charge the same path.
    @Test func electionIsStableRegardlessOfInsertionOrder() {
        func build(reversed: Bool) -> (FileTree, Int32, Int32) {
            var tree = FileTree()
            _ = tree.addNode(name: "root", parent: -1, isDirectory: true,
                             logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
            let first = tree.addNode(name: reversed ? "zeta" : "alpha", parent: 0, isDirectory: true,
                                     logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
            let second = tree.addNode(name: reversed ? "alpha" : "zeta", parent: 0, isDirectory: true,
                                      logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
            _ = tree.addNode(name: "f.bin", parent: first, isDirectory: false,
                             logicalSize: 10, allocatedSize: 16, modifiedDaysSinceEpoch: 1,
                             flags: NodeFlags.hardLink, fileID: 7)
            _ = tree.addNode(name: "f.bin", parent: second, isDirectory: false,
                             logicalSize: 10, allocatedSize: 16, modifiedDaysSinceEpoch: 1,
                             flags: NodeFlags.hardLink, fileID: 7)
            let alpha = reversed ? second : first
            let zeta = reversed ? first : second
            return (tree, alpha, zeta)
        }

        let (t1, alpha1, zeta1) = build(reversed: false)
        let (t2, alpha2, zeta2) = build(reversed: true)
        let r1 = t1.rollUpBoth().allocated
        let r2 = t2.rollUpBoth().allocated
        // "alpha/f.bin" wins in both, whichever order the nodes were created.
        #expect(r1[Int(alpha1)] == 16)
        #expect(r1[Int(zeta1)] == 0)
        #expect(r2[Int(alpha2)] == 16)
        #expect(r2[Int(zeta2)] == 0)
        #expect(r1[0] == r2[0])
    }

    /// End-to-end against a real hard link on the real filesystem.
    @Test func realHardLinkIsCountedOnceAfterAScan() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskmap-hlroll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = Data(repeating: 0x7E, count: 200_000)
        let original = root.appendingPathComponent("movie.bin")
        try payload.write(to: original)
        #expect(link(original.path, root.appendingPathComponent("movie-copy.bin").path) == 0)

        let result = await ScanEngine().scan(root: root)
        #expect(result.hardLinkCount == 2)

        let both = result.tree.rollUpBoth()
        let correction = result.tree.hardLinkCorrection()
        #expect(correction.inodeCount == 1)
        #expect(correction.duplicateNameCount == 1)
        // The root must reflect one copy on disk, not two.
        #expect(both.logical[0] == Int64(payload.count))
    }
}
