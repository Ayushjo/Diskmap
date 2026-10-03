import Foundation
import Testing
@testable import DiskMapCore

/// TASK-082 — staging a folder is measured from the scan tree when that gives
/// exactly what the walk would, and walked otherwise.
@Suite("Seeded staging measurement")
struct SeededProfileTests {

    final class Fixture {
        let base: URL
        let root: URL
        let marker: URL
        init() throws {
            base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("diskmap-seeded-\(UUID().uuidString)")
            root = base.appendingPathComponent("root")
            marker = base.appendingPathComponent("barrier/.marker")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit {
            // A chmod-000 folder must be opened up again before cleanup.
            chmod(root.appendingPathComponent("stage/locked").path, 0o755)
            try? FileManager.default.removeItem(at: base)
        }

        func url(_ rel: String) -> URL { root.appendingPathComponent(rel) }

        func put(_ rel: String, _ bytes: Int, fill: UInt8 = 7) throws {
            let target = url(rel)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: fill, count: bytes).write(to: target)
        }

        func clone(_ source: String, _ rel: String) throws {
            try FileManager.default.createDirectory(at: url(rel).deletingLastPathComponent(), withIntermediateDirectories: true)
            let cp = Process()
            cp.executableURL = URL(fileURLWithPath: "/bin/cp")
            cp.arguments = ["-c", url(source).path, url(rel).path]
            try cp.run()
            cp.waitUntilExit()
            #expect(cp.terminationStatus == 0)
        }

        /// Everything the walk distinguishes, in one folder ("stage").
        func populate() throws {
            try put("stage/plain.bin", 300_000)
            try put("stage/nested/deeper/more.bin", 70_000, fill: 3)
            try put("stage/empty.bin", 0)
            try FileManager.default.createDirectory(at: url("stage/empty-folder"), withIntermediateDirectories: true)
            // Hard links: both names inside, and one name outside.
            try put("stage/inside-a.bin", 50_000, fill: 4)
            #expect(link(url("stage/inside-a.bin").path, url("stage/nested/inside-b.bin").path) == 0)
            try put("stage/shared-out.bin", 40_000, fill: 5)
            try FileManager.default.createDirectory(at: url("outside"), withIntermediateDirectories: true)
            #expect(link(url("stage/shared-out.bin").path, url("outside/shared-out.bin").path) == 0)
            // A clone family split across the boundary, and an edited clone.
            var blocks = Data()
            for block in 0..<4 { blocks.append(Data(repeating: UInt8(0x60 + block), count: 16_384)) }
            try FileManager.default.createDirectory(at: url("stage/clones"), withIntermediateDirectories: true)
            try blocks.write(to: url("stage/clones/a.bin"))
            try clone("stage/clones/a.bin", "stage/clones/b.bin")
            try clone("stage/clones/a.bin", "outside/c.bin")
            try clone("stage/clones/a.bin", "stage/clones/edited.bin")
            let handle = try FileHandle(forWritingTo: url("stage/clones/edited.bin"))
            try handle.seek(toOffset: 16_384)
            try handle.write(contentsOf: Data(repeating: 0xEE, count: 16_384))
            try handle.synchronize()
            try handle.close()
            try FileManager.default.createSymbolicLink(at: url("stage/link-to-plain"), withDestinationURL: url("stage/plain.bin"))
        }

        /// A scan whose start event id is after every fixture write.
        func scanContext(_ mode: SharingMode) async throws -> StorageSharing.ScanContext {
            #expect(FSEventHistory.waitForPendingEvents(marker: marker))
            let result = await ScanEngine().scan(root: root, sharing: mode)
            return StorageSharing.ScanContext(
                tree: result.tree, rootPath: root.path, eventID: result.eventIDAtStart,
                volumeUUID: FSEventHistory.volumeUUID(forPath: FSEventHistory.realPath(root.path)),
                deniedIDs: Set(result.deniedDirectoryIDs), barrierMarker: marker, capturedAt: Date())
        }
    }

    @Test func theTreeGivesExactlyWhatTheWalkGives() async throws {
        let f = try Fixture()
        try f.populate()
        let context = try await f.scanContext(.full)
        let stage = f.url("stage").path
        let seeded = try #require(StorageSharing.seededProfile(context: context, path: stage))
        let walked = try #require(StorageSharing.profile(atPath: stage))
        #expect(seeded == walked)
        #expect(seeded.hardLinks.count == 2)
        #expect(seeded.sharedUnattributedBytes > 0, "the edited clone's shared blocks are not counted as freed")
        #expect(!seeded.clones.isEmpty)
    }

    @Test func aChangeAfterTheScanMeansAWalk() async throws {
        let f = try Fixture()
        try f.populate()
        let context = try await f.scanContext(.full)
        try f.put("stage/nested/new.bin", 12_345)
        #expect(StorageSharing.seededProfile(context: context, path: f.url("stage").path) == nil)
        // A sibling folder that did not change is still answered from the tree.
        try f.put("calm/one.bin", 1_000)
        let calm = try await f.scanContext(.full)
        try f.put("stage/again.bin", 99)
        #expect(StorageSharing.seededProfile(context: calm, path: f.url("calm").path) != nil)
    }

    @Test func tooManyFilesToAskAboutMeansAWalk() async throws {
        let f = try Fixture()
        try f.populate()
        let context = try await f.scanContext(.full)
        #expect(StorageSharing.seededProfile(context: context, path: f.url("stage").path, flaggedLimit: 1) == nil)
    }

    @Test func withoutEverySharingFactAPFSIsWalked() async throws {
        let f = try Fixture()
        try f.populate()
        for mode in [SharingMode.off, .refcount] {
            let context = try await f.scanContext(mode)
            #expect(StorageSharing.seededProfile(context: context, path: f.url("stage").path) == nil,
                    "\(mode) cannot see edited clones, so it would overstate what is freed")
        }
    }

    @Test func anUnreadableFolderInsideIsIncompleteBothWays() async throws {
        let f = try Fixture()
        try f.put("stage/locked/secret.bin", 5_000)
        try f.put("stage/open.bin", 8_000)
        chmod(f.url("stage/locked").path, 0o000)
        let context = try await f.scanContext(.full)
        let seeded = try #require(StorageSharing.seededProfile(context: context, path: f.url("stage").path))
        let walked = try #require(StorageSharing.profile(atPath: f.url("stage").path))
        #expect(seeded.isComplete == false)
        #expect(seeded == walked)
    }

    @Test func aFileOrAnUnknownPathIsNotSeeded() async throws {
        let f = try Fixture()
        try f.populate()
        let context = try await f.scanContext(.full)
        #expect(StorageSharing.seededProfile(context: context, path: f.url("stage/plain.bin").path) == nil)
        #expect(StorageSharing.seededProfile(context: context, path: "/tmp/not-in-this-scan") == nil)
    }

    @Test func theQueueUsesTheTreeAndSaysSo() async throws {
        let f = try Fixture()
        try f.populate()
        let context = try await f.scanContext(.full)
        let queue = CleanupQueue()
        await queue.setScanContext(context)
        #expect(await queue.stage(f.url("stage"), size: 1, reason: "test"))
        await queue.waitForMeasurements()
        let item = try #require(await queue.allItems().first)
        #expect(item.measurementSource == .scan(context.capturedAt))
        #expect(item.sharing == StorageSharing.profile(atPath: f.url("stage").path))

        // Without a context it walks, as before.
        let plain = CleanupQueue()
        #expect(await plain.stage(f.url("stage"), size: 1, reason: "test"))
        await plain.waitForMeasurements()
        #expect(await plain.allItems().first?.measurementSource == .walk)
    }
}
