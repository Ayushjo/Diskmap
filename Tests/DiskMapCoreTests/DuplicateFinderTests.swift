import Foundation
import Testing
@testable import DiskMapCore

struct DuplicateFinderTests {
    @Test func freshCloneSkipsFullHashAndIndependentCopyDoesNot() async throws {
        let fixture = try DuplicateFixture()
        defer { fixture.tearDown() }

        let clones = await DuplicateFinder.scan([
            (0, URL(fileURLWithPath: fixture.original), fixture.byteCount),
            (1, URL(fileURLWithPath: fixture.clone), fixture.byteCount),
        ])
        #expect(clones.fullContentHashCalls == 0)
        #expect(clones.groups.count == 1)
        #expect(clones.groups[0].sharesStorage == true)
        #expect(clones.groups[0].fileIDs == [0, 1])
        #expect(clones.groups[0].reclaimableBytes(deleting: [0]) == 0)
        #expect(clones.groups[0].reclaimableBytes(deleting: [0, 1]) == fixture.byteCount)

        let copies = await DuplicateFinder.scan([
            (2, URL(fileURLWithPath: fixture.original), fixture.byteCount),
            (3, URL(fileURLWithPath: fixture.unrelated), fixture.byteCount),
        ])
        #expect(copies.fullContentHashCalls == 2)
        #expect(copies.groups.count == 1)
        #expect(copies.groups[0].sharesStorage == false)
        #expect(copies.groups[0].fileIDs == [2, 3])
        #expect(copies.groups[0].reclaimableBytes(deleting: [3]) == fixture.byteCount)
    }

    @Test func cowDivergedCloneIsHashedAndNotGrouped() async throws {
        let fixture = try DuplicateFixture()
        defer { fixture.tearDown() }

        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: fixture.clone))
        try handle.seek(toOffset: 1_048_576)
        try handle.write(contentsOf: Data(repeating: 0x22, count: 4096))
        try handle.close()

        let result = await DuplicateFinder.scan([
            (0, URL(fileURLWithPath: fixture.original), fixture.byteCount),
            (1, URL(fileURLWithPath: fixture.clone), fixture.byteCount),
        ])
        #expect(result.fullContentHashCalls == 2)
        #expect(result.groups.isEmpty)
    }

    @Test func keeperIsTheOldestFile() {
        let group = DuplicateGroup(hash: "h", fileIDs: [3, 1, 2], sizeEach: 10, sharesStorage: false)
        let days: [Int32: Int32] = [3: 100, 1: 40, 2: 40]
        #expect(group.defaultKeeperID { days[$0] ?? 0 } == 1)
    }

    @Test func candidatesSkipDirectoriesAndNotDownloaded() {
        var tree = FileTree()
        let root = tree.addNode(name: "root", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "keep.txt", parent: root, isDirectory: false, logicalSize: 8, allocatedSize: 8, modifiedDaysSinceEpoch: 1)
        _ = tree.addNode(name: "cloud.txt", parent: root, isDirectory: false, logicalSize: 8, allocatedSize: 0, modifiedDaysSinceEpoch: 1, flags: NodeFlags.notDownloaded)
        _ = tree.addNode(name: "empty.txt", parent: root, isDirectory: false, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        let folder = tree.addNode(name: "dir", parent: root, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)

        let found = DuplicateFinder.candidates(in: tree, root: URL(fileURLWithPath: "/tmp/diskmap-candidates", isDirectory: true))
        #expect(found.map(\.id) == [tree.node(named: "keep.txt", parentNamed: "root")].compactMap { $0 })
        #expect(found.count == 1)
        #expect(folder > 0)
    }
}

struct CleanupQueueReclaimTests {
    @Test func oneCloneFreesNothingUntilTheLastCopyIsStaged() async {
        let queue = CleanupQueue()
        let a = URL(fileURLWithPath: "/tmp/diskmap-clone-a")
        let b = URL(fileURLWithPath: "/tmp/diskmap-clone-b")
        #expect(await queue.stage(a, size: 800, reason: "shared clone", sharesStorageGroup: "g", groupCopyCount: 2) == true)
        #expect(await queue.totalSize() == 0)

        #expect(await queue.stage(b, size: 800, reason: "shared clone", sharesStorageGroup: "g", groupCopyCount: 2) == true)
        #expect(await queue.totalSize() == 800)

        #expect(await queue.stage(URL(fileURLWithPath: "/tmp/diskmap-real-copy"), size: 100, reason: "duplicate") == true)
        #expect(await queue.totalSize() == 900)
    }

    @Test func excludedPrefixStillCannotBeStaged() async {
        let queue = CleanupQueue()
        #expect(await queue.stage(URL(fileURLWithPath: "/System/Library/Kernels/kernel"), size: 1, reason: "duplicate") == false)
        #expect(await queue.allItems().isEmpty)
    }
}

private struct DuplicateFixture {
    let directory: String
    let original: String
    let clone: String
    let unrelated: String
    let byteCount: Int64 = 8_388_608

    init() throws {
        directory = NSTemporaryDirectory() + "DiskMap-dup-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        original = directory + "/original.bin"
        clone = directory + "/clone.bin"
        unrelated = directory + "/unrelated.bin"
        let bytes = Data(repeating: 0xAB, count: Int(byteCount))
        FileManager.default.createFile(atPath: original, contents: bytes)
        FileManager.default.createFile(atPath: unrelated, contents: bytes)
        let cp = Process()
        cp.executableURL = URL(fileURLWithPath: "/bin/cp")
        cp.arguments = ["-c", original, clone]
        try cp.run()
        cp.waitUntilExit()
        if cp.terminationStatus != 0 {
            throw DuplicateCopyFailed(status: cp.terminationStatus)
        }
    }

    func tearDown() {
        try? FileManager.default.removeItem(atPath: directory)
    }
}

private struct DuplicateCopyFailed: Error {
    var status: Int32
}
