import Foundation
import Testing
@testable import DiskMapCore

/// TASK-079 — a small per-folder history of scans, and "what grew this week".
@Suite("Storage history")
struct StorageHistoryTests {
    private static let day: TimeInterval = 86_400
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)   // a fixed "now"

    private func temporaryHistory() -> StorageHistory {
        StorageHistory(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskmap-history-\(UUID().uuidString)", isDirectory: true))
    }

    private func entry(daysAgo: Double, free: Int64 = 100_000_000_000, folders: [String: Int64] = [:],
                       denied: Int = 0, mode: SharingMode = .off) -> StorageHistory.Entry {
        StorageHistory.Entry(date: Self.now.addingTimeInterval(-daysAgo * Self.day), freeBytes: free, totalBytes: 500_000_000_000,
                             scannedBytes: folders.values.reduce(0, +), deniedCount: denied, sharingMode: mode.rawValue, folders: folders)
    }

    // MARK: building

    @Test func foldersKeepBigChildrenAndLookInsideBigFolders() {
        var tree = FileTree()
        _ = tree.addNode(name: "home", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let library = tree.addNode(name: "Library", parent: 0, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        for index in 0..<25 {
            let child = tree.addNode(name: "c\(index)", parent: library, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
            _ = tree.addNode(name: "f", parent: child, isDirectory: false, logicalSize: 0,
                             allocatedSize: Int64(index + 1) * 300_000_000, modifiedDaysSinceEpoch: 0)
        }
        let small = tree.addNode(name: "Small", parent: 0, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "s", parent: small, isDirectory: false, logicalSize: 0, allocatedSize: 49_000_000, modifiedDaysSinceEpoch: 0)
        let mid = tree.addNode(name: "Mid", parent: 0, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "m", parent: mid, isDirectory: false, logicalSize: 0, allocatedSize: 60_000_000, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "loose.bin", parent: 0, isDirectory: false, logicalSize: 0, allocatedSize: 9_000_000_000, modifiedDaysSinceEpoch: 0)

        let folders = StorageHistory.folders(tree: tree, totals: tree.rollUpBoth().allocated)
        #expect(folders["Library"] == (1...25).reduce(0) { $0 + Int64($1) * 300_000_000 })
        #expect(folders["Mid"] == 60_000_000)
        #expect(folders["Small"] == nil, "under 50 MB")
        #expect(folders["loose.bin"] == nil, "files are not folders")
        let inside = folders.keys.filter { $0.hasPrefix("Library/") }
        #expect(inside.count == 20, "the 20 largest children of a big folder")
        #expect(folders["Library/c24"] == 7_500_000_000)
        #expect(folders["Library/c0"] == nil)
    }

    // MARK: retention

    @Test func retentionKeepsDaysThenWeeksThenNothing() {
        var entries: [StorageHistory.Entry] = []
        for daysAgo in 0..<400 {
            entries.append(entry(daysAgo: Double(daysAgo) + 0.5))   // morning
            entries.append(entry(daysAgo: Double(daysAgo) + 0.1))   // evening, same day
        }
        let kept = StorageHistory.retained(entries, now: Self.now, calendar: Self.utc)
        let recent = kept.filter { Self.now.timeIntervalSince($0.date) <= 31 * Self.day }
        #expect(recent.count >= 30 && recent.count <= 32, "one per day for the last month")
        let days = Set(kept.map { Self.utc.startOfDay(for: $0.date) })
        #expect(days.count == kept.count, "never two entries on one day")
        #expect(kept.allSatisfy { Self.now.timeIntervalSince($0.date) <= 366 * Self.day }, "nothing older than a year")
        #expect(kept.count <= 85)
        // Each kept day keeps its LAST scan.
        let latestToday = entries.filter { Self.utc.isDate($0.date, inSameDayAs: Self.now.addingTimeInterval(-0.1 * Self.day)) }
            .max { $0.date < $1.date }
        #expect(kept.contains { $0.date == latestToday?.date })
    }

    // MARK: comparing

    @Test func comparesWithAboutAWeekAgo() throws {
        let entries = [
            entry(daysAgo: 20, folders: ["Library": 10_000_000_000]),
            entry(daysAgo: 8, free: 120_000_000_000, folders: ["Library": 20_000_000_000, "Movies": 1_000_000_000]),
            entry(daysAgo: 6, free: 118_000_000_000, folders: ["Library": 21_000_000_000]),
            entry(daysAgo: 1, folders: ["Library": 29_000_000_000]),
        ]
        let latest = entry(daysAgo: 0, free: 108_000_000_000,
                           folders: ["Library": 30_000_000_000, "Downloads": 3_000_000_000, "Movies": 1_050_000_000])
        let comparison = try #require(StorageHistory.compare(entries, latest: latest))
        // 8 and 6 days are both 1 day off 7; ties go to the first found — either is a week ago.
        #expect(comparison.isWeek)
        #expect([entries[1].date, entries[2].date].contains(comparison.since))
        #expect(comparison.growers.first?.path == "Library")
        #expect(comparison.growers.contains { $0.path == "Downloads" && $0.before == 0 }, "a new folder grew from nothing")
        #expect(!comparison.growers.contains { $0.path == "Movies" }, "under 100 MB of growth is noise")
        #expect(comparison.deniedChanged == false)
    }

    @Test func fallsBackToTheOldestEntryOldEnough() throws {
        let entries = [entry(daysAgo: 3, folders: ["A": 1_000_000_000]), entry(daysAgo: 2.5, folders: ["A": 1_500_000_000])]
        let comparison = try #require(StorageHistory.compare(entries, latest: entry(daysAgo: 0, folders: ["A": 2_000_000_000])))
        #expect(comparison.isWeek == false)
        #expect(comparison.since == entries[0].date)
        #expect(comparison.growers.first?.delta == 1_000_000_000)
        #expect(StorageHistory.compare([entry(daysAgo: 1)], latest: entry(daysAgo: 0)) == nil, "nothing old enough yet")
    }

    @Test func secondLevelFoldersNeedBothSides() throws {
        let base = entry(daysAgo: 7, folders: ["Library": 10_000_000_000])
        let latest = entry(daysAgo: 0, folders: ["Library": 16_000_000_000, "Library/Caches": 6_000_000_000])
        let comparison = try #require(StorageHistory.compare([base], latest: latest))
        #expect(comparison.growers.map(\.path) == ["Library"], "Library/Caches was not looked into a week ago")

        let deeperBase = entry(daysAgo: 7, folders: ["Library": 10_000_000_000, "Library/Caches": 1_000_000_000])
        let deeper = try #require(StorageHistory.compare([deeperBase], latest: latest))
        #expect(deeper.growers.map(\.path) == ["Library/Caches"], "the child explains its parent's growth")
    }

    @Test func differentReadingOrCountingIsFlaggedOrSkipped() throws {
        let base = entry(daysAgo: 7, folders: ["A": 1_000_000_000], denied: 3)
        let comparison = try #require(StorageHistory.compare([base], latest: entry(daysAgo: 0, folders: ["A": 2_000_000_000], denied: 0)))
        #expect(comparison.deniedChanged)
        let otherCounting = entry(daysAgo: 7, folders: ["A": 9_000_000_000], mode: .off)
        #expect(StorageHistory.compare([otherCounting], latest: entry(daysAgo: 0, folders: ["A": 1_000_000_000], mode: .refcount)) == nil,
                "clones counted once vs per copy would read as a fake shrink")
    }

    // MARK: files

    @Test func oneFilePerRootRoundTrips() throws {
        let history = temporaryHistory()
        defer { try? FileManager.default.removeItem(at: history.directory) }
        try history.record(entry(daysAgo: 2, folders: ["A": 1]), rootPath: "/Users/x", calendar: Self.utc)
        try history.record(entry(daysAgo: 1, folders: ["A": 2]), rootPath: "/Users/x", calendar: Self.utc)
        try history.record(entry(daysAgo: 1, folders: ["B": 3]), rootPath: "/Volumes/Other", calendar: Self.utc)
        #expect(history.entries(for: "/Users/x").map { $0.folders["A"] } == [1, 2])
        #expect(history.entries(for: "/Volumes/Other").count == 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: history.directory.path).filter { $0.hasSuffix(".json") }
        #expect(files.count == 2)
    }

    @Test func aDamagedFileIsLeftAndAFallbackTakesOver() throws {
        let history = temporaryHistory()
        defer { try? FileManager.default.removeItem(at: history.directory) }
        try FileManager.default.createDirectory(at: history.directory, withIntermediateDirectories: true)
        let primary = history.primaryURL(for: "/Users/x")
        try Data("not json".utf8).write(to: primary)
        try history.record(entry(daysAgo: 0, folders: ["A": 1]), rootPath: "/Users/x", calendar: Self.utc)
        #expect(try String(contentsOf: primary, encoding: .utf8) == "not json", "the damaged file is not touched")
        #expect(FileManager.default.fileExists(atPath: history.fallbackURL(for: "/Users/x").path))
        #expect(history.entries(for: "/Users/x").count == 1)
    }
}
