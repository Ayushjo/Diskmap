import Foundation
import Testing
@testable import DiskMapCore

@Suite("Forgotten Files candidates")
struct ForgottenFilesTests {
    private func todayOffset(_ daysAgo: Int32) -> Int32 {
        AgeMap.today() - daysAgo
    }

    @Test func downloadsOldVideoIsLikelyForgotten() {
        var tree = FileTree()
        _ = tree.addNode(name: "Users", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let user = tree.addNode(name: "alex", parent: 0, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let downloads = tree.addNode(name: "Downloads", parent: user, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let file = tree.addNode(
            name: "old-movie.mkv",
            parent: downloads,
            isDirectory: false,
            logicalSize: 8_000_000_000,
            allocatedSize: 8_000_000_000,
            modifiedDaysSinceEpoch: todayOffset(800)
        )
        let both = tree.rollUpBoth()
        let candidates = ForgottenFiles.candidates(
            tree: tree,
            root: URL(fileURLWithPath: "/Users", isDirectory: true),
            totals: both.allocated,
            today: AgeMap.today(),
            limit: 50
        )
        let hit = candidates.first { $0.id == file }
        #expect(hit != nil)
        #expect(hit?.confidence == .likelyForgotten)
        #expect(hit?.isReviewable == true)
    }

    @Test func appBundleFrameworkIsOldImportant() {
        var tree = FileTree()
        _ = tree.addNode(name: "Applications", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let app = tree.addNode(name: "FreeCAD.app", parent: 0, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let contents = tree.addNode(name: "Contents", parent: app, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let fw = tree.addNode(name: "Frameworks", parent: contents, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let file = tree.addNode(
            name: "model.espresso.weights",
            parent: fw,
            isDirectory: false,
            logicalSize: 140_000_000,
            allocatedSize: 140_000_000,
            modifiedDaysSinceEpoch: todayOffset(900)
        )
        let both = tree.rollUpBoth()
        let candidates = ForgottenFiles.candidates(
            tree: tree,
            root: URL(fileURLWithPath: "/Applications", isDirectory: true),
            totals: both.allocated,
            today: AgeMap.today(),
            limit: 50
        )
        let hit = candidates.first { $0.id == file }
        #expect(hit?.confidence == .oldImportant)
        let summary = ForgottenFiles.summary(from: candidates)
        #expect(summary.reviewableBytes == 0 || !candidates.contains { $0.id == file && $0.isReviewable })
        #expect(hit?.isReviewable == false)
    }

    @Test func systemFileProtectedExcluded() {
        var tree = FileTree()
        _ = tree.addNode(name: "System", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let lib = tree.addNode(name: "Library", parent: 0, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let file = tree.addNode(
            name: "kernel",
            parent: lib,
            isDirectory: false,
            logicalSize: 5_000_000_000,
            allocatedSize: 5_000_000_000,
            modifiedDaysSinceEpoch: todayOffset(1200)
        )
        let both = tree.rollUpBoth()
        let candidates = ForgottenFiles.candidates(
            tree: tree,
            root: URL(fileURLWithPath: "/", isDirectory: true),
            totals: both.allocated,
            today: AgeMap.today()
        )
        let hit = candidates.first { $0.id == file }
        #expect(hit?.confidence == .oldImportant)
        #expect(hit?.safety.level == .protected)
    }

    @Test func recentLargeFileNotForgotten() {
        var tree = FileTree()
        _ = tree.addNode(name: "Users", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let user = tree.addNode(name: "alex", parent: 0, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let downloads = tree.addNode(name: "Downloads", parent: user, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(
            name: "fresh.mkv",
            parent: downloads,
            isDirectory: false,
            logicalSize: 20_000_000_000,
            allocatedSize: 20_000_000_000,
            modifiedDaysSinceEpoch: todayOffset(60)
        )
        let both = tree.rollUpBoth()
        let candidates = ForgottenFiles.candidates(
            tree: tree,
            root: URL(fileURLWithPath: "/Users", isDirectory: true),
            totals: both.allocated,
            today: AgeMap.today()
        )
        #expect(candidates.isEmpty)
    }

    @Test func tinyOldFileExcludedBySizeFloor() {
        var tree = FileTree()
        _ = tree.addNode(name: "Users", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let user = tree.addNode(name: "alex", parent: 0, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let downloads = tree.addNode(name: "Downloads", parent: user, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(
            name: "note.txt",
            parent: downloads,
            isDirectory: false,
            logicalSize: 2000,
            allocatedSize: 2000,
            modifiedDaysSinceEpoch: todayOffset(3000)
        )
        let both = tree.rollUpBoth()
        let candidates = ForgottenFiles.candidates(
            tree: tree,
            root: URL(fileURLWithPath: "/Users", isDirectory: true),
            totals: both.allocated,
            today: AgeMap.today()
        )
        #expect(candidates.isEmpty)
    }

    @Test func ageDistributionOnlyUsesReviewableCandidates() {
        var tree = FileTree()
        _ = tree.addNode(name: "Users", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let user = tree.addNode(name: "alex", parent: 0, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let downloads = tree.addNode(name: "Downloads", parent: user, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(
            name: "a.mkv",
            parent: downloads,
            isDirectory: false,
            logicalSize: 2_000_000_000,
            allocatedSize: 2_000_000_000,
            modifiedDaysSinceEpoch: todayOffset(400)
        )
        _ = tree.addNode(
            name: "b.mkv",
            parent: downloads,
            isDirectory: false,
            logicalSize: 3_000_000_000,
            allocatedSize: 3_000_000_000,
            modifiedDaysSinceEpoch: todayOffset(40)
        )
        let both = tree.rollUpBoth()
        let candidates = ForgottenFiles.candidates(
            tree: tree,
            root: URL(fileURLWithPath: "/Users", isDirectory: true),
            totals: both.allocated,
            today: AgeMap.today()
        )
        let summary = ForgottenFiles.summary(from: candidates)
        let chartSum = summary.ageDistribution.values.reduce(Int64(0), +)
        #expect(chartSum == summary.reviewableBytes)
        #expect(summary.reviewableBytes == 2_000_000_000)
        // All-files age map would include the 3GB fresh file — forgotten chart must not.
        let allBuckets = AgeMap.bucketSizes(in: tree, totals: both.allocated, today: AgeMap.today())
        let allSum = allBuckets.values.reduce(Int64(0), +)
        #expect(allSum > summary.reviewableBytes)
    }

    @Test func dockerRawIsOldImportant() {
        let conf = ForgottenFiles.classifyConfidence(
            path: "/Users/alex/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
            name: "Docker.raw",
            kind: .virtualDisk,
            safety: SafetyClassifier.assess(
                path: "/Users/alex/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
                name: "Docker.raw",
                isDirectory: false
            ),
            bytes: 10_000_000_000
        )
        #expect(conf == .oldImportant)
    }
}
