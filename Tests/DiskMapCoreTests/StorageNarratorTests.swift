import Foundation
import Testing
@testable import DiskMapCore

@Suite("StorageNarrator + CleanupPreflight")
struct StorageNarratorTests {
    @Test func recommendationsPreferSafeQuickWins() {
        let snap = AnalysisSnapshot(
            scanRootPath: "/Users/test",
            volume: nil,
            scannedBytes: 10_000,
            categories: [
                StorageCategory(key: "downloads", title: "Downloads", bytes: 5_000, colorHint: "downloads"),
                StorageCategory(key: "caches", title: "Caches", bytes: 2_000, colorHint: "caches"),
            ],
            topFiles: [],
            topFolders: [],
            reviewableBytes: 4_000,
            forgottenBytes: 1_000,
            quickWinBytes: 3_000,
            health: .tight,
            fileCount: 10,
            folderCount: 4
        )
        let recs = StorageNarrator.recommendations(from: snap)
        #expect(!recs.isEmpty)
        #expect(recs.first?.safety == .safe || recs.first?.id == "rec-quickwins" || recs.first?.id == "rec-caches")
        #expect(recs[0].score >= (recs.last?.score ?? 0))
    }

    @Test func storiesCapAtFive() {
        let snap = AnalysisSnapshot(
            scanRootPath: "/Users/test",
            volume: nil,
            scannedBytes: 100,
            categories: [StorageCategory(key: "other", title: "Other", bytes: 100, colorHint: "other")],
            topFiles: [StorageFileHit(nodeID: 1, name: "a.bin", bytes: 90, relativePath: "a.bin", modifiedDay: 0)],
            topFolders: [],
            reviewableBytes: 50,
            forgottenBytes: 40,
            quickWinBytes: 30,
            health: .healthy,
            fileCount: 1,
            folderCount: 1
        )
        #expect(StorageNarrator.stories(from: snap, limit: 5).count <= 5)
    }

    @Test func preflightBlocksSystem() {
        let r = CleanupPreflight.evaluate(url: URL(fileURLWithPath: "/System/Library"), isDirectory: true)
        #expect(r.allowed == false)
        #expect(r.assessment.level == .protected)
    }

    @Test func preflightAllowsNpm() {
        let r = CleanupPreflight.evaluate(url: URL(fileURLWithPath: "/Users/x/.npm"), isDirectory: true)
        #expect(r.allowed == true)
        #expect(r.assessment.level == .safe)
        #expect(!r.assessment.consequences.isEmpty)
        #expect(!r.assessment.recommendedAction.isEmpty)
    }

    @Test func safetyCargoIsSafe() {
        let a = SafetyClassifier.assess(path: "/Users/x/.cargo", name: ".cargo", isDirectory: true)
        #expect(a.level == .safe)
    }

    @Test func safetyKeychainProtected() {
        let a = SafetyClassifier.assess(path: "/Users/x/Library/Keychains", name: "Keychains", isDirectory: true)
        #expect(a.level == .protected)
    }
}
