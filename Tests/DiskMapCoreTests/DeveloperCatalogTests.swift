import Foundation
import Testing
@testable import DiskMapCore

@Suite("Developer Storage catalog")
struct DeveloperCatalogTests {
    @Test func classifiesNpmAndNodeModulesWithoutDoubleCount() {
        var tree = FileTree()
        let root = tree.addNode(name: "Users", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 100)
        let user = tree.addNode(name: "dev", parent: root, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 100)
        let lib = tree.addNode(name: "Library", parent: user, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 100)
        let caches = tree.addNode(name: "Caches", parent: lib, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 100)
        let npm = tree.addNode(name: ".npm", parent: caches, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 90)
        _ = tree.addNode(name: "tgz", parent: npm, isDirectory: false, logicalSize: 4_000_000_000, allocatedSize: 4_000_000_000, modifiedDaysSinceEpoch: 90)

        let code = tree.addNode(name: "Code", parent: user, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 80)
        let proj = tree.addNode(name: "my-app", parent: code, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 80)
        let nm = tree.addNode(name: "node_modules", parent: proj, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 70)
        _ = tree.addNode(name: "pkg", parent: nm, isDirectory: false, logicalSize: 2_000_000_000, allocatedSize: 2_000_000_000, modifiedDaysSinceEpoch: 70)

        let both = tree.rollUpBoth()
        let built = DeveloperCatalog.build(
            tree: tree,
            root: URL(fileURLWithPath: "/Users", isDirectory: true),
            totals: both.allocated
        )

        #expect(built.items.contains { $0.displayName.lowercased().contains("npm") })
        #expect(built.items.contains { $0.category == .dependencies && $0.ecosystem == .node })
        #expect(built.summary.totalBytes == 6_000_000_000)
        #expect(built.projects.contains { $0.name == "my-app" })
        let npmItem = built.items.first { $0.absolutePath.lowercased().contains("/.npm") }
        #expect(npmItem?.reclaimability == .reclaimable)
        #expect(npmItem?.category == .caches)
        #expect(built.opportunities.isEmpty == false)
    }

    @Test func prefersOuterDirectoryOverNestedHit() {
        var tree = FileTree()
        _ = tree.addNode(name: "home", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        let cargo = tree.addNode(name: ".cargo", parent: 0, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        let registry = tree.addNode(name: "registry", parent: cargo, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        // nested name that also matches a rule shouldn't double-count if we only match exact names;
        // add nested .cargo-like via target under project instead
        let proj = tree.addNode(name: "crate", parent: 0, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        let target = tree.addNode(name: "target", parent: proj, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        _ = tree.addNode(name: "a.o", parent: target, isDirectory: false, logicalSize: 500_000_000, allocatedSize: 500_000_000, modifiedDaysSinceEpoch: 1)
        _ = tree.addNode(name: "idx", parent: registry, isDirectory: false, logicalSize: 300_000_000, allocatedSize: 300_000_000, modifiedDaysSinceEpoch: 1)

        let both = tree.rollUpBoth()
        let built = DeveloperCatalog.build(
            tree: tree,
            root: URL(fileURLWithPath: "/tmp/home", isDirectory: true),
            totals: both.allocated
        )
        #expect(built.items.contains { $0.displayName.lowercased().contains("cargo") || $0.absolutePath.contains(".cargo") })
        #expect(built.items.contains { $0.category == .buildArtifacts && $0.ecosystem == .rust })
        #expect(built.summary.totalBytes == 800_000_000)
    }

    @Test func derivedDataIsReclaimableBuildArtifact() {
        var tree = FileTree()
        _ = tree.addNode(name: "Developer", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 10)
        let dd = tree.addNode(name: "DerivedData", parent: 0, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 10)
        _ = tree.addNode(name: "ModuleCache", parent: dd, isDirectory: false, logicalSize: 1_500_000_000, allocatedSize: 1_500_000_000, modifiedDaysSinceEpoch: 10)
        let both = tree.rollUpBoth()
        let built = DeveloperCatalog.build(
            tree: tree,
            root: URL(fileURLWithPath: "/Users/x/Library/Developer", isDirectory: true),
            totals: both.allocated
        )
        let hit = built.items.first { $0.nodeID == dd }
        #expect(hit != nil)
        #expect(hit?.category == .buildArtifacts)
        #expect(hit?.ecosystem == .xcode)
        #expect(hit?.reclaimability == .reclaimable)
        #expect(hit?.safety.level == .safe)
    }
}
