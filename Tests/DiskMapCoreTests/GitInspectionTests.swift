import Foundation
import Testing
@testable import DiskMapCore

/// TASK-053 / TASK-054. Fixtures are written by hand — config, loose refs,
/// packed refs, ignore files — so the tests exercise exactly the files DiskMap
/// reads and need no `git` binary.
@Suite("Git inspection")
struct GitInspectionTests {

    final class Repo {
        let path: String
        init() throws {
            path = NSTemporaryDirectory() + "diskmap-git-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: path + "/.git/refs/heads", withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(atPath: path) }
        func write(_ relative: String, _ text: String) throws {
            let full = path + "/" + relative
            try FileManager.default.createDirectory(
                atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: full, atomically: true, encoding: .utf8)
        }
    }

    static let shaA = String(repeating: "a", count: 40)
    static let shaB = String(repeating: "b", count: 40)

    @Test func folderWithoutGitIsNotARepository() throws {
        let dir = NSTemporaryDirectory() + "diskmap-nogit-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(GitInspector.inspect(repositoryPath: dir) == .notARepository)
    }

    @Test func repositoryWithoutRemoteMayBeTheOnlyCopy() throws {
        let repo = try Repo()
        try repo.write(".git/config", "[core]\n\trepositoryformatversion = 0\n")
        try repo.write(".git/refs/heads/main", Self.shaA + "\n")
        #expect(GitInspector.inspect(repositoryPath: repo.path) == .noRemote)
    }

    @Test func matchingBranchesAreInSync() throws {
        let repo = try Repo()
        try repo.write(".git/config", "[remote \"origin\"]\n\turl = git@example.com:x.git\n")
        try repo.write(".git/refs/heads/main", Self.shaA + "\n")
        try repo.write(".git/refs/remotes/origin/main", Self.shaA + "\n")
        #expect(GitInspector.inspect(repositoryPath: repo.path) == .inSync)
        #expect(GitInspector.inspect(repositoryPath: repo.path).isBackedUp)
    }

    /// Unpushed commits, or a branch never pushed at all.
    @Test func differingAndUnpushedBranchesAreNamed() throws {
        let repo = try Repo()
        try repo.write(".git/config", "[remote \"origin\"]\n\turl = x\n")
        try repo.write(".git/refs/heads/main", Self.shaB + "\n")
        try repo.write(".git/refs/remotes/origin/main", Self.shaA + "\n")
        try repo.write(".git/refs/heads/feature/login", Self.shaA + "\n")   // never pushed
        #expect(GitInspector.inspect(repositoryPath: repo.path) == .differs(branches: ["feature/login", "main"]))
    }

    /// `git gc` moves refs into packed-refs; a loose ref overrides a packed one.
    @Test func packedRefsAreRead() throws {
        let repo = try Repo()
        try repo.write(".git/config", "[remote \"origin\"]\n\turl = x\n")
        try repo.write(".git/packed-refs", """
            # pack-refs with: peeled fully-peeled sorted
            \(Self.shaA) refs/heads/main
            \(Self.shaA) refs/remotes/origin/main
            ^\(Self.shaB)
            """)
        #expect(GitInspector.inspect(repositoryPath: repo.path) == .inSync)
        try repo.write(".git/refs/heads/main", Self.shaB + "\n")
        #expect(GitInspector.inspect(repositoryPath: repo.path) == .differs(branches: ["main"]))
    }

    @Test func worktreeGitFileIsUnknownNotAssumedSafe() throws {
        let dir = NSTemporaryDirectory() + "diskmap-wt-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "gitdir: /elsewhere/.git/worktrees/x\n".write(toFile: dir + "/.git", atomically: true, encoding: .utf8)
        if case .unknown = GitInspector.inspect(repositoryPath: dir) {} else {
            Issue.record("a worktree must not be reported as backed up")
        }
        #expect(!GitInspector.inspect(repositoryPath: dir).isBackedUp)
    }

    @Test func nonOriginRemoteIsUsedWhenOriginIsAbsent() throws {
        let repo = try Repo()
        try repo.write(".git/config", "[remote \"upstream\"]\n\turl = x\n")
        try repo.write(".git/refs/heads/main", Self.shaA + "\n")
        try repo.write(".git/refs/remotes/upstream/main", Self.shaA + "\n")
        #expect(GitInspector.inspect(repositoryPath: repo.path) == .inSync)
    }
}

@Suite("gitignore")
struct GitIgnoreTests {

    private func rules(_ text: String, base: String = "") -> GitIgnoreRules {
        var r = GitIgnoreRules()
        r.rules = GitIgnoreRules.parse(text, base: base)
        return r
    }

    @Test func literalNamesMatchAtAnyDepth() {
        let r = rules("node_modules\n.DS_Store\n")
        #expect(r.verdict(relativePath: "node_modules", name: "node_modules", isDirectory: true) == true)
        #expect(r.verdict(relativePath: "a/b/node_modules", name: "node_modules", isDirectory: true) == true)
        #expect(r.verdict(relativePath: "src/main.swift", name: "main.swift", isDirectory: false) == nil)
    }

    @Test func extensionGlobsAndClasses() {
        let r = rules("*.log\n*.py[cod]\n")
        #expect(r.verdict(relativePath: "x/debug.log", name: "debug.log", isDirectory: false) == true)
        #expect(r.verdict(relativePath: "m.pyc", name: "m.pyc", isDirectory: false) == true)
        #expect(r.verdict(relativePath: "m.py", name: "m.py", isDirectory: false) == nil)
    }

    @Test func trailingSlashMeansDirectoriesOnly() {
        let r = rules("build/\n")
        #expect(r.verdict(relativePath: "build", name: "build", isDirectory: true) == true)
        #expect(r.verdict(relativePath: "build", name: "build", isDirectory: false) == nil)
    }

    @Test func slashesAnchorToTheIgnoreFilesFolder() {
        let r = rules("/dist\ndocs/generated\n")
        #expect(r.verdict(relativePath: "dist", name: "dist", isDirectory: true) == true)
        #expect(r.verdict(relativePath: "pkg/dist", name: "dist", isDirectory: true) == nil)
        #expect(r.verdict(relativePath: "docs/generated", name: "generated", isDirectory: true) == true)
        #expect(r.verdict(relativePath: "x/docs/generated", name: "generated", isDirectory: true) == nil)
    }

    @Test func doubleStarForms() {
        let r = rules("**/cache\nlogs/**\na/**/z\n")
        #expect(r.verdict(relativePath: "cache", name: "cache", isDirectory: true) == true)
        #expect(r.verdict(relativePath: "p/q/cache", name: "cache", isDirectory: true) == true)
        #expect(r.verdict(relativePath: "logs/x/y.txt", name: "y.txt", isDirectory: false) == true)
        #expect(r.verdict(relativePath: "a/z", name: "z", isDirectory: true) == true)
        #expect(r.verdict(relativePath: "a/b/c/z", name: "z", isDirectory: true) == true)
    }

    /// The regex prefilter must never reject a real match.
    @Test func requiredLiteralNeverExcludesAMatch() {
        #expect(GitIgnoreRules.longestLiteral("**/cache") == "cache")
        #expect(GitIgnoreRules.longestLiteral("*.py[cod]") == ".py")
        #expect(GitIgnoreRules.longestLiteral("lib/node_modules/**/tsconfig.json") == "lib/node_modules/")
        let r = rules("**/node_modules/\nlib/**/tsconfig.json\n._*\n")
        #expect(r.verdict(relativePath: "node_modules", name: "node_modules", isDirectory: true) == true)
        #expect(r.verdict(relativePath: "lib/tsconfig.json", name: "tsconfig.json", isDirectory: false) == true)
        #expect(r.verdict(relativePath: "x/._foo", name: "._foo", isDirectory: false) == true)
        // requiredName must not reject a path ending in the right name.
        #expect(r.verdict(relativePath: "lib/a/b/tsconfig.json", name: "tsconfig.json", isDirectory: false) == true)
        #expect(r.verdict(relativePath: "lib/a/b/other.json", name: "other.json", isDirectory: false) == nil)
    }

    /// Last match wins across the index: a later literal rule overrides an
    /// earlier extension rule and vice versa.
    @Test func indexPreservesLastMatchOrder() {
        let r = rules("*.env\n!prod.env\n*.env\n")
        #expect(r.verdict(relativePath: "prod.env", name: "prod.env", isDirectory: false) == true)
        let s = rules("*.env\n!prod.env\n")
        #expect(s.verdict(relativePath: "prod.env", name: "prod.env", isDirectory: false) == false)
    }

    @Test func lastMatchWinsAndNegationReincludes() {
        let r = rules("*.env\n!example.env\n")
        #expect(r.verdict(relativePath: "prod.env", name: "prod.env", isDirectory: false) == true)
        #expect(r.verdict(relativePath: "example.env", name: "example.env", isDirectory: false) == false)
    }

    @Test func nestedIgnoreFileOnlyAppliesBelowItsFolder() {
        let r = rules("tmp\n", base: "packages/web")
        #expect(r.verdict(relativePath: "packages/web/tmp", name: "tmp", isDirectory: true) == true)
        #expect(r.verdict(relativePath: "tmp", name: "tmp", isDirectory: true) == nil)
    }

    @Test func commentsBlanksAndEscapes() {
        let r = rules("# comment\n\n\\#notacomment\n")
        #expect(r.rules.count == 1)
        #expect(r.verdict(relativePath: "#notacomment", name: "#notacomment", isDirectory: false) == true)
    }

    /// End to end over a real scanned repository: ignored folders count once
    /// (at the top-most ignored node), a nested ignore file applies, and a
    /// folder git would not descend into cannot be re-included.
    @Test func ignoredBytesOverARealTree() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("diskmap-ign-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func put(_ rel: String, _ bytes: Int) throws {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: bytes).write(to: url)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "node_modules/\n*.log\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try put("node_modules/lib/index.js", 300_000)
        try put("server.log", 100_000)
        try put("src/app.js", 50_000)
        try put("packages/web/.gitignore", 0)
        try "dist\n".write(to: root.appendingPathComponent("packages/web/.gitignore"), atomically: true, encoding: .utf8)
        try put("packages/web/dist/bundle.js", 200_000)
        try put("packages/api/dist/keep.js", 70_000)   // not ignored: rule is scoped to web

        let tree = await ScanEngine().scan(root: root).tree
        let totals = tree.rollUpBoth().allocated
        let result = GitIgnoreRules.ignoredBytes(tree: tree, repositoryID: 0, repositoryPath: root.path, totals: totals)

        func bytes(_ name: String, under parent: String) throws -> Int64 {
            totals[Int(try #require(tree.node(named: name, parentNamed: parent)))]
        }
        let expected = try bytes("node_modules", under: root.lastPathComponent)
            + bytes("server.log", under: root.lastPathComponent)
            + bytes("dist", under: "web")
        #expect(result.ignoredBytes == expected)
        #expect(result.ignoreFileCount == 2)
    }
}
