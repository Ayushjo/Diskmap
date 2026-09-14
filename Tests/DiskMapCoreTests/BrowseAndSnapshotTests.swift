import Foundation
import Testing
@testable import DiskMapCore

struct BrowseQueryTests {
    @Test func topSizesSkipsRootAndCaps() {
        let totals: [Int64] = [100, 5, 40, 1, 90]
        #expect(TopSizes.ranked(totals: totals, limit: 2) == [4, 2])
    }

    @Test func ageBucketsAndUntouchedUseAFixedToday() {
        let today: Int32 = 20_000
        #expect(AgeMap.bucket(modifiedDay: 0, today: today) == .unknown)
        #expect(AgeMap.bucket(modifiedDay: today - 10, today: today) == .under30)
        #expect(AgeMap.bucket(modifiedDay: today - 40, today: today) == .days30to90)
        #expect(AgeMap.bucket(modifiedDay: today - 200, today: today) == .days90to365)
        #expect(AgeMap.bucket(modifiedDay: today - 400, today: today) == .oneToTwoYears)
        #expect(AgeMap.bucket(modifiedDay: today - 800, today: today) == .overTwoYears)
        #expect(AgeBucket.oneToTwoYears.shortTitle == "1–2y")
        #expect(AgeBucket.overTwoYears.shortTitle == "2y+")
        #expect(AgeBucket.unknown.shortTitle == "No date")
        #expect(AgeBucket.unknown.title == "No date")

        var tree = FileTree()
        let root = tree.addNode(name: "root", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let huge = tree.addNode(name: "huge.bin", parent: root, isDirectory: false, logicalSize: 9_000, allocatedSize: 9_000, modifiedDaysSinceEpoch: today - 400)
        let small = tree.addNode(name: "small.bin", parent: root, isDirectory: false, logicalSize: 10, allocatedSize: 10, modifiedDaysSinceEpoch: today - 800)
        _ = tree.addNode(name: "recent.bin", parent: root, isDirectory: false, logicalSize: 50_000, allocatedSize: 50_000, modifiedDaysSinceEpoch: today - 3)
        _ = tree.addNode(name: "folder", parent: root, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: today - 900)
        let totals = tree.rollUpSizes()
        #expect(AgeMap.untouched(in: tree, totals: totals, today: today, limit: 10) == [huge, small])
        let sizes = AgeMap.bucketSizes(in: tree, totals: totals, today: today)
        #expect(sizes[.under30] == 50_000)
        #expect(sizes[.oneToTwoYears] == 9_000)
    }
}

struct ChartLayoutTests {
    @Test func smallSiblingsCollapseIntoOther() {
        var tree = FileTree()
        let root = tree.addNode(name: "root", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let big = tree.addNode(name: "big", parent: root, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "payload", parent: big, isDirectory: false, logicalSize: 10_000, allocatedSize: 10_000, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "dust", parent: root, isDirectory: false, logicalSize: 1, allocatedSize: 1, modifiedDaysSinceEpoch: 0)
        let totals = tree.rollUpSizes()
        let slices = ChartLayout.slices(of: root, in: tree, totals: totals)
        #expect(slices.contains { $0.label == "big" && $0.drillable })
        #expect(slices.contains { $0.nodeID == nil && $0.drillable == false && $0.label.contains("Other") })
    }
}

struct CirclePackTests {
    @Test func packedCirclesDoNotOverlap() {
        let slices = (0..<6).map { index in
            ChartSlice(id: "\(index)", nodeID: Int32(index), size: Int64((index + 1) * 100), label: "\(index)", drillable: false, children: [])
        }
        let circles = CirclePack.pack(slices)
        #expect(circles.count == 6)
        for i in circles.indices {
            for j in circles.indices where j > i {
                let dx = circles[i].x - circles[j].x
                let dy = circles[i].y - circles[j].y
                let gap = (circles[i].radius + circles[j].radius) - 1e-4
                #expect(dx * dx + dy * dy >= gap * gap)
            }
        }
    }
}

struct SnapshotTests {
    @Test func roundTripAndDiffReportsOneSidedFolders() throws {
        var beforeTree = FileTree()
        let beforeRoot = beforeTree.addNode(name: "root", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let keepBefore = beforeTree.addNode(name: "keep", parent: beforeRoot, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        _ = beforeTree.addNode(name: "file", parent: keepBefore, isDirectory: false, logicalSize: 100, allocatedSize: 100, modifiedDaysSinceEpoch: 1)
        let gone = beforeTree.addNode(name: "gone", parent: beforeRoot, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        _ = beforeTree.addNode(name: "file", parent: gone, isDirectory: false, logicalSize: 40, allocatedSize: 40, modifiedDaysSinceEpoch: 1)
        let before = DiskSnapshot(rootPath: "/tmp/diskmap-snap", capturedAt: Date(timeIntervalSince1970: 1_700_000_000), tree: beforeTree)

        var afterTree = FileTree()
        let afterRoot = afterTree.addNode(name: "root", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let keepAfter = afterTree.addNode(name: "keep", parent: afterRoot, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        _ = afterTree.addNode(name: "file", parent: keepAfter, isDirectory: false, logicalSize: 250, allocatedSize: 250, modifiedDaysSinceEpoch: 1)
        let added = afterTree.addNode(name: "new", parent: afterRoot, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        _ = afterTree.addNode(name: "file", parent: added, isDirectory: false, logicalSize: 15, allocatedSize: 15, modifiedDaysSinceEpoch: 1)
        let after = DiskSnapshot(rootPath: "/tmp/diskmap-snap", capturedAt: Date(timeIntervalSince1970: 1_700_000_100), tree: afterTree)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiskMap-snapshots-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try SnapshotStore.save(before, in: directory)
        let header = try SnapshotStore.readHeader(from: url)
        #expect(header.rootPath == before.rootPath)
        #expect(header.capturedAt == before.capturedAt)
        let loaded = try SnapshotStore.load(from: url)
        #expect(loaded.rootPath == before.rootPath)
        #expect(loaded.tree.count == before.tree.count)
        #expect(loaded.tree.name(of: 1) == "keep")

        let changes = SnapshotDiff.changes(before: before, after: after, basis: .allocated)
        let byName = Dictionary(uniqueKeysWithValues: changes.map { (URL(fileURLWithPath: $0.path).lastPathComponent, $0) })
        #expect(byName["keep"]?.delta == 150)
        #expect(byName["gone"]?.before == 40)
        #expect(byName["gone"]?.after == 0)
        #expect(byName["new"]?.before == 0)
        #expect(byName["new"]?.after == 15)
    }
}
