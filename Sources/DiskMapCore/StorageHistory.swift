import Foundation

/// A small record of every scan of a folder, so DiskMap can say what grew
/// since last week (TASK-079). Foundation only; no tree is kept — one entry
/// is a few hundred folder sizes.
///
/// One file per scanned root:
/// `~/Library/Application Support/DiskMap/History/<fnv-1a of the path>.json`.
/// Written whole and atomically after each scan; never deleted. A file that
/// no longer decodes is left alone and a `.v2.json` beside it takes over.
public struct StorageHistory: Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public var date: Date
        public var freeBytes: Int64
        public var totalBytes: Int64
        public var scannedBytes: Int64
        public var deniedCount: Int
        /// The clone accounting the sizes were counted with (TASK-077):
        /// entries counted differently are not compared.
        public var sharingMode: String
        /// Root-relative folder path → allocated bytes. Root children of
        /// 50 MB or more; for big top-level folders, their 20 largest
        /// children too ("Library/Caches").
        public var folders: [String: Int64]

        public init(date: Date, freeBytes: Int64, totalBytes: Int64, scannedBytes: Int64, deniedCount: Int,
                    sharingMode: String = SharingMode.off.rawValue, folders: [String: Int64]) {
            self.date = date
            self.freeBytes = freeBytes
            self.totalBytes = totalBytes
            self.scannedBytes = scannedBytes
            self.deniedCount = deniedCount
            self.sharingMode = sharingMode
            self.folders = folders
        }
    }

    struct File: Codable, Equatable {
        var version = 1
        var rootPath: String
        var entries: [Entry]
    }

    public let directory: URL

    public init(directory: URL = StorageHistory.defaultDirectory()) {
        self.directory = directory
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DiskMap/History", isDirectory: true)
    }

    // MARK: - Building an entry

    public static let rootChildThreshold: Int64 = 50_000_000
    public static let bigFolderBytes: Int64 = 5_000_000_000
    public static let bigFolderShare = 0.05
    public static let childrenPerBigFolder = 20
    public static let maxFolders = 300

    /// The folder sizes worth remembering from one scan. `totals` must be
    /// the allocated rollup of `tree`.
    public static func folders(tree: FileTree, totals: [Int64]) -> [String: Int64] {
        guard tree.count > 0, totals.count == tree.count else { return [:] }
        let rootTotal = totals[0]
        var result: [String: Int64] = [:]
        let children = tree.children(of: 0, totals: totals)
            .filter { tree.isDirectory[Int($0.id)] && $0.size >= rootChildThreshold }
            .sorted { $0.size != $1.size ? $0.size > $1.size : tree.name(of: $0.id) < tree.name(of: $1.id) }
        for child in children where result.count < maxFolders {
            result[tree.name(of: child.id)] = child.size
        }
        for child in children {
            let big = child.size >= bigFolderBytes || (rootTotal > 0 && Double(child.size) / Double(rootTotal) >= bigFolderShare)
            guard big else { continue }
            let parentName = tree.name(of: child.id)
            let grandchildren = tree.children(of: child.id, totals: totals)
                .filter { tree.isDirectory[Int($0.id)] && $0.size > 0 }
                .sorted { $0.size != $1.size ? $0.size > $1.size : tree.name(of: $0.id) < tree.name(of: $1.id) }
                .prefix(childrenPerBigFolder)
            for grandchild in grandchildren where result.count < maxFolders {
                result[parentName + "/" + tree.name(of: grandchild.id)] = grandchild.size
            }
        }
        return result
    }

    // MARK: - Reading and writing

    static func hash(_ path: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", value)
    }

    func primaryURL(for rootPath: String) -> URL { directory.appendingPathComponent(Self.hash(rootPath) + ".json") }
    func fallbackURL(for rootPath: String) -> URL { directory.appendingPathComponent(Self.hash(rootPath) + ".v2.json") }

    /// The file in use for `rootPath`: the primary one, unless it exists and
    /// cannot be read — then the fallback, leaving the damaged one in place.
    func activeURL(for rootPath: String) -> URL {
        let primary = primaryURL(for: rootPath)
        guard FileManager.default.fileExists(atPath: primary.path) else { return primary }
        return decode(primary, rootPath: rootPath) != nil ? primary : fallbackURL(for: rootPath)
    }

    private func decode(_ url: URL, rootPath: String) -> File? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(File.self, from: data), file.rootPath == rootPath else { return nil }
        return file
    }

    public func entries(for rootPath: String) -> [Entry] {
        decode(activeURL(for: rootPath), rootPath: rootPath)?.entries ?? []
    }

    /// Adds `entry`, applies retention, and rewrites the file atomically.
    @discardableResult
    public func record(_ entry: Entry, rootPath: String, calendar: Calendar = .current) throws -> [Entry] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = activeURL(for: rootPath)
        let existing = decode(url, rootPath: rootPath)?.entries ?? []
        let kept = Self.retained(existing + [entry], now: entry.date, calendar: calendar)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(File(rootPath: rootPath, entries: kept)).write(to: url, options: .atomic)
        return kept
    }

    // MARK: - Retention

    /// One entry per calendar day (the day's last); every day of the last
    /// 30; the last entry of each ISO week for the rest of the year; nothing
    /// older. About 80 entries at most.
    public static func retained(_ entries: [Entry], now: Date, calendar: Calendar = .current) -> [Entry] {
        let sorted = entries.sorted { $0.date < $1.date }
        var perDay: [Date: Entry] = [:]
        for entry in sorted { perDay[calendar.startOfDay(for: entry.date)] = entry }
        let recentCutoff = calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: now)) ?? now
        let yearCutoff = calendar.date(byAdding: .day, value: -365, to: calendar.startOfDay(for: now)) ?? now
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        var perWeek: [String: Entry] = [:]
        var recent: [Entry] = []
        for (day, entry) in perDay {
            if day >= recentCutoff {
                recent.append(entry)
            } else if day >= yearCutoff {
                let parts = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: day)
                let key = "\(parts.yearForWeekOfYear ?? 0)-\(parts.weekOfYear ?? 0)"
                if let current = perWeek[key], current.date > entry.date { continue }
                perWeek[key] = entry
            }
        }
        return (recent + perWeek.values).sorted { $0.date < $1.date }
    }

    // MARK: - Comparing

    public struct Growth: Sendable, Equatable {
        public var path: String
        public var before: Int64
        public var after: Int64
        public var delta: Int64 { after - before }
    }

    public struct Comparison: Sendable, Equatable {
        public var since: Date
        /// True when the comparison point is the "about a week ago" one; false
        /// when it is simply the oldest entry old enough to compare with.
        public var isWeek: Bool
        public var freeDelta: Int64
        public var scannedDelta: Int64
        /// Largest growers first, each at least `minGrowth`.
        public var growers: [Growth]
        /// Set when the two scans could not read the same folders, so small
        /// deltas may be the reading, not the disk.
        public var deniedChanged: Bool
    }

    public static let minGrowth: Int64 = 100_000_000

    /// What changed between the entry about a week before `latest` and
    /// `latest`. The comparison point is the entry closest to 7 days back
    /// among those at least 5 days old; failing that, the oldest at least 2
    /// days old ("since <date>"); failing that, none.
    public static func compare(_ entries: [Entry], latest: Entry, limit: Int = 5) -> Comparison? {
        let sameCounting = entries.filter { $0.sharingMode == latest.sharingMode && $0.date < latest.date }
        let day: TimeInterval = 86_400
        let target = latest.date.addingTimeInterval(-7 * day)
        let weekCandidates = sameCounting.filter { latest.date.timeIntervalSince($0.date) >= 5 * day }
        let base: Entry
        let isWeek: Bool
        if let closest = weekCandidates.min(by: { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) }) {
            base = closest
            isWeek = true
        } else if let oldest = sameCounting.filter({ latest.date.timeIntervalSince($0.date) >= 2 * day }).min(by: { $0.date < $1.date }) {
            base = oldest
            isWeek = false
        } else {
            return nil
        }
        var growers: [Growth] = []
        for path in Set(latest.folders.keys).union(base.folders.keys) {
            // A second-level folder is compared only when both scans looked
            // inside its parent; otherwise "new" would just mean "newly big".
            if let slash = path.firstIndex(of: "/") {
                let parent = String(path[..<slash])
                let bothDeep = base.folders.keys.contains { $0.hasPrefix(parent + "/") }
                    && latest.folders.keys.contains { $0.hasPrefix(parent + "/") }
                guard bothDeep else { continue }
            }
            let growth = Growth(path: path, before: base.folders[path] ?? 0, after: latest.folders[path] ?? 0)
            if growth.delta >= minGrowth { growers.append(growth) }
        }
        growers.sort { $0.delta != $1.delta ? $0.delta > $1.delta : $0.path < $1.path }
        // Prefer the deepest explanation: drop a parent whose growth a
        // listed child already accounts for most of.
        growers = growers.filter { grower in
            !growers.contains { $0.path.hasPrefix(grower.path + "/") && Double($0.delta) >= 0.8 * Double(grower.delta) }
        }
        return Comparison(
            since: base.date, isWeek: isWeek, freeDelta: latest.freeBytes - base.freeBytes,
            scannedDelta: latest.scannedBytes - base.scannedBytes, growers: Array(growers.prefix(limit)),
            deniedChanged: latest.deniedCount != base.deniedCount
        )
    }
}
