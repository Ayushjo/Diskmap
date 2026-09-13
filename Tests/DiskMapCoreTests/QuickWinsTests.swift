import Foundation
import Testing
@testable import DiskMapCore

struct QuickWinsTests {
    @Test func bundledPatternsIncludeTheTicketList() {
        let patterns = QuickWins.bundledPatterns()
        #expect(patterns.directoryNames.contains("node_modules"))
        #expect(patterns.directoryNames.contains("DerivedData"))
        #expect(patterns.pathSuffixes.contains { $0.contains("iOS DeviceSupport") })
    }

    @Test func matchSwallowsDescendantsAndStillFindsASibling() {
        var tree = FileTree()
        let root = tree.addNode(name: "proj", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let modules = tree.addNode(name: "node_modules", parent: root, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "dist", parent: modules, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let ownDist = tree.addNode(name: "dist", parent: root, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "src", parent: root, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)

        let hits = QuickWins.find(
            in: tree,
            root: URL(fileURLWithPath: "/tmp/proj", isDirectory: true),
            patterns: QuickWins.Patterns(directoryNames: ["node_modules", "dist"], pathSuffixes: [])
        )
        #expect(Set(hits.map(\.id)) == [modules, ownDist])
    }

    @Test func pathSuffixMatchesUnderAScanRoot() {
        var tree = FileTree()
        let root = tree.addNode(name: "home", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let library = tree.addNode(name: "Library", parent: root, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let dev = tree.addNode(name: "Developer", parent: library, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let xcode = tree.addNode(name: "Xcode", parent: dev, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let support = tree.addNode(name: "iOS DeviceSupport", parent: xcode, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)

        let hits = QuickWins.find(
            in: tree,
            root: URL(fileURLWithPath: "/Users/example", isDirectory: true),
            patterns: QuickWins.Patterns(directoryNames: [], pathSuffixes: ["Library/Developer/Xcode/iOS DeviceSupport"])
        )
        #expect(hits.map(\.id) == [support])
    }

    @Test func applicationBundlesAreAppFoldersOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DiskMap-apps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("One.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("not-an-app"), withIntermediateDirectories: true)
        let found = AppLeftoverFinder.applicationBundles(in: [dir])
        #expect(found.map(\.lastPathComponent) == ["One.app"])
    }
}
