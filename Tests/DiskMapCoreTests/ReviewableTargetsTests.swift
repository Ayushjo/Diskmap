import Foundation
import Testing
@testable import DiskMapCore

@Suite("Safe to Review catalog")
struct ReviewableTargetsTests {
    @Test func cachesGroupedByAppWithoutDoubleCountingParent() {
        var tree = FileTree()
        _ = tree.addNode(name: "Users", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let user = tree.addNode(name: "alex", parent: 0, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let library = tree.addNode(name: "Library", parent: user, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let caches = tree.addNode(name: "Caches", parent: library, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let chrome = tree.addNode(name: "Google", parent: caches, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let chromeCache = tree.addNode(name: "Chrome", parent: chrome, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "f.bin", parent: chromeCache, isDirectory: false, logicalSize: 3_000_000_000, allocatedSize: 3_000_000_000, modifiedDaysSinceEpoch: 10)
        let spotify = tree.addNode(name: "com.spotify.client", parent: caches, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "g.bin", parent: spotify, isDirectory: false, logicalSize: 2_000_000_000, allocatedSize: 2_000_000_000, modifiedDaysSinceEpoch: 10)
        let both = tree.rollUpBoth()
        let qw = QuickWins.find(in: tree, root: URL(fileURLWithPath: "/Users", isDirectory: true), patterns: QuickWins.bundledPatterns())
        let built = ReviewableCatalog.build(
            tree: tree,
            root: URL(fileURLWithPath: "/Users", isDirectory: true),
            totals: both.allocated,
            quickWins: qw
        )
        let cacheTargets = built.targets.filter { $0.category == .caches }
        #expect(cacheTargets.contains { $0.displayName == "Chrome" })
        #expect(cacheTargets.contains { $0.displayName == "Spotify" })
        // Parent Caches folder must not appear as its own additive target
        #expect(!built.targets.contains { $0.displayName == "Caches" && $0.category == .caches })
        let chromeBytes = cacheTargets.first { $0.displayName == "Chrome" }?.bytes ?? 0
        let spotifyBytes = cacheTargets.first { $0.displayName == "Spotify" }?.bytes ?? 0
        #expect(chromeBytes == 3_000_000_000)
        #expect(spotifyBytes == 2_000_000_000)
        #expect(built.summary.cacheBytes == chromeBytes + spotifyBytes)
    }

    @Test func nodeModulesIsBuildArtifactReviewFirst() {
        var tree = FileTree()
        _ = tree.addNode(name: "proj", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let nm = tree.addNode(name: "node_modules", parent: 0, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "pkg", parent: nm, isDirectory: false, logicalSize: 1_100_000_000, allocatedSize: 1_100_000_000, modifiedDaysSinceEpoch: 5)
        let both = tree.rollUpBoth()
        let qw = QuickWins.find(in: tree, root: URL(fileURLWithPath: "/tmp/proj", isDirectory: true), patterns: QuickWins.bundledPatterns())
        let built = ReviewableCatalog.build(
            tree: tree,
            root: URL(fileURLWithPath: "/tmp/proj", isDirectory: true),
            totals: both.allocated,
            quickWins: qw
        )
        let hit = built.targets.first { $0.nodeIDs.contains(nm) || $0.displayName.lowercased().contains("node") }
        #expect(hit != nil)
        #expect(hit?.category == .buildArtifacts)
        #expect(hit?.safety.level == .review)
    }

    @Test func summaryCategoriesAreAdditive() {
        let targets = [
            ReviewableTarget(
                id: "1", category: .caches, displayName: "A", detail: "d", bytes: 10,
                primaryPath: "/a", paths: ["/a"], nodeIDs: [1],
                safety: SafetyAssessment(level: .safe, reason: "r", title: "A"),
                consequence: "c", symbolName: "internaldrive", bundleHint: nil
            ),
            ReviewableTarget(
                id: "2", category: .buildArtifacts, displayName: "B", detail: "d", bytes: 20,
                primaryPath: "/b", paths: ["/b"], nodeIDs: [2],
                safety: SafetyAssessment(level: .review, reason: "r", title: "B"),
                consequence: "c", symbolName: "hammer", bundleHint: nil
            ),
        ]
        let s = ReviewableCatalog.summarize(targets)
        #expect(s.totalBytes == 30)
        #expect(s.cacheBytes == 10)
        #expect(s.buildBytes == 20)
    }
}
