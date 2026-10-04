import Foundation
import Testing
@testable import DiskMapCore

@Suite("Large Media catalog")
struct MediaCatalogTests {
    @Test func classifiesMediaAndExcludesDiskImages() {
        #expect(MediaCatalog.classify(fileName: "Dune.mkv") == .video)
        #expect(MediaCatalog.classify(fileName: "clip.mp4") == .video)
        #expect(MediaCatalog.classify(fileName: "IMG_01.HEIC") == .image)
        #expect(MediaCatalog.classify(fileName: "song.mp3") == .audio)
        #expect(MediaCatalog.classify(fileName: "Library.photoslibrary", isDirectory: true) == .project)
        #expect(MediaCatalog.classify(fileName: "os.dmg") == nil)
        #expect(MediaCatalog.classify(fileName: "os.clone.dmg") == nil)
        #expect(MediaCatalog.classify(fileName: "Setup.pkg") == nil)
        #expect(MediaCatalog.classify(fileName: "archive.zip") == nil)
        #expect(MediaCatalog.classify(fileName: "Notes.pdf") == nil)
        #expect(MediaCatalog.classify(fileName: "Docker.raw") == nil)
        #expect(MediaCatalog.classify(fileName: "IMG_0042.dng") == .image)
    }

    @Test func buildExcludesDmgAndKeepsVideo() {
        var tree = FileTree()
        let root = tree.addNode(name: "Users", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1000)
        let user = tree.addNode(name: "alex", parent: root, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1000)
        let dl = tree.addNode(name: "Downloads", parent: user, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1000)
        let video = tree.addNode(name: "Dune.mkv", parent: dl, isDirectory: false, logicalSize: 5_000_000_000, allocatedSize: 5_000_000_000, modifiedDaysSinceEpoch: 100)
        let dmg = tree.addNode(name: "os.dmg", parent: dl, isDirectory: false, logicalSize: 7_000_000_000, allocatedSize: 7_000_000_000, modifiedDaysSinceEpoch: 200)
        let clone = tree.addNode(name: "os.clone.dmg", parent: dl, isDirectory: false, logicalSize: 7_000_000_000, allocatedSize: 7_000_000_000, modifiedDaysSinceEpoch: 200)
        let photo = tree.addNode(name: "IMG_1.heic", parent: dl, isDirectory: false, logicalSize: 12_000_000, allocatedSize: 12_000_000, modifiedDaysSinceEpoch: 900)
        _ = dmg
        _ = clone
        let both = tree.rollUpBoth()
        let built = MediaCatalog.build(
            tree: tree,
            root: URL(fileURLWithPath: "/Users", isDirectory: true),
            totals: both.allocated,
            today: 1000
        )
        #expect(built.candidates.contains { $0.nodeID == video })
        #expect(built.candidates.contains { $0.nodeID == photo })
        #expect(!built.candidates.contains { $0.name == "os.dmg" })
        #expect(!built.candidates.contains { $0.name == "os.clone.dmg" })
        #expect(built.summary.videoBytes >= 5_000_000_000)
        #expect(built.summary.imageCount >= 1)
        let dune = built.candidates.first { $0.nodeID == video }
        #expect(dune?.status == .reviewFirst)
        #expect(dune?.location == .downloads)
    }

    @Test func filtersByTypeLocationAndQuery() {
        let items = [
            MediaCandidate(
                nodeID: 1, name: "a.mkv", absolutePath: "/Users/x/Downloads/a.mkv",
                displayPath: "~/Downloads/a.mkv", bytes: 2_000_000_000, modifiedDay: 1, ageDays: 400,
                kind: .video, location: .downloads, status: .reviewFirst,
                safety: SafetyAssessment(level: .review, reason: "r", title: "a"),
                whyHere: "w", recommendation: "r", isDirectory: false, score: 1
            ),
            MediaCandidate(
                nodeID: 2, name: "b.heic", absolutePath: "/Users/x/Desktop/b.heic",
                displayPath: "~/Desktop/b.heic", bytes: 8_000_000, modifiedDay: 1, ageDays: 40,
                kind: .image, location: .desktop, status: .reviewFirst,
                safety: SafetyAssessment(level: .review, reason: "r", title: "b"),
                whyHere: "w", recommendation: "r", isDirectory: false, score: 1
            ),
        ]
        let videos = MediaCatalog.filter(items, type: .video, size: .any, age: .all, location: .any, query: "")
        #expect(videos.count == 1)
        let dl = MediaCatalog.filter(items, type: .all, size: .any, age: .all, location: .downloads, query: "")
        #expect(dl.count == 1)
        let q = MediaCatalog.filter(items, type: .all, size: .any, age: .all, location: .any, query: "desktop")
        #expect(q.count == 1)
        #expect(q[0].name == "b.heic")
    }

    @Test func personalVideoNeverLikelyDisposable() {
        #expect(MediaCatalog.classifyStatus(kind: .video, ageDays: 900, name: "Dune.mkv") == .reviewFirst)
        #expect(MediaCatalog.classifyStatus(kind: .image, ageDays: 900, name: "IMG.heic") == .reviewFirst)
        #expect(MediaCatalog.classifyStatus(kind: .project, ageDays: 900, name: "Lib.photoslibrary") == .reviewFirst)
    }
}
