import Foundation
import Testing
@testable import DiskMapCore

/// Regression cover for a walk-termination race found while stabilising the
/// trust pass (2026-09-25). It predates the trust pass: measured on the
/// unmodified parent commit, the existing fixture test failed 3 runs in 15.
///
/// The sequence: the publisher takes a directory's batch off the queue and
/// unlocks. Before it re-locks to append that directory's children, a worker
/// fails to `open()` an unreadable sibling and drops `inflight` to 0 while
/// `jobs` and `batches` happen to be empty. Termination fired, every worker
/// exited, and the child jobs the publisher appended a moment later were
/// never scanned — the scan returned a tree missing a whole subtree, with no
/// error raised anywhere. Totals were silently wrong.
///
/// Unreadable directories are what make the window reachable, because
/// `noteUnopenedDirectory` decrements `inflight` without ever adding a batch.
@Suite("Scan termination")
struct ScanTerminationTests {

    private func makeRaceFixture() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskmap-termination-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // A chain deep enough that losing it is unmistakable in the count.
        var chain = root.appendingPathComponent("chain")
        try fm.createDirectory(at: chain, withIntermediateDirectories: true)
        for level in 0..<6 {
            chain = chain.appendingPathComponent("level\(level)")
            try fm.createDirectory(at: chain, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: chain.appendingPathComponent("leaf\(level).txt"))
        }

        // Several unreadable siblings: each one is a worker that finishes
        // without producing a batch, which is exactly the trigger.
        for i in 0..<4 {
            let denied = root.appendingPathComponent("denied\(i)")
            try fm.createDirectory(at: denied, withIntermediateDirectories: true)
            try Data("nope".utf8).write(to: denied.appendingPathComponent("secret.txt"))
            try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        }
        return root
    }

    private func restore(_ root: URL) {
        for i in 0..<4 {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: root.appendingPathComponent("denied\(i)").path
            )
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// The walk must never end while the publisher still holds work. Repeated
    /// because the failure is a race: a single pass passed most of the time
    /// even before the fix.
    @Test func deepSubtreeSurvivesUnreadableSiblings() async throws {
        let root = try makeRaceFixture()
        defer { restore(root) }

        var counts = Set<Int>()
        for _ in 0..<40 {
            let tree = await ScanEngine().scan(root: root).tree
            // The deepest leaf is the first thing lost when termination fires
            // early, because it is furthest down the publisher's chain.
            let deepest = tree.node(named: "leaf5.txt", parentNamed: "level5")
            #expect(deepest != nil, "deepest leaf missing — the walk ended early")
            counts.insert(tree.count)
        }
        // Every run must agree. A race shows up as more than one node count.
        #expect(counts.count == 1, "node count varied across identical scans: \(counts.sorted())")
    }

    /// The unreadable directories themselves must still be recorded (they are
    /// real directories, just unopenable) and must contribute no children.
    @Test func unreadableDirectoriesAreRecordedButEmpty() async throws {
        let root = try makeRaceFixture()
        defer { restore(root) }

        let tree = await ScanEngine().scan(root: root).tree
        for i in 0..<4 {
            let denied = try #require(
                tree.node(named: "denied\(i)", parentNamed: root.lastPathComponent)
            )
            #expect(tree.isDirectory[Int(denied)])
            #expect(tree.firstChild[Int(denied)] == -1)
        }
        #expect(tree.node(named: "secret.txt", parentNamed: "denied0") == nil)
    }

    /// Second, separate hang (2026-09-28). `ScanEngine.scan` ran the blocking
    /// walk on Swift's cooperative pool and its workers on GCD's global queue.
    /// With more scans in flight than cores, every pool slot held a walk
    /// blocked on its workers, the workers could never be scheduled, and every
    /// scan waited forever: 11 stuck in `group.wait()`, zero workers alive.
    /// Oversubscribe on purpose. Verified against the unfixed commit: this
    /// test hung for over 10 minutes with that exact thread signature, and
    /// passes in about 0.3 s with the fix. NOTE: a full regression shows up
    /// as a HUNG suite, not a failure — the time limit is enforced on the same
    /// cooperative pool the bug starves, so it cannot fire. The limit only
    /// catches partial starvation. If `scripts/test.sh` ever stops returning,
    /// suspect this first.
    @Test(.timeLimit(.minutes(1)))
    func manyConcurrentScansAllFinish() async throws {
        let root = try makeRaceFixture()
        defer { restore(root) }

        let concurrent = ProcessInfo.processInfo.activeProcessorCount * 2 + 4
        let counts = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<concurrent {
                group.addTask { await ScanEngine().scan(root: root).tree.count }
            }
            var all: [Int] = []
            for await count in group { all.append(count) }
            return all
        }
        #expect(counts.count == concurrent)
        #expect(Set(counts).count == 1, "concurrent scans disagreed: \(Set(counts).sorted())")
    }
}
