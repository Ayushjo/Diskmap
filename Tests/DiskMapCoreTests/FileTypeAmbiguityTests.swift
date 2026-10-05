import Foundation
import Testing
@testable import DiskMapCore

/// Extensions that mean two things. On a real Desktop, 25,417 TypeScript
/// `.ts` files were counted as Video, and Docker's 11 GB `Docker.raw` disk
/// image as Image.
@Suite("Ambiguous file types")
struct FileTypeAmbiguityTests {
    private func category(of ext: String) -> String? {
        FileTypeCatalog.loadBundled().first { $0.extensions.contains(ext) }?.id
    }

    @Test func typeScriptIsDeveloperNotVideo() {
        #expect(category(of: "ts") == "developer")
        #expect(FileQuery.kindExtensions["video"]?.contains("ts") == false)
        #expect(category(of: "m2ts") == "video")
        #expect(category(of: "mts") == "video")
    }

    @Test func rawIsNotAnImage() {
        #expect(category(of: "raw") == nil)
        #expect(category(of: "cr2") == "image")
        #expect(category(of: "arw") == "image")
    }

    @Test func largeMediaSkipsTypeScriptButKeepsTransportStreams() {
        var tree = FileTree()
        let root = tree.addNode(name: "root", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "bundle.ts", parent: root, isDirectory: false, logicalSize: 3_000_000, allocatedSize: 3_000_000, modifiedDaysSinceEpoch: 1)
        _ = tree.addNode(name: "recording.ts", parent: root, isDirectory: false, logicalSize: 900_000_000, allocatedSize: 900_000_000, modifiedDaysSinceEpoch: 1)
        let totals = tree.rollUpSizes()
        let names = MediaCatalog.build(tree: tree, root: URL(fileURLWithPath: "/tmp/x"), totals: totals).candidates.map(\.name)
        #expect(names == ["recording.ts"])
    }
}
