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

    /// Tool caches found on a real home were missed (ccache, ~/.cache/uv) or
    /// split into 145 fake "projects" (site-packages inside rattler's cache).
    @Test func toolCachesAreOneItemEachAndLookalikesAreIgnored() {
        var tree = FileTree()
        func dir(_ name: String, _ parent: Int32) -> Int32 {
            tree.addNode(name: name, parent: parent, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 100)
        }
        func file(_ parent: Int32, _ bytes: Int64) {
            _ = tree.addNode(name: "f", parent: parent, isDirectory: false, logicalSize: bytes, allocatedSize: bytes, modifiedDaysSinceEpoch: 100)
        }
        let root = dir("Users", -1)
        let user = dir("dev", root)
        let library = dir("Library", user)
        let caches = dir("Caches", library)
        let rattler = dir("rattler", caches)
        let pkgs = dir("pkgs", rattler)
        let pkg = dir("numpy-2.0", pkgs)
        file(dir("site-packages", pkg), 3_000_000_000)
        file(dir("ccache", caches), 2_000_000_000)
        let pnpm = dir("pnpm", library)
        file(dir("node_modules", dir("store", pnpm)), 1_000_000_000)
        file(dir("uv", dir(".cache", user)), 500_000_000)
        // A project's own "uv" folder and the pnpm package are not tool caches.
        let app = dir("app", user)
        file(dir("uv", app), 400_000_000)
        file(dir("pnpm", dir("node_modules", app)), 300_000_000)

        let built = DeveloperCatalog.build(tree: tree, root: URL(fileURLWithPath: "/Users", isDirectory: true),
                                           totals: tree.rollUpBoth().allocated)
        let byPath = Dictionary(built.items.map { ($0.absolutePath, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byPath["/Users/dev/Library/Caches/rattler"]?.category == .caches)
        #expect(byPath["/Users/dev/Library/Caches/ccache"]?.reclaimability == .reclaimable)
        #expect(byPath["/Users/dev/Library/pnpm"]?.category == .caches)
        #expect(byPath["/Users/dev/.cache/uv"]?.category == .caches)
        #expect(byPath["/Users/dev/app/uv"] == nil)
        #expect(byPath["/Users/dev/app/node_modules"] != nil)
        #expect(!built.items.contains { $0.absolutePath.contains("/rattler/") || $0.absolutePath.contains("/pnpm/") })
        #expect(!built.projects.contains { $0.name == "numpy-2.0" })
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

    /// The rules are data now (developer-rules.json). A typo in a category
    /// or ecosystem name would silently drop that rule, so every entry must
    /// decode.
    @Test func everyBundledRuleDecodes() throws {
        let url = try #require(Bundle.module.url(forResource: "developer-rules", withExtension: "json"))
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let entries = try #require(raw?["rules"] as? [[String: Any]])
        #expect(entries.count > 0)
        #expect(DeveloperCatalog.loadedRuleCount == entries.count, "a rule failed to decode")
    }

    @Test func malformedRulesYieldNothingRatherThanCrash() {
        #expect(DeveloperCatalog.loadRules(from: Data("{".utf8)).isEmpty)
        let unknownCategory = #"{"rules":[{"names":["x"],"category":"nope","ecosystem":"node","reclaimability":"keep","isToolRoot":true,"projectFromParent":false,"whyLarge":"-"}]}"#
        #expect(DeveloperCatalog.loadRules(from: Data(unknownCategory.utf8)).isEmpty)
    }
}
