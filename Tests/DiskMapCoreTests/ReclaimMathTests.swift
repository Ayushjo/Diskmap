import Foundation
import Testing
@testable import DiskMapCore

/// TASK-038 — the figure shown at the moment of the destructive action must be
/// what emptying the Trash will actually free. Every fixture here is real APFS
/// state (clones via `cp -c`, hard links via `link(2)`), never a mock: the
/// point is to check our reading of what the filesystem reports.
@Suite("Reclaim math")
struct ReclaimMathTests {

    // MARK: - Fixtures

    final class Fixture {
        let dir: String
        init() throws {
            dir = NSTemporaryDirectory() + "DiskMap-reclaim-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(atPath: dir) }

        @discardableResult
        func file(_ name: String, bytes: Int = 1_048_576, fill: UInt8 = 0xAB) -> String {
            let path = dir + "/" + name
            try? FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: Data(repeating: fill, count: bytes))
            let fd = open(path, O_RDONLY); fsync(fd); close(fd)
            return path
        }

        @discardableResult
        func clone(_ source: String, _ name: String) throws -> String {
            let path = dir + "/" + name
            let cp = Process()
            cp.executableURL = URL(fileURLWithPath: "/bin/cp")
            cp.arguments = ["-c", source, path]
            try cp.run()
            cp.waitUntilExit()
            #expect(cp.terminationStatus == 0)
            return path
        }

        @discardableResult
        func hardLink(_ source: String, _ name: String) -> String {
            let path = dir + "/" + name
            try? FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            #expect(link(source, path) == 0)
            return path
        }

        func allocated(_ path: String) -> Int64 {
            var info = stat()
            lstat(path, &info)
            return Int64(info.st_blocks) * 512
        }
    }

    /// Stages and waits for the background measurement, so the estimate
    /// read next is the real one, not the provisional caller-supplied size.
    private func stage(_ queue: CleanupQueue, _ path: String, size: Int64 = 0) async -> Bool {
        let added = await queue.stage(URL(fileURLWithPath: path), size: size, reason: "test")
        await queue.waitForMeasurements()
        return added
    }

    // MARK: - Reading the filesystem

    /// The single-object record layout, checked field by field against lstat.
    @Test func factsMatchLstat() throws {
        let f = try Fixture()
        let plain = f.file("plain.bin")
        let first = f.file("linked.bin")
        f.hardLink(first, "linked-2.bin")
        for path in [plain, first] {
            let facts = try #require(StorageSharing.facts(atPath: path))
            var info = stat()
            lstat(path, &info)
            #expect(facts.inode == UInt64(info.st_ino))
            #expect(facts.device == Int32(info.st_dev))
            #expect(facts.linkCount == Int(info.st_nlink))
            #expect(facts.allocated == Int64(info.st_blocks) * 512)
            #expect(!facts.isDirectory)
        }
    }

    /// The bulk walker must see exactly the files lstat sees, with the same
    /// sizes — otherwise its offsets are wrong.
    @Test func directoryWalkAgreesWithLstat() throws {
        let f = try Fixture()
        f.file("tree/a.bin", bytes: 300_000)
        f.file("tree/sub/b.bin", bytes: 700_000)
        f.file("tree/sub/deeper/c.bin", bytes: 50_000)
        let profile = try #require(StorageSharing.profile(atPath: f.dir + "/tree"))
        let expected = ["tree/a.bin", "tree/sub/b.bin", "tree/sub/deeper/c.bin"]
            .map { f.allocated(f.dir + "/" + $0) }
            .reduce(0, +)
        #expect(profile.fileCount == 3)
        #expect(profile.allocatedBytes == expected)
        #expect(profile.isComplete)
        #expect(profile.usesFilesystemAccounting)
    }

    // MARK: - The queue

    /// The APFS gate must actually open on the volume these tests run on,
    /// or every other test here would be checking the fallback path.
    @Test func tempDirectoryIsAPFS() throws {
        let f = try Fixture()
        #expect(StorageSharing.isAPFS(f.dir))
    }

    @Test func plainFileFreesItsOnDiskSize() async throws {
        let f = try Fixture()
        let path = f.file("plain.bin")
        let queue = CleanupQueue()
        #expect(await stage(queue, path, size: 1))
        let estimate = await queue.reclaimEstimate()
        #expect(estimate.bytes == f.allocated(path))
        #expect(!estimate.isLowerBound)
    }

    /// The flagged bug: a clone staged from any screen other than Duplicates
    /// used to count at full size. Now the queue finds the sharing itself.
    @Test func cloneStagedWithoutAnyHintFreesNothingAlone() async throws {
        let f = try Fixture()
        let original = f.file("original.bin")
        let copy = try f.clone(original, "copy.bin")
        let queue = CleanupQueue()
        #expect(await stage(queue, copy, size: 1_048_576))   // no sharesStorageGroup
        let alone = await queue.reclaimEstimate()
        #expect(alone.bytes == 0)
        #expect(alone.heldByUnqueuedCopies == f.allocated(original))

        #expect(await stage(queue, original, size: 1_048_576))
        let both = await queue.reclaimEstimate()
        #expect(both.bytes == f.allocated(original), "shared blocks counted once, not twice")
        #expect(both.heldByUnqueuedCopies == 0)
    }

    @Test func threeCloneFamilyFreesOnlyWhenAllAreQueued() async throws {
        let f = try Fixture()
        let a = f.file("a.bin")
        let b = try f.clone(a, "b.bin")
        let c = try f.clone(a, "c.bin")
        let queue = CleanupQueue()
        #expect(await stage(queue, a))
        #expect(await stage(queue, b))
        #expect(await queue.totalSize() == 0)
        #expect(await stage(queue, c))
        #expect(await queue.totalSize() == f.allocated(a))
    }

    /// Plan acceptance: staging 4 of 5 hard links frees 0; the 5th frees the
    /// file once.
    @Test func hardLinksFreeOnlyWhenEveryNameIsQueued() async throws {
        let f = try Fixture()
        let first = f.file("h1.bin")
        let names = [first] + (2...5).map { f.hardLink(first, "h\($0).bin") }
        let queue = CleanupQueue()
        for name in names.prefix(4) { #expect(await stage(queue, name)) }
        let partial = await queue.reclaimEstimate()
        #expect(partial.bytes == 0)
        #expect(partial.heldByUnqueuedCopies == f.allocated(first))

        #expect(await stage(queue, names[4]))
        #expect(await queue.totalSize() == f.allocated(first))
    }

    /// pnpm hard-links every file in node_modules to a global store, so
    /// trashing node_modules frees almost nothing. The app used to promise
    /// the folder's full size.
    @Test func folderHardLinkedFromOutsideFreesNothingForThoseFiles() async throws {
        let f = try Fixture()
        let stored = f.file("store/lodash.js", bytes: 600_000)
        f.hardLink(stored, "project/node_modules/lodash.js")
        let own = f.file("project/node_modules/.modules.yaml", bytes: 40_000)
        let queue = CleanupQueue()
        #expect(await stage(queue, f.dir + "/project/node_modules"))
        let estimate = await queue.reclaimEstimate()
        #expect(estimate.bytes == f.allocated(own), "only the unlinked file is freed")
        #expect(estimate.heldByUnqueuedCopies == f.allocated(stored))
    }

    /// Partially shared blocks cannot be attributed, so the figure is a floor.
    @Test func editedClonePairIsReportedAsALowerBound() async throws {
        let f = try Fixture()
        let a = f.file("a.bin")
        let b = try f.clone(a, "b.bin")
        let handle = try #require(FileHandle(forWritingAtPath: b))
        try handle.seek(toOffset: 524_288)
        try handle.write(contentsOf: Data(repeating: 0x33, count: 65_536))
        try handle.synchronize()
        try handle.close()

        let queue = CleanupQueue()
        #expect(await stage(queue, a))
        #expect(await stage(queue, b))
        let estimate = await queue.reclaimEstimate()
        #expect(estimate.isLowerBound)
        #expect(estimate.sharedUnattributed > 0)
        #expect(estimate.bytes > 0 && estimate.bytes < f.allocated(a) * 2)
    }

    /// A folder and a file inside it both staged: counted once.
    @Test func itemInsideAQueuedFolderIsNotCountedTwice() async throws {
        let f = try Fixture()
        let inner = f.file("folder/inner.bin")
        f.file("folder/other.bin")
        let queue = CleanupQueue()
        #expect(await stage(queue, inner))
        let innerOnly = await queue.totalSize()
        #expect(await stage(queue, f.dir + "/folder"))
        let total = await queue.totalSize()
        #expect(total == f.allocated(inner) + f.allocated(f.dir + "/folder/other.bin"))
        #expect(total > innerOnly)
    }

    // MARK: - Measuring in the background

    /// Staging must return at once; a big folder is measured afterwards and
    /// the estimate says so until it is done.
    @Test func stagingReturnsBeforeMeasurementAndFlagsTheEstimate() async throws {
        let f = try Fixture()
        for i in 0..<400 { f.file("big/f\(i).bin", bytes: 4_096) }
        let queue = CleanupQueue()
        #expect(await queue.stage(URL(fileURLWithPath: f.dir + "/big"), size: 123, reason: "test"))
        let immediate = await queue.reclaimEstimate()
        let items = await queue.allItems()
        if items.first?.isMeasuring == true {
            #expect(immediate.isCalculating)
            #expect(immediate.bytes == 123, "provisional figure is the caller's size")
        }
        await queue.waitForMeasurements()
        let settled = await queue.reclaimEstimate()
        #expect(!settled.isCalculating)
        #expect(settled.bytes >= 400 * 4_096)
        #expect(await queue.allItems().allSatisfy { !$0.isMeasuring })
    }

    /// Unstaging the item being measured must not leave a waiter hanging.
    @Test func unstagingWhileMeasuringDoesNotHangWaiters() async throws {
        let f = try Fixture()
        for i in 0..<200 { f.file("gone/f\(i).bin", bytes: 4_096) }
        let queue = CleanupQueue()
        #expect(await queue.stage(URL(fileURLWithPath: f.dir + "/gone"), size: 1, reason: "test"))
        if let id = await queue.allItems().first?.id { await queue.unstage(id: id) }
        await queue.waitForMeasurements()      // must return
        #expect(await queue.allItems().isEmpty)
    }

    /// The commit computes its receipt from real measurements even when the
    /// caller confirms before they finish.
    @Test func commitWaitsForMeasurement() async throws {
        let f = try Fixture()
        let path = f.file("solo.bin", bytes: 300_000)
        let queue = CleanupQueue()
        #expect(await queue.stage(URL(fileURLWithPath: path), size: 1, reason: "test"))
        let report = await queue.commitReport { _ in }
        #expect(report.freedWhenTrashEmptied == f.allocated(path))
    }

    // MARK: - Commit (through the test seam: nothing reaches the real Trash)

    @Test func receiptEqualsThePreCommitEstimate() async throws {
        let f = try Fixture()
        let a = f.file("a.bin")
        let b = try f.clone(a, "b.bin")
        let plain = f.file("plain.bin", bytes: 200_000)
        let queue = CleanupQueue()
        for path in [a, b, plain] { #expect(await stage(queue, path)) }
        let before = await queue.reclaimEstimate()

        var moved: [String] = []
        let report = await queue.commitReport { moved.append($0.path) }
        #expect(report.freedWhenTrashEmptied == before.bytes)
        #expect(report.entries.map(\.freedBytes).reduce(0, +) == before.bytes)
        let receipt = CleanupPreflight.logEntries(from: report)
        #expect(receipt.map(\.bytes).reduce(0, +) == before.bytes)
        #expect(moved.count == 3)
        #expect(await queue.allItems().isEmpty)
    }

    @Test func folderMovesFirstAndItsContentsGoWithIt() async throws {
        let f = try Fixture()
        let inner = f.file("folder/inner.bin")
        let queue = CleanupQueue()
        #expect(await stage(queue, inner))
        #expect(await stage(queue, f.dir + "/folder"))

        var moved: [String] = []
        let report = await queue.commitReport { moved.append($0.path) }
        #expect(moved == [URL(fileURLWithPath: f.dir + "/folder").standardizedFileURL.path])
        let innerEntry = try #require(report.entries.first { $0.item.url.path.hasSuffix("inner.bin") })
        #expect(innerEntry.error == nil)
        #expect(innerEntry.movedWithFolder)
    }

    /// A partial failure must not report space from an item still on disk,
    /// and the failed item stays queued for a retry.
    @Test func failedItemIsNotCountedAndStaysQueued() async throws {
        let f = try Fixture()
        let keep = f.file("fails.bin")
        let goes = f.file("goes.bin", bytes: 300_000)
        let queue = CleanupQueue()
        #expect(await stage(queue, keep))
        #expect(await stage(queue, goes))

        struct Denied: Error {}
        let report = await queue.commitReport { url in
            if url.lastPathComponent == "fails.bin" { throw Denied() }
        }
        #expect(report.freedWhenTrashEmptied == f.allocated(goes))
        #expect(await queue.allItems().map(\.url.lastPathComponent) == ["fails.bin"])
    }

    // MARK: - Duplicates

    /// Two names of one inode are one file. They used to hash identically and
    /// be offered as duplicates whose deletion frees nothing.
    @Test func hardLinkedNamesAreNotOfferedAsDuplicates() async throws {
        let f = try Fixture()
        let first = f.file("dups/one.bin", bytes: 20_000)
        f.hardLink(first, "dups/two.bin")
        let result = await ScanEngine().scan(root: URL(fileURLWithPath: f.dir + "/dups"))
        let candidates = DuplicateFinder.candidates(in: result.tree, root: URL(fileURLWithPath: f.dir + "/dups"))
        #expect(candidates.count == 1)
    }

    @Test func duplicateReclaimUsesOnDiskSize() {
        let copies = DuplicateGroup(hash: "h", fileIDs: [1, 2, 3], sizeEach: 1_000, sharesStorage: false)
        let onDisk: (Int32) -> Int64 = { _ in 4_096 }
        #expect(copies.reclaimableBytes(deleting: [2, 3], onDisk: onDisk) == 8_192)
        let clones = DuplicateGroup(hash: "s", fileIDs: [1, 2], sizeEach: 1_000, sharesStorage: true)
        #expect(clones.reclaimableBytes(deleting: [2], onDisk: onDisk) == 0)
        #expect(clones.reclaimableBytes(deleting: [1, 2], onDisk: onDisk) == 4_096)
    }

    // MARK: - Non-APFS

    /// Opt-in, like the other ExFAT tests: runs only when a scratch ExFAT
    /// volume is mounted at /Volumes/DISKMAP (scripts/make-exfat-fixture.sh).
    /// FSKit ExFAT claims to return the extended attributes and fills them
    /// with zeros (measured: returned bits 0x1308, PRIVATESIZE 0). Trusting
    /// that would report "frees nothing" for every file on an external drive,
    /// so the queue must fall back to allocated size.
    @Test func nonAPFSVolumeFallsBackToAllocatedSize() async throws {
        let volume = "/Volumes/DISKMAP"
        var fs = statfs()
        guard statfs(volume, &fs) == 0 else { return }
        let type = withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard type.lowercased().contains("exfat") else { return }

        let dir = volume + "/reclaim-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/plain.bin"
        FileManager.default.createFile(atPath: path, contents: Data(repeating: 7, count: 500_000))

        let profile = try #require(StorageSharing.profile(atPath: path))
        #expect(!profile.usesFilesystemAccounting)

        let queue = CleanupQueue()
        #expect(await queue.stage(URL(fileURLWithPath: path), size: 1, reason: "test"))
        await queue.waitForMeasurements()
        var info = stat()
        lstat(path, &info)
        #expect(await queue.totalSize() == Int64(info.st_blocks) * 512)

        // macOS may add `._` AppleDouble sidecars on ExFAT, so ≥ 1 files.
        let folder = try #require(StorageSharing.profile(atPath: dir))
        #expect(folder.fileCount >= 1)
        #expect(folder.allocatedBytes >= Int64(info.st_blocks) * 512)
        #expect(!folder.usesFilesystemAccounting)
    }
}
