import Foundation
import Testing
@testable import DiskMapCore

/// Storage categories and cleanup advice (docs/MAC-FIXES-FROM-WINDOWS.md §3.1,
/// §3.2), ported from the Windows build's StorageClassifierTests.
@Suite("Storage classifier")
struct StorageClassifierTests {

    @Test(arguments: [
        ("/Users/me/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", false, "vms", CleanupAdvice.warn),
        ("/Users/me/Library/Application Support/Claude/vm_bundles/claudevm.bundle/rootfs.img", false, "vms", .warn),
        ("/Users/me/VMs/Ubuntu.utm", true, "vms", .warn),
        ("/Users/me/.android/avd/Pixel.avd/userdata.img", false, "vms", .warn),
        ("/Users/me/Library/Application Support/Google/Chrome/Default/History", false, "browsers", .warn),
        ("/Users/me/code/app/.git/objects/pack/pack-1.pack", false, "projects", .warn),
        ("/Applications/Xcode.app", true, "devtools", .warn),
        ("/Applications/Slack.app", true, "apps", .warn),
        ("/Users/me/.ollama/models/blobs/sha256-1", false, "ai", .review),
        ("/Users/me/Documents/models/llama.gguf", false, "ai", .review),
        ("/Users/me/Library/Caches/com.spotify.client/data", false, "caches", .fine),
        ("/Users/me/Library/Caches/rattler/cache/pkgs/x", false, "pkgcache", .fine),
        ("/Users/me/.cargo/registry/cache/x.crate", false, "pkgcache", .fine),
        ("/Users/me/.cargo/bin/cargo", false, "devtools", .review),
        ("/Users/me/Downloads/Installer.dmg", false, "installers", .fine),
        ("/Users/me/Downloads/notes.txt", false, "downloads", .fine),
        ("/Users/me/Pictures/IMG_1.heic", false, "media", .fine),
        ("/Users/me/Library/Mobile Documents/com~apple~CloudDocs/a.pdf", false, "cloud", .never),
        ("/System/Library/Kernels/kernel", false, "system", .never),
        ("/private/var/vm/sleepimage", false, "system", .never),
        ("/System/Volumes/Data/Users/me/Downloads/a.dmg", false, "installers", .fine),
        ("/Users/me/something.dat", false, "other", .fine),
    ])
    func classifiesPathsFromARealMac(_ path: String, _ isDirectory: Bool, _ expected: String, _ advice: CleanupAdvice) {
        let verdict = StorageClassifier.classify(path: path, isDirectory: isDirectory)
        #expect(verdict.storageClass.id == expected, "\(path)")
        #expect(verdict.advice == advice, "\(path)")
    }

    @Test func dependenciesInsideAProjectStayDependencies() {
        for path in ["/Users/me/Documents/code/app/node_modules/react/index.js",
                     "/Users/me/Desktop/site/.next/cache/x",
                     "/Users/me/Developer/api/.venv/lib/python3.12/site-packages/x.py"] {
            #expect(StorageClassifier.classify(path: path, isDirectory: false).storageClass.id == "deps", "\(path)")
        }
        #expect(StorageClassifier.classify(path: "/Users/me/Developer/api/main.py", isDirectory: false).storageClass.id == "projects")
    }

    @Test func riskyVerdictsSayWhatToDoInstead() {
        let docker = StorageClassifier.classify(path: "/Users/me/Library/Containers/com.docker.docker", isDirectory: true)
        #expect(docker.instead?.contains("docker system prune") == true)
        let git = StorageClassifier.classify(path: "/Users/me/code/app/.git", isDirectory: true)
        #expect(git.instead?.contains("git gc") == true)
        for path in ["/Applications/Slack.app", "/Users/me/Library/Safari", "/Users/me/Library/Mobile Documents",
                     "/Users/me/Parallels/Win.pvm"] {
            let verdict = StorageClassifier.classify(path: path, isDirectory: true)
            #expect(verdict.advice.isRisky, "\(path)")
            #expect(!(verdict.note ?? "").isEmpty && !(verdict.instead ?? "").isEmpty, "\(path)")
        }
    }

    @Test func rollupIsExclusiveAndSumsToTheRoot() {
        var tree = FileTree()
        func dir(_ name: String, _ parent: Int32) -> Int32 {
            tree.addNode(name: name, parent: parent, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        }
        func file(_ name: String, _ parent: Int32, _ bytes: Int64) {
            _ = tree.addNode(name: name, parent: parent, isDirectory: false, logicalSize: bytes, allocatedSize: bytes, modifiedDaysSinceEpoch: 1)
        }
        let root = dir("Macintosh HD", -1)
        file("kernel", dir("System", root), 15)
        let me = dir("me", dir("Users", root))
        let app = dir("app", dir("code", me))
        file("main.swift", app, 3)
        file("x.js", dir("node_modules", app), 7)
        file("Docker.raw", dir("com.docker.docker", dir("Containers", dir("Library", me))), 40)
        file("Installer.dmg", dir("Downloads", me), 4)
        file("loose.dat", me, 1)
        // A project found by its marker, outside any known folder name.
        let relay = dir("Relay", dir("Rust", me))
        file("Cargo.toml", relay, 2)
        file("x.rlib", dir("target", relay), 6)
        let totals = tree.rollUpBoth().allocated

        let rows = StorageClassifier.rollup(tree: tree, root: URL(fileURLWithPath: "/"), totals: totals)
        let bytes = Dictionary(uniqueKeysWithValues: rows.map { ($0.storageClass.id, $0.bytes) })
        #expect(bytes == ["system": 15, "projects": 5, "deps": 13, "vms": 40, "installers": 4, "other": 1])
        #expect(rows.reduce(0) { $0 + $1.bytes } == totals[0])
        #expect(rows.last?.storageClass.id == "other")
        #expect(rows.first?.storageClass.id == "vms")
        #expect(rows.first?.largestNode.map { tree.name(of: $0) } == "com.docker.docker")
    }

    @Test func aHomeOutsideUsersStillGetsHomeRules() {
        var tree = FileTree()
        let root = tree.addNode(name: "me", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        let caches = tree.addNode(name: "Caches", parent: tree.addNode(name: "Library", parent: root, isDirectory: true,
                                                                         logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1),
                                  isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        _ = tree.addNode(name: "c", parent: caches, isDirectory: false, logicalSize: 9, allocatedSize: 9, modifiedDaysSinceEpoch: 1)
        let rows = StorageClassifier.rollup(tree: tree, root: URL(fileURLWithPath: "/Volumes/Backup/me"),
                                            totals: tree.rollUpBoth().allocated, rootIsHome: true)
        #expect(rows.map(\.storageClass.id) == ["caches"])
    }

    @Test func theBundledTableDecodesWholeAndBadInputIsHarmless() throws {
        let url = try #require(DiskMapResources.url(forResource: "storage-categories", withExtension: "json"))
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let declared = (raw?["rules"] as? [Any])?.count ?? -1
        let table = StorageClassifier.loadTable()
        #expect(table.rules.count == declared, "a rule names an unknown class or advice")
        #expect(table.classes.count == 18)
        #expect(Set(table.notes.keys).isSuperset(of: Set(table.rules.compactMap(\.note))))
        let broken = StorageClassifier.loadTable(from: Data("{".utf8))
        #expect(broken.rules.isEmpty)
        #expect(broken.classes.map(\.id) == ["other"])
    }
}
