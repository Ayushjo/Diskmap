import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import DiskMapCore

struct FileTreeTests {

    @Test func rollUpSizesSumsCorrectly() {
        var tree = FileTree()
        let root = tree.addNode(name: "root", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let sub = tree.addNode(name: "sub", parent: root, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "a.txt", parent: root, isDirectory: false, logicalSize: 100, allocatedSize: 100, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "b.txt", parent: sub, isDirectory: false, logicalSize: 200, allocatedSize: 200, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "c.txt", parent: sub, isDirectory: false, logicalSize: 50, allocatedSize: 50, modifiedDaysSinceEpoch: 0)

        let totals = tree.rollUpSizes()

        #expect(totals[Int(sub)] == 250)   // b.txt + c.txt
        #expect(totals[Int(root)] == 350)  // a.txt + sub's subtree
    }

    @Test func rollUpBothMatchesSeparateRollups() {
        var tree = FileTree()
        let root = tree.addNode(name: "root", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let sub = tree.addNode(name: "sub", parent: root, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "a.txt", parent: root, isDirectory: false, logicalSize: 100, allocatedSize: 4096, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "b.txt", parent: sub, isDirectory: false, logicalSize: 200, allocatedSize: 8192, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(
            name: "cloud",
            parent: sub,
            isDirectory: false,
            logicalSize: 50,
            allocatedSize: 0,
            modifiedDaysSinceEpoch: 0,
            flags: NodeFlags.notDownloaded
        )

        let both = tree.rollUpBoth()
        #expect(both.logical == tree.rollUpSizes(basis: .logical))
        #expect(both.allocated == tree.rollUpSizes(basis: .allocated))
    }

    @Test func logicalRollupKeepsCloudSizeWhenAllocatedIsZero() {
        var tree = FileTree()
        let root = tree.addNode(name: "root", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let folder = tree.addNode(name: "Cloud", parent: root, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let evicted = tree.addNode(
            name: "note",
            parent: folder,
            isDirectory: false,
            logicalSize: 135_699,
            allocatedSize: 0,
            modifiedDaysSinceEpoch: 0,
            flags: NodeFlags.notDownloaded
        )
        _ = tree.addNode(name: "local.txt", parent: folder, isDirectory: false, logicalSize: 100, allocatedSize: 4096, modifiedDaysSinceEpoch: 0)

        let logical = tree.rollUpSizes(basis: .logical)
        let allocated = tree.rollUpSizes(basis: .allocated)

        #expect(logical[Int(evicted)] == 135_699)
        #expect(allocated[Int(evicted)] == 0)
        #expect(logical[Int(folder)] == 135_799)
        #expect(allocated[Int(folder)] == 4096)
        #expect(logical[Int(root)] == logical[Int(folder)])
        #expect(allocated[Int(root)] == allocated[Int(folder)])
    }

    @Test func evictedDirectoryContributesItsOwnSizeWhenNotDescended() {
        var tree = FileTree()
        let root = tree.addNode(name: "root", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let evictedDir = tree.addNode(
            name: "Offloaded",
            parent: root,
            isDirectory: true,
            logicalSize: 8_000,
            allocatedSize: 0,
            modifiedDaysSinceEpoch: 0,
            flags: NodeFlags.notDownloaded
        )

        #expect(tree.rollUpSizes(basis: .logical)[Int(evictedDir)] == 8_000)
        #expect(tree.rollUpSizes(basis: .allocated)[Int(evictedDir)] == 0)
        #expect(tree.rollUpSizes(basis: .logical)[Int(root)] == 8_000)
    }

    @Test func nameInterningDeduplicatesRepeatedNames() {
        var tree = FileTree()
        let root = tree.addNode(name: "root", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "node_modules", parent: root, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "node_modules", parent: root, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)

        // Both nodes should point at the SAME interned string entry,
        // proving we didn't allocate "node_modules" twice.
        #expect(tree.nameTable.filter { $0 == "node_modules" }.count == 1)
    }

    @Test func ancestorChainIsRootFirstAndStopsAtRoot() {
        var tree = FileTree()
        let root = tree.addNode(name: "root", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let mid = tree.addNode(name: "mid", parent: root, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let leaf = tree.addNode(name: "leaf", parent: mid, isDirectory: false, logicalSize: 1, allocatedSize: 1, modifiedDaysSinceEpoch: 0)

        #expect(tree.ancestorIDs(of: leaf) == [root, mid, leaf])
        #expect(tree.ancestorIDs(of: root) == [root])
    }
}

struct SquarifiedTreemapTests {

    @Test func layoutCoversFullAreaWithoutOverlap() {
        let items: [(id: Int32, size: Int64)] = [
            (0, 6), (1, 6), (2, 4), (3, 3), (4, 2), (5, 2), (6, 1)
        ]
        let bounds = CGRect(x: 0, y: 0, width: 6, height: 4)
        let rects = SquarifiedTreemap.layout(items: items, in: bounds)

        #expect(tilingError(rects, itemCount: items.count, in: bounds) == nil)
    }

    /// Paper section 3.1 / Figure 3: sizes [6, 6, 4, 3, 2, 2, 1] in a 6×4
    /// rect. Row membership is the paper's ([6, 6], [4, 3], [2], [2], [1]).
    /// The old `shortSide²` aspect-ratio formula wrongly merged the last
    /// two 2s into one row; this locks the corrected split.
    @Test func paperReferenceLayout() {
        let items: [(id: Int32, size: Int64)] = [
            (6, 1), (0, 6), (4, 2), (1, 6), (2, 4), (3, 3), (5, 2)
        ]
        let rects = SquarifiedTreemap.layout(items: items, in: CGRect(x: 0, y: 0, width: 6, height: 4))
        let byID = Dictionary(uniqueKeysWithValues: rects.map { ($0.id, $0.rect) })

        let expected: [Int32: CGRect] = [
            0: CGRect(x: 0, y: 0, width: 3, height: 2),
            1: CGRect(x: 0, y: 2, width: 3, height: 2),
            2: CGRect(x: 3, y: 0, width: 12.0 / 7.0, height: 7.0 / 3.0),
            3: CGRect(x: 3 + 12.0 / 7.0, y: 0, width: 9.0 / 7.0, height: 7.0 / 3.0),
            4: CGRect(x: 3, y: 7.0 / 3.0, width: 6.0 / 5.0, height: 5.0 / 3.0),
            5: CGRect(x: 3 + 6.0 / 5.0, y: 7.0 / 3.0, width: 6.0 / 5.0, height: 5.0 / 3.0),
            6: CGRect(x: 3 + 12.0 / 5.0, y: 7.0 / 3.0, width: 3.0 / 5.0, height: 5.0 / 3.0),
        ]

        #expect(byID.count == expected.count)
        for (id, want) in expected {
            #expect(byID[id] != nil, "missing rect for id \(id)")
            if let got = byID[id] {
                #expect(rectsMatch(got, want), "id \(id): got \(got) want \(want)")
            }
        }
    }

    /// Short side is the width, so the first row is a horizontal strip.
    /// Guards the orientation branch the 6×4 example never takes.
    @Test func tallRectangleLaysFirstRowHorizontally() {
        let items: [(id: Int32, size: Int64)] = [
            (0, 6), (1, 6), (2, 4), (3, 3), (4, 2), (5, 2), (6, 1)
        ]
        let bounds = CGRect(x: 10, y: 20, width: 4, height: 6)
        let rects = SquarifiedTreemap.layout(items: items, in: bounds)
        let byID = Dictionary(uniqueKeysWithValues: rects.map { ($0.id, $0.rect) })

        #expect(rectsMatch(byID[0]!, CGRect(x: 10, y: 20, width: 2, height: 3)))
        #expect(rectsMatch(byID[1]!, CGRect(x: 12, y: 20, width: 2, height: 3)))
        #expect(tilingError(rects, itemCount: items.count, in: bounds) == nil)
    }

    @Test func singleItemFillsWholeRect() {
        let rects = SquarifiedTreemap.layout(items: [(0, 100)], in: CGRect(x: 2, y: 3, width: 50, height: 20))
        #expect(rects.count == 1)
        #expect(rects[0].rect == CGRect(x: 2, y: 3, width: 50, height: 20))
    }

    @Test func emptyItemsProducesNoRects() {
        #expect(SquarifiedTreemap.layout(items: [], in: CGRect(x: 0, y: 0, width: 50, height: 20)).isEmpty)
    }

    @Test func hitTestReturnsTheRectangleContainingThePoint() {
        let items: [(id: Int32, size: Int64)] = [(10, 6), (11, 6), (12, 4)]
        let rects = SquarifiedTreemap.layout(items: items, in: CGRect(x: 0, y: 0, width: 6, height: 4))
        let interior = rects[0].rect.origin
        #expect(SquarifiedTreemap.hitTest(rects, at: CGPoint(x: interior.x + 0.1, y: interior.y + 0.1)) == rects[0].id)
        #expect(SquarifiedTreemap.hitTest(rects, at: CGPoint(x: -1, y: -1)) == nil)
    }

    @Test func nonPositiveSizesAreDropped() {
        let rects = SquarifiedTreemap.layout(
            items: [(0, 0), (1, 4), (2, -3)],
            in: CGRect(x: 0, y: 0, width: 8, height: 2)
        )
        #expect(rects.count == 1)
        #expect(rects[0].id == 1)
        #expect(rects[0].rect == CGRect(x: 0, y: 0, width: 8, height: 2))
    }
}

private func tilingError(_ rects: [TreemapRect], itemCount: Int, in bounds: CGRect) -> String? {
    if rects.count != itemCount {
        return "expected \(itemCount) rects, got \(rects.count)"
    }

    let accuracy = 1e-6
    var totalArea = 0.0
    for rect in rects {
        let r = rect.rect
        if r.width <= 0 || r.height <= 0 {
            return "id \(rect.id) has non-positive size \(r)"
        }
        if r.minX < bounds.minX - accuracy || r.minY < bounds.minY - accuracy
            || r.maxX > bounds.maxX + accuracy || r.maxY > bounds.maxY + accuracy {
            return "id \(rect.id) escapes bounds: \(r)"
        }
        totalArea += Double(r.width) * Double(r.height)
    }

    for i in rects.indices {
        for j in rects.indices where j > i {
            let overlap = rects[i].rect.intersection(rects[j].rect)
            if overlap.isNull || overlap.isInfinite { continue }
            let area = Double(overlap.width) * Double(overlap.height)
            if area > accuracy {
                return "ids \(rects[i].id) and \(rects[j].id) overlap by \(area)"
            }
        }
    }

    let expectedArea = Double(bounds.width) * Double(bounds.height)
    if abs(totalArea - expectedArea) > accuracy {
        return "area \(totalArea) != bounds \(expectedArea)"
    }
    return nil
}

private func rectsMatch(_ got: CGRect, _ want: CGRect, accuracy: CGFloat = 1e-6) -> Bool {
    abs(got.minX - want.minX) <= accuracy
        && abs(got.minY - want.minY) <= accuracy
        && abs(got.width - want.width) <= accuracy
        && abs(got.height - want.height) <= accuracy
}

struct CloneDetectorTests {
    @Test func clonePairMatchesAndIndependentCopyDoesNot() throws {
        let fixture = try CloneFixture()
        defer { fixture.tearDown() }

        #expect(fixture.inode(fixture.original) != fixture.inode(fixture.clone))
        #expect(CloneDetector.areLikelyClones(fixture.original, fixture.clone))
        #expect(!CloneDetector.areLikelyClones(fixture.original, fixture.unrelated))
        #expect(!CloneDetector.areLikelyClones(fixture.original, fixture.directory + "/missing.bin"))
    }

    @Test func overwrittenCloneIsNotAFullExtentMatch() throws {
        let fixture = try CloneFixture()
        defer { fixture.tearDown() }

        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: fixture.clone))
        try handle.seek(toOffset: 1_048_576)
        try handle.write(contentsOf: Data(repeating: 0x22, count: 4096))
        try handle.close()

        #expect(!CloneDetector.areLikelyClones(fixture.original, fixture.clone))
    }
}

private struct CloneCopyFailed: Error {
    var status: Int32
}

private struct CloneFixture {
    let directory: String
    let original: String
    let clone: String
    let unrelated: String

    init() throws {
        directory = NSTemporaryDirectory() + "DiskMap-clone-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        original = directory + "/original.bin"
        clone = directory + "/clone.bin"
        unrelated = directory + "/unrelated.bin"
        let bytes = Data(repeating: 0xAB, count: 8_388_608)
        FileManager.default.createFile(atPath: original, contents: bytes)
        FileManager.default.createFile(atPath: unrelated, contents: bytes)

        let cp = Process()
        cp.executableURL = URL(fileURLWithPath: "/bin/cp")
        cp.arguments = ["-c", original, clone]
        try cp.run()
        cp.waitUntilExit()
        if cp.terminationStatus != 0 {
            throw CloneCopyFailed(status: cp.terminationStatus)
        }
    }

    func tearDown() {
        try? FileManager.default.removeItem(atPath: directory)
    }

    func inode(_ path: String) -> ino_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_ino
    }
}
