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

    /// An outer hit that holds nothing but an inner hit is the same size; the
    /// inner one must not be kept as well (19 GB counted twice on Windows, §3.4).
    @Test func equalSizedNestedHitsCountOnce() {
        var tree = FileTree()
        let root = tree.addNode(name: "Users", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        let user = tree.addNode(name: "dev", parent: root, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        let library = tree.addNode(name: "Library", parent: user, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        let android = tree.addNode(name: "Android", parent: library, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        let sdk = tree.addNode(name: "sdk", parent: android, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        _ = tree.addNode(name: "system.img", parent: sdk, isDirectory: false, logicalSize: 19_000_000_000,
                         allocatedSize: 19_000_000_000, modifiedDaysSinceEpoch: 1)
        let built = DeveloperCatalog.build(tree: tree, root: URL(fileURLWithPath: "/Users", isDirectory: true),
                                           totals: tree.rollUpBoth().allocated)
        #expect(built.items.count == 1)
        #expect(built.items.first?.nodeID == android)
        #expect(built.summary.totalBytes == 19_000_000_000)
    }

    /// "Where it lives" (MAC-FIXES-FROM-WINDOWS §4.3): developer bytes by
    /// folder, summing to the catalog, opening past single-child chains.
    @Test func whereItLivesRollsUpByFolder() {
        var tree = FileTree()
        func dir(_ name: String, _ parent: Int32) -> Int32 {
            tree.addNode(name: name, parent: parent, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        }
        func file(_ parent: Int32, _ bytes: Int64) {
            _ = tree.addNode(name: "f", parent: parent, isDirectory: false, logicalSize: bytes, allocatedSize: bytes, modifiedDaysSinceEpoch: 1)
        }
        let root = dir("Users", -1)
        let me = dir("me", root)
        let code = dir("code", me)
        let a = dir("a", code)
        file(dir("node_modules", a), 600)
        let b = dir("b", code)
        file(dir("node_modules", b), 300)
        file(dir(".rustup", me), 100)
        let catalog = DeveloperCatalog.build(tree: tree, root: URL(fileURLWithPath: "/Users"), totals: tree.rollUpBoth().allocated)
        let folders = DeveloperCatalog.folderRollup(catalog, tree: tree) { $0.reclaimability != .keep }
        #expect(folders.folders[0]?.bytes == catalog.summary.totalBytes)
        #expect(folders.folders[0]?.bytes == 1_000)
        // Users → me is one chain (me holds 100%); me splits 900 / 100, so it opens at code (90%).
        #expect(folders.autoStart() == code)
        #expect(folders.folders[code]?.children == [a, b])
        #expect(folders.folders[code]?.itemCount == 2)
        // .rustup is kept, so it never counts as removable.
        #expect(folders.folders[me]?.removableBytes == 900)
        #expect(folders.folders[a].flatMap { folders.folders[$0.children.first ?? -1]?.itemID } != nil)
    }

    /// Packages inside a tool's cache are not projects (332 of them inside
    /// ~/Library/Caches/Yarn on a real home); the cache is one item.
    @Test func packagesInsideAToolCacheAreNotProjects() {
        var tree = FileTree()
        func dir(_ name: String, _ parent: Int32) -> Int32 {
            tree.addNode(name: name, parent: parent, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        }
        let user = dir("me", dir("Users", -1))
        let v6 = dir("v6", dir("Yarn", dir("Caches", dir("Library", user))))
        for k in 0..<5 {
            _ = tree.addNode(name: "f", parent: dir("node_modules", dir("npm-pkg\(k)", v6)), isDirectory: false,
                             logicalSize: 1_000, allocatedSize: 1_000, modifiedDaysSinceEpoch: 1)
        }
        let uvTool = dir("site-packages", dir("lib", dir("tool", dir("tools", dir("uv", dir("share", dir(".local", user)))))))
        _ = tree.addNode(name: "f", parent: uvTool, isDirectory: false, logicalSize: 500, allocatedSize: 500, modifiedDaysSinceEpoch: 1)
        let built = DeveloperCatalog.build(tree: tree, root: URL(fileURLWithPath: "/Users"), totals: tree.rollUpBoth().allocated)
        #expect(built.projects.isEmpty)
        #expect(built.items.map(\.absolutePath) == ["/Users/me/Library/Caches/Yarn"])
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
