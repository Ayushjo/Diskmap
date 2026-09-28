import Foundation
import Testing
@testable import DiskMapCore

/// Milestone 11 — Developer Storage v2, over one real scanned fixture.
@Suite("Developer Storage v2")
struct DeveloperV2Tests {

    final class Fixture {
        let root: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("diskmap-dev2-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        @discardableResult
        func put(_ rel: String, _ bytes: Int = 1_000, text: String? = nil, daysAgo: Int? = nil) throws -> URL {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let text { try text.write(to: url, atomically: true, encoding: .utf8) }
            else { try Data(repeating: 1, count: bytes).write(to: url) }
            if let daysAgo {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date().addingTimeInterval(-Double(daysAgo) * 86_400)], ofItemAtPath: url.path)
            }
            return url
        }
    }

    static let sha = String(repeating: "c", count: 40)

    private func build(_ f: Fixture) async -> DeveloperCatalogResult {
        let result = await ScanEngine().scan(root: f.root)
        return DeveloperCatalog.build(tree: result.tree, root: f.root, totals: result.tree.rollUpBoth().allocated)
    }

    private func item(_ r: DeveloperCatalogResult, endingWith suffix: String) -> DeveloperItem? {
        r.items.first { $0.absolutePath.hasSuffix(suffix) }
    }

    // MARK: TASK-051 — project roots by manifest

    @Test func nestedPackageBelongsToItsManifestNotItsParent() async throws {
        let f = try Fixture()
        try f.put("mono/package.json", text: "{}")
        try f.put("mono/pnpm-lock.yaml", text: "lockfileVersion: 9")
        try f.put("mono/packages/web/package.json", text: "{}")
        try f.put("mono/packages/web/src/deep/node_modules/x.js", 20_000)   // parent is "deep"
        let r = await build(f)
        let nm = try #require(item(r, endingWith: "src/deep/node_modules"))
        #expect(nm.projectName == "web", "nearest manifest, not the parent folder \"deep\"")
        #expect(nm.projectManifest == "package.json")
    }

    @Test func noManifestFallsBackToParent() async throws {
        let f = try Fixture()
        try f.put("loose/app/node_modules/x.js", 20_000)
        let r = await build(f)
        #expect(item(r, endingWith: "app/node_modules")?.projectName == "app")
    }

    // MARK: TASK-052 — rebuild cost and lockfiles

    @Test func lockfileAtTheWorkspaceRootPinsANestedPackage() async throws {
        let f = try Fixture()
        try f.put("mono/.git/config", text: "[core]\n")
        try f.put("mono/package.json", text: "{}")
        try f.put("mono/pnpm-lock.yaml", text: "x")
        try f.put("mono/packages/api/package.json", text: "{}")
        try f.put("mono/packages/api/node_modules/x.js", 20_000)
        let r = await build(f)
        let nm = try #require(item(r, endingWith: "api/node_modules"))
        #expect(nm.lockfile == "pnpm-lock.yaml")
        #expect(nm.rebuildCost == .networked)
    }

    @Test func dependenciesWithoutALockfileAreUnpinned() async throws {
        let f = try Fixture()
        try f.put("pyproj/pyproject.toml", text: "[project]")
        try f.put("pyproj/.venv/lib/x.py", 20_000)
        try f.put("pinned/pyproject.toml", text: "[project]")
        try f.put("pinned/requirements.txt", text: "requests==2.32.0")
        try f.put("pinned/.venv/lib/x.py", 20_000)
        let r = await build(f)
        #expect(item(r, endingWith: "pyproj/.venv")?.rebuildCost == .networkedUnpinned)
        #expect(item(r, endingWith: "pinned/.venv")?.rebuildCost == .networked)
        #expect(r.summary.unpinnedBytes > 0)
    }

    @Test func buildOutputIsCheapAndBytecodeIsFree() async throws {
        let f = try Fixture()
        try f.put("rust/Cargo.toml", text: "[package]")
        try f.put("rust/target/debug/app", 30_000)
        try f.put("py/pyproject.toml", text: "x")
        try f.put("py/pkg/__pycache__/m.pyc", 5_000)
        let r = await build(f)
        #expect(item(r, endingWith: "rust/target")?.rebuildCost == .cheap)
        #expect(item(r, endingWith: "pkg/__pycache__")?.rebuildCost == .free)
    }

    // MARK: TASK-056 — ageing

    @Test func projectAgeIgnoresGeneratedFolders() async throws {
        let f = try Fixture()
        try f.put("old/package.json", text: "{}", daysAgo: 400)
        try f.put("old/src/index.js", 2_000, daysAgo: 400)
        try f.put("old/node_modules/fresh.js", 50_000, daysAgo: 1)   // reinstalled yesterday
        let r = await build(f)
        let project = try #require(r.projects.first { $0.name == "old" })
        let age = AgeMap.today() - project.lastSourceDay
        #expect(age >= 399, "a fresh node_modules must not make an abandoned project look active")
        #expect(r.summary.staleProjectCount >= 1)
        #expect(r.summary.staleReclaimableBytes > 0)
    }

    // MARK: TASK-053 / TASK-054 — git state and ignored bytes

    @Test func projectsReportTheirRepositoryState() async throws {
        let f = try Fixture()
        try f.put("repo/.git/config", text: "[remote \"origin\"]\n\turl = x\n")
        try f.put("repo/.git/refs/heads/main", text: Self.sha + "\n")
        try f.put("repo/.git/refs/remotes/origin/main", text: Self.sha + "\n")
        try f.put("repo/.gitignore", text: "node_modules/\n")
        try f.put("repo/package.json", text: "{}")
        try f.put("repo/package-lock.json", text: "{}")
        try f.put("repo/node_modules/big.js", 80_000)
        let r = await build(f)
        let project = try #require(r.projects.first { $0.name == "repo" })
        #expect(project.git == .inSync)
        #expect(project.repositoryPath?.hasSuffix("/repo") == true)
        #expect((project.ignoredBytes ?? 0) >= 80_000)
    }

    // MARK: Safety and scope

    @Test func foldersInsideApplicationBundlesAreNeverOffered() async throws {
        let f = try Fixture()
        try f.put("Tools/Editor.app/Contents/Resources/app/node_modules/x.js", 40_000)
        let r = await build(f)
        #expect(!r.items.contains { $0.absolutePath.contains(".app/") })
        #expect(DeveloperCatalog.isInsideApplicationBundle("/A/Editor.app/Contents/node_modules"))
        #expect(!DeveloperCatalog.isInsideApplicationBundle("/A/my.app-builder/node_modules"))
    }

    @Test func installedPythonLibrariesAreOneDependencyFolder() async throws {
        let f = try Fixture()
        try f.put("env/lib/python3.12/site-packages/pandas/core/__pycache__/a.pyc", 20_000)
        try f.put("env/lib/python3.12/site-packages/numpy/__pycache__/b.pyc", 20_000)
        let r = await build(f)
        #expect(item(r, endingWith: "site-packages")?.category == .dependencies)
        #expect(!r.items.contains { $0.absolutePath.hasSuffix("__pycache__") }, "swallowed by site-packages")
    }

    // MARK: TASK-055 — recipes

    @Test func recipesMatchTheirTools() {
        let home = "/Users/x"
        #expect(CleanupRecipes.recipe(forPath: home + "/Library/Containers/com.docker.docker")?.id == "docker")
        #expect(CleanupRecipes.recipe(forPath: home + "/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")?.trashIsUnsafe == true)
        #expect(CleanupRecipes.recipe(forPath: home + "/Library/Developer/CoreSimulator")?.id == "simulators")
        #expect(CleanupRecipes.recipe(forPath: home + "/.npm")?.command == "npm cache clean --force")
        #expect(CleanupRecipes.recipe(forPath: home + "/go/pkg/mod")?.id == "go-modules")
        #expect(CleanupRecipes.recipe(forPath: home + "/Projects/app/node_modules") == nil)
    }

    @Test func everyBundledRecipeDecodes() throws {
        let url = try #require(Bundle.module.url(forResource: "cleanup-recipes", withExtension: "json"))
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let entries = try #require(raw?["recipes"] as? [[String: Any]])
        #expect(CleanupRecipes.bundled.count == entries.count)
        #expect(CleanupRecipes.bundled.allSatisfy { !$0.command.isEmpty && !$0.why.isEmpty })
    }

    @Test func dockerDesktopDataIsNowListedWithItsRecipe() async throws {
        let f = try Fixture()
        try f.put("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", 60_000)
        let r = await build(f)
        let docker = try #require(item(r, endingWith: "com.docker.docker"))
        #expect(docker.recipe?.id == "docker")
        #expect(docker.recipe?.trashIsUnsafe == true)
    }
}
