import Foundation
import Testing
@testable import DiskMapCore

/// Snapshot compare: aligned by name, each level sums to its parent, and
/// hotspots name where a change happened instead of every ancestor of it.
@Suite("Snapshot comparison")
struct SnapshotComparisonTests {

    /// Paths → sizes; folders are implied by the paths.
    static func snapshot(_ files: [String: Int64], root: String = "/Users/x") -> DiskSnapshot {
        var tree = FileTree()
        let rootID = tree.addNode(name: "x", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        var folders: [String: Int32] = ["": rootID]
        for (path, size) in files.sorted(by: { $0.key < $1.key }) {
            let parts = path.split(separator: "/").map(String.init)
            var parentPath = ""
            for part in parts.dropLast() {
                let folderPath = parentPath.isEmpty ? part : parentPath + "/" + part
                if folders[folderPath] == nil {
                    folders[folderPath] = tree.addNode(name: part, parent: folders[parentPath] ?? rootID, isDirectory: true,
                                                       logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
                }
                parentPath = folderPath
            }
            tree.addNode(name: parts.last ?? path, parent: folders[parentPath] ?? rootID, isDirectory: false,
                         logicalSize: size, allocatedSize: size, modifiedDaysSinceEpoch: 1)
        }
        return DiskSnapshot(rootPath: root, capturedAt: Date(), tree: tree)
    }

    static let gb: Int64 = 1_000_000_000

    @Test func childrenAlignByNameAndSumToTheParent() {
        let comparison = SnapshotComparison(
            before: Self.snapshot(["Downloads/a.mov": 5 * Self.gb, "Library/cache.db": 2 * Self.gb, "notes.txt": 100]),
            after: Self.snapshot(["Downloads/a.mov": 5 * Self.gb, "Downloads/b.mov": 3 * Self.gb, "Library/cache.db": Self.gb, "new.txt": 50]),
            basis: .allocated)
        let root = comparison.root
        #expect(root.delta == 3 * Self.gb - Self.gb + 50 - 100)
        let kids = comparison.children(of: root)
        #expect(kids.map(\.name) == ["Downloads", "Library", "notes.txt", "new.txt"], "largest change first")
        #expect(kids.reduce(0) { $0 + $1.delta } == root.delta, "a level adds up to its parent")
        #expect(kids.first { $0.name == "notes.txt" }?.kind == .removed)
        #expect(kids.first { $0.name == "new.txt" }?.kind == .added)
        #expect(comparison.split(of: root) == (grew: 3 * Self.gb + 50, shrank: -Self.gb - 100))
        #expect(!comparison.children(of: root).contains { $0.delta == 0 })
    }

    @Test func aDeepNewFileIsOneHotspotNotEveryAncestor() {
        let comparison = SnapshotComparison(
            before: Self.snapshot(["Downloads/show/s1/e1.mkv": Self.gb, "Library/x": Self.gb]),
            after: Self.snapshot(["Downloads/show/s1/e1.mkv": Self.gb, "Downloads/show/s1/e2.mkv": 4 * Self.gb, "Library/x": Self.gb]),
            basis: .allocated)
        let spots = comparison.hotspots(minimumChange: 100_000_000)
        #expect(spots.map(\.path) == ["Downloads/show/s1/e2.mkv"])
        #expect(spots.first?.kind == .added)
    }

    @Test func goneFoldersAndSpreadChangesStopWhereTheyHappened() {
        var before: [String: Int64] = ["Old/big.iso": 6 * Self.gb]
        var after: [String: Int64] = [:]
        // Library/Caches grows by 1 GB across 50 apps of 20 MB each: spread.
        for app in 0..<50 {
            before["Library/Caches/app\(app)/blob"] = 10_000_000
            after["Library/Caches/app\(app)/blob"] = 30_000_000
        }
        let comparison = SnapshotComparison(before: Self.snapshot(before), after: Self.snapshot(after), basis: .allocated)
        let spots = comparison.hotspots(minimumChange: 100_000_000)
        #expect(spots.map(\.path) == ["Old", "Library/Caches"])
        #expect(spots.first?.kind == .removed, "a removed folder is reported whole")
        #expect(spots.last?.delta == Self.gb)
    }

    /// Growth spread over many big subfolders is one row for the folder, not
    /// one per subfolder (seen on a real home: WhatsApp media across chats).
    @Test func growthAcrossManyBigSubfoldersIsOneRow() {
        var before: [String: Int64] = ["Photos/keep.jpg": Self.gb]
        var after: [String: Int64] = ["Photos/keep.jpg": Self.gb]
        for chat in 0..<12 { after["Media/chat\(chat)/video.mp4"] = 500_000_000 }
        before["Media/placeholder"] = 1
        after["Media/placeholder"] = 1
        let comparison = SnapshotComparison(before: Self.snapshot(before), after: Self.snapshot(after), basis: .allocated)
        let spots = comparison.hotspots(minimumChange: 100_000_000)
        #expect(spots.map(\.path) == ["Media"])
        #expect(spots.first?.delta == 6 * Self.gb)
    }

    @Test func mixedDirectionsAreReportedSeparately() {
        let comparison = SnapshotComparison(
            before: Self.snapshot(["Work/a/big.bin": 2 * Self.gb, "Work/b/old.bin": 5 * Self.gb]),
            after: Self.snapshot(["Work/a/big.bin": 9 * Self.gb, "Work/b/old.bin": 3 * Self.gb]),
            basis: .allocated)
        let spots = comparison.hotspots(minimumChange: 100_000_000)
        #expect(Set(spots.map(\.path)) == ["Work/a/big.bin", "Work/b/old.bin"])
        #expect(spots.first?.delta == 7 * Self.gb)
    }

    @Test func entriesResolveByPath() {
        let comparison = SnapshotComparison(
            before: Self.snapshot(["A/B/c.txt": 10]), after: Self.snapshot(["A/B/c.txt": 30]), basis: .allocated)
        #expect(comparison.entry(atPath: "A/B")?.delta == 20)
        #expect(comparison.entry(atPath: "A/nope") == nil)
        #expect(comparison.entry(atPath: "")?.path == "")
        #expect(comparison.absolutePath(of: comparison.entry(atPath: "A/B")!) == "/Users/x/A/B")
        #expect(comparison.rootsMatch)
    }
}

@Suite("Snapshot names")
struct SnapshotNameTests {
    private func record(name: String, captured: Date) -> SnapshotRecord {
        SnapshotRecord(url: URL(fileURLWithPath: "/tmp/x.snapshot"),
                       header: SnapshotHeader(rootPath: "/Users/x", capturedAt: captured),
                       meta: SnapshotMeta(name: name), isCurrent: false)
    }

    @Test func automaticTodayNamesAgeCorrectly() {
        let twoWeeksAgo = Date().addingTimeInterval(-14 * 86_400)
        let stale = "Today — \(twoWeeksAgo.formatted(date: .omitted, time: .shortened))"
        let rec = record(name: stale, captured: twoWeeksAgo)
        #expect(!rec.displayName.hasPrefix("Today"))
        #expect(rec.displayName == twoWeeksAgo.formatted(date: .abbreviated, time: .shortened))
        #expect(record(name: "Before Docker cleanup", captured: twoWeeksAgo).displayName == "Before Docker cleanup")
        let now = Date()
        #expect(record(name: "", captured: now).displayName.hasPrefix("Today — "))
    }
}
