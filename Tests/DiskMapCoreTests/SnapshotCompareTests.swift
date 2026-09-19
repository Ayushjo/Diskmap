import Foundation
import Testing
@testable import DiskMapCore

@Suite("Snapshot compare + meta")
struct SnapshotCompareTests {
    @Test func metaSidecarRoundTrip() throws {
        var tree = FileTree()
        _ = tree.addNode(name: "root", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 10, modifiedDaysSinceEpoch: 1)
        let snap = DiskSnapshot(rootPath: "/tmp/snap-meta", capturedAt: Date(timeIntervalSince1970: 1_700_000_000), tree: tree)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiskMap-meta-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let meta = SnapshotMeta(
            name: "Before cleanup",
            note: "Docker caches",
            favorite: true,
            totalBytes: 150,
            freeBytes: 50,
            usedBytes: 100
        )
        let url = try SnapshotStore.save(snap, meta: meta, in: directory)
        let loaded = SnapshotStore.loadMeta(for: url)
        #expect(loaded.name == "Before cleanup")
        #expect(loaded.note == "Docker caches")
        #expect(loaded.favorite == true)
        #expect(loaded.usedBytes == 100)
        let records = SnapshotStore.records(in: directory, rootPath: "/tmp/snap-meta")
        #expect(records.count == 1)
        #expect(records[0].displayName == "Before cleanup")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: SnapshotStore.metaURL(for: url).path))
    }

    @Test func compareReportsCategoryAndFolderDeltas() {
        var beforeTree = FileTree()
        let br = beforeTree.addNode(name: "Users", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        let user = beforeTree.addNode(name: "alex", parent: br, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        let dl = beforeTree.addNode(name: "Downloads", parent: user, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        _ = beforeTree.addNode(name: "a.bin", parent: dl, isDirectory: false, logicalSize: 1_000_000_000, allocatedSize: 1_000_000_000, modifiedDaysSinceEpoch: 1)

        var afterTree = FileTree()
        let ar = afterTree.addNode(name: "Users", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        let user2 = afterTree.addNode(name: "alex", parent: ar, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        let dl2 = afterTree.addNode(name: "Downloads", parent: user2, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        _ = afterTree.addNode(name: "a.bin", parent: dl2, isDirectory: false, logicalSize: 1_000_000_000, allocatedSize: 1_000_000_000, modifiedDaysSinceEpoch: 1)
        _ = afterTree.addNode(name: "b.bin", parent: dl2, isDirectory: false, logicalSize: 500_000_000, allocatedSize: 500_000_000, modifiedDaysSinceEpoch: 1)

        let before = DiskSnapshot(rootPath: "/Users", capturedAt: Date(timeIntervalSince1970: 1), tree: beforeTree)
        let after = DiskSnapshot(rootPath: "/Users", capturedAt: Date(timeIntervalSince1970: 2), tree: afterTree)
        let beforeMeta = SnapshotMeta(name: "A", totalBytes: 1_000_000_100, freeBytes: 100, usedBytes: 1_000_000_000)
        let afterMeta = SnapshotMeta(name: "B", totalBytes: 1_500_000_050, freeBytes: 50, usedBytes: 1_500_000_000)
        let report = SnapshotCompare.report(
            before: before,
            after: after,
            beforeMeta: beforeMeta,
            afterMeta: afterMeta,
            basis: .allocated
        )
        #expect(report.usedDelta == 500_000_000)
        #expect(report.freeDelta == -50)
        #expect(report.folderChanges.contains { $0.delta == 500_000_000 })
        let kinds = SnapshotCompare.filterChanges(report.folderChanges, kind: .grew, query: "", minAbsDelta: 0)
        #expect(!kinds.isEmpty)
        #expect(SnapshotCompare.narrative(for: report).contains("increased") || SnapshotCompare.narrative(for: report).contains("GB") || SnapshotCompare.narrative(for: report).contains("MB"))
    }

    @Test func changeKindClassification() {
        #expect(SnapshotChange(path: "/a", before: 0, after: 10).kind == .added)
        #expect(SnapshotChange(path: "/a", before: 10, after: 0).kind == .removed)
        #expect(SnapshotChange(path: "/a", before: 10, after: 20).kind == .grew)
        #expect(SnapshotChange(path: "/a", before: 20, after: 10).kind == .shrunk)
    }
}
