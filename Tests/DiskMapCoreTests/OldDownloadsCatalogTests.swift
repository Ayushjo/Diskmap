import Foundation
import Testing
@testable import DiskMapCore

@Suite("Old Downloads catalog")
struct OldDownloadsCatalogTests {
    @Test func findsDownloadsFilesAndAges() {
        var tree = FileTree()
        let root = tree.addNode(name: "Users", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1000)
        let user = tree.addNode(name: "alex", parent: root, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1000)
        let dl = tree.addNode(name: "Downloads", parent: user, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1000)
        let video = tree.addNode(name: "Dune.mkv", parent: dl, isDirectory: false, logicalSize: 5_000_000_000, allocatedSize: 5_000_000_000, modifiedDaysSinceEpoch: 100)
        let dmg = tree.addNode(name: "App.dmg", parent: dl, isDirectory: false, logicalSize: 800_000_000, allocatedSize: 800_000_000, modifiedDaysSinceEpoch: 50)
        _ = tree.addNode(name: "notes.txt", parent: dl, isDirectory: false, logicalSize: 1000, allocatedSize: 1000, modifiedDaysSinceEpoch: 900)
        let both = tree.rollUpBoth()
        let built = OldDownloadsCatalog.build(
            tree: tree,
            root: URL(fileURLWithPath: "/Users", isDirectory: true),
            totals: both.allocated,
            today: 1000
        )
        #expect(built.candidates.contains { $0.nodeID == video })
        #expect(built.candidates.contains { $0.nodeID == dmg })
        // tiny notes below floor
        #expect(!built.candidates.contains { $0.name == "notes.txt" })
        let dune = built.candidates.first { $0.nodeID == video }
        #expect(dune?.kind == .video)
        #expect(dune?.status == .reviewFirst)
        #expect(dune?.ageDays == 900)
        let installer = built.candidates.first { $0.nodeID == dmg }
        #expect(installer?.status == .likelyDisposable)
        #expect(built.summary.totalBytes >= 5_800_000_000)
        #expect(built.summary.bytes365 > 0)
    }

    @Test func filtersByAgeAndType() {
        let items = [
            OldDownloadsCandidate(
                nodeID: 1, name: "a.mkv", absolutePath: "/Users/x/Downloads/a.mkv",
                displayPath: "~/Downloads/a.mkv", bytes: 2_000_000_000, modifiedDay: 1, ageDays: 400,
                kind: .video, status: .reviewFirst,
                safety: SafetyAssessment(level: .review, reason: "r", title: "a"),
                whyHere: "w", recommendation: "r", score: 1
            ),
            OldDownloadsCandidate(
                nodeID: 2, name: "b.dmg", absolutePath: "/Users/x/Downloads/b.dmg",
                displayPath: "~/Downloads/b.dmg", bytes: 500_000_000, modifiedDay: 1, ageDays: 40,
                kind: .diskImage, status: .reviewFirst,
                safety: SafetyAssessment(level: .review, reason: "r", title: "b"),
                whyHere: "w", recommendation: "r", score: 1
            ),
        ]
        let year = OldDownloadsCatalog.filter(items, age: .year1, size: .any, type: .all, query: "")
        #expect(year.count == 1)
        #expect(year[0].name == "a.mkv")
        let videos = OldDownloadsCatalog.filter(items, age: .all, size: .any, type: .video, query: "")
        #expect(videos.count == 1)
    }

    @Test func isUnderDownloads() {
        #expect(OldDownloadsCatalog.isUnderDownloads("/Users/a/Downloads/x.mkv"))
        #expect(!OldDownloadsCatalog.isUnderDownloads("/Users/a/Documents/x.mkv"))
    }
}
