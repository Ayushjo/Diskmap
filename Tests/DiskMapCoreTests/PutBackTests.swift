import Foundation
import Testing
@testable import DiskMapCore

/// TASK-080 — the last cleanup can be put back. Everything goes through the
/// commit seam with a fake "Trash" folder; the real Trash is never touched.
@Suite("Put Back")
struct PutBackTests {

    final class Fixture {
        let base: URL
        let root: URL
        let trash: URL
        init() throws {
            base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("diskmap-putback-\(UUID().uuidString)")
            root = base.appendingPathComponent("home")
            trash = base.appendingPathComponent("FakeTrash")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: base) }

        func url(_ rel: String) -> URL { root.appendingPathComponent(rel) }

        func put(_ rel: String, _ bytes: Int) throws {
            try FileManager.default.createDirectory(at: url(rel).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 6, count: bytes).write(to: url(rel))
        }

        /// Like the Trash: moves the item in under a unique name, returns where.
        func fakeTrash(_ item: URL) throws -> URL? {
            let destination = trash.appendingPathComponent(UUID().uuidString + "-" + item.lastPathComponent)
            try FileManager.default.moveItem(at: item, to: destination)
            return destination
        }

        func commit(_ rels: [String]) async throws -> CleanupQueue.CommitReport {
            let queue = CleanupQueue()
            for rel in rels {
                #expect(await queue.stage(url(rel), size: 1, reason: "test"))
            }
            return await queue.commitReport(movingToTrash: fakeTrash)
        }
    }

    private func size(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    @Test func committedItemsComeBackWhereTheyWere() async throws {
        let f = try Fixture()
        try f.put("Downloads/a.dmg", 30_000)
        try f.put("Projects/old/b.zip", 20_000)
        let report = try await f.commit(["Downloads/a.dmg", "Projects/old/b.zip"])
        #expect(!FileManager.default.fileExists(atPath: f.url("Downloads/a.dmg").path))
        let record = CleanupRecord(report: report)
        #expect(record.items.count == 2)
        #expect(record.items.allSatisfy { $0.trashedPath.hasPrefix(f.trash.path) })

        let result = CleanupQueue.putBack(record)
        #expect(result.restored.count == 2)
        #expect(result.skipped.isEmpty)
        #expect(size(f.url("Downloads/a.dmg")) == 30_000)
        #expect(size(f.url("Projects/old/b.zip")) == 20_000)
    }

    @Test func somethingNewAtTheOldPathIsNeverReplaced() async throws {
        let f = try Fixture()
        try f.put("Downloads/a.dmg", 30_000)
        let record = CleanupRecord(report: try await f.commit(["Downloads/a.dmg"]))
        try f.put("Downloads/a.dmg", 7)   // a new file with the same name
        let result = CleanupQueue.putBack(record)
        #expect(result.restored.isEmpty)
        #expect(result.skipped.first?.reason.hasPrefix("Something new is at") == true)
        #expect(size(f.url("Downloads/a.dmg")) == 7, "the new file is untouched")
        #expect(FileManager.default.fileExists(atPath: record.items[0].trashedPath), "the old one stays in the Trash")
    }

    @Test func goneFromTheTrashIsReported() async throws {
        let f = try Fixture()
        try f.put("Downloads/a.dmg", 30_000)
        let record = CleanupRecord(report: try await f.commit(["Downloads/a.dmg"]))
        // Emptying the Trash, simulated by moving it out of the fake Trash.
        try FileManager.default.moveItem(atPath: record.items[0].trashedPath, toPath: f.base.appendingPathComponent("elsewhere").path)
        let result = CleanupQueue.putBack(record)
        #expect(result.skipped.first?.reason == "Already removed from the Trash")
        #expect(!FileManager.default.fileExists(atPath: f.url("Downloads/a.dmg").path))
    }

    @Test func aFolderBringsItsQueuedChildBack() async throws {
        let f = try Fixture()
        try f.put("Old/inner/x.bin", 4_000)
        try f.put("Old/y.bin", 5_000)
        let report = try await f.commit(["Old", "Old/inner/x.bin"])
        #expect(report.entries.contains { $0.movedWithFolder })
        let record = CleanupRecord(report: report)
        #expect(record.items.map(\.originalPath) == [f.url("Old").path], "the child went with its folder")
        let result = CleanupQueue.putBack(record)
        #expect(result.restored.count == 1)
        #expect(size(f.url("Old/inner/x.bin")) == 4_000)
        #expect(size(f.url("Old/y.bin")) == 5_000)
    }

    @Test func aMissingParentIsRecreated() async throws {
        let f = try Fixture()
        try f.put("Gone/parent/file.bin", 2_000)
        let record = CleanupRecord(report: try await f.commit(["Gone/parent/file.bin"]))
        try FileManager.default.moveItem(at: f.url("Gone"), to: f.base.appendingPathComponent("moved-away"))
        let result = CleanupQueue.putBack(record)
        #expect(result.restored.count == 1)
        #expect(size(f.url("Gone/parent/file.bin")) == 2_000)
    }

    @Test func failedItemsAreNotInTheRecord() async throws {
        let f = try Fixture()
        try f.put("a.bin", 10)
        let queue = CleanupQueue()
        #expect(await queue.stage(f.url("a.bin"), size: 1, reason: "test"))
        struct Refused: Error {}
        let report = await queue.commitReport(movingToTrash: { _ in throw Refused() })
        #expect(CleanupRecord(report: report).items.isEmpty)
    }

    /// The Trash refusing an item never deletes it another way: it stays
    /// staged with a reason a person can act on, and the next commit retries.
    @Test func refusedItemsStayStagedWithAPlainReason() async throws {
        let f = try Fixture()
        try f.put("a.bin", 10)
        let queue = CleanupQueue()
        #expect(await queue.stage(f.url("a.bin"), size: 1, reason: "test"))
        let unsupported = NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
        _ = await queue.commitReport(movingToTrash: { _ in throw unsupported })
        let left = await queue.allItems()
        #expect(left.count == 1)
        #expect(left.first?.lastFailure?.contains("no Trash") == true)
        #expect(FileManager.default.fileExists(atPath: f.url("a.bin").path))
        // A retry that succeeds clears it.
        var tried: [URL] = []
        _ = await queue.commitReport(movingToTrash: { tried.append($0); return nil })
        #expect(tried.count == 1)
        #expect(await queue.allItems().isEmpty)
        // Errors read as sentences.
        #expect(CleanupQueue.plainReason(NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))).contains("in use"))
        #expect(CleanupQueue.plainReason(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)).contains("no longer there"))
    }

    /// Progress only moves forward and ends with every item moved; sizes are
    /// measured at most eight at a time (MAC-FIXES-FROM-WINDOWS §2.3).
    @Test func commitReportsProgressAndMeasuringIsBounded() async throws {
        let f = try Fixture()
        let queue = CleanupQueue()
        for k in 0..<20 {
            try f.put("d\(k)/x.bin", 1_000)
            #expect(await queue.stage(f.url("d\(k)"), size: 1_000, reason: "test"))
        }
        final class Log: @unchecked Sendable {
            var steps: [CleanupQueue.CommitProgress] = []
            let lock = NSLock()
            func add(_ step: CleanupQueue.CommitProgress) { lock.lock(); steps.append(step); lock.unlock() }
        }
        let log = Log()
        _ = await queue.commitReport(movingToTrash: { _ in nil }, progress: { log.add($0) })
        let moving = log.steps.compactMap { step -> Int? in
            if case let .moving(done, total) = step { #expect(total == 20); return done } else { return nil }
        }
        #expect(moving == Array(1...20))
        #expect(log.steps.contains(.verifying(done: 20, total: 20)) || log.steps.first.map { if case .moving = $0 { return true } else { return false } } == true)
        #expect(await queue.peakActiveMeasurements <= CleanupQueue.measurementLimit)
    }

    @Test func theRecordSurvivesARelaunch() throws {
        let f = try Fixture()
        let file = f.base.appendingPathComponent("support/last-cleanup.json")
        let record = CleanupRecord(date: Date(timeIntervalSince1970: 1_790_000_000),
                                   items: [.init(originalPath: "/Users/x/a", trashedPath: "/Users/x/.Trash/a", bytes: 42)])
        try record.save(to: file)
        #expect(CleanupRecord.load(from: file) == record)
        try CleanupRecord(date: Date(timeIntervalSince1970: 1_790_000_100), items: []).save(to: file)
        #expect(CleanupRecord.load(from: file)?.items.isEmpty == true)
    }
}
