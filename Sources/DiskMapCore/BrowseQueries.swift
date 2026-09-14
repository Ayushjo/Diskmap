import Foundation

/// Ranked node ids for the Top Sizes list. Index 0 (the scan root) is
/// omitted. Directories already carry subtree totals; files carry their
/// own size. Paths are not built here — a 1.6M-node scan can sort ids
/// and only resolve the capped list.
public enum TopSizes {
    public static func ranked(totals: [Int64], limit: Int = 500) -> [Int32] {
        guard totals.count > 1, limit > 0 else { return [] }
        var ids = Array(1..<Int32(totals.count))
        ids.sort { totals[Int($0)] > totals[Int($1)] }
        var result: [Int32] = []
        result.reserveCapacity(min(limit, ids.count))
        for id in ids {
            guard totals[Int(id)] > 0 else { break }
            result.append(id)
            if result.count == limit { break }
        }
        return result
    }
}

public enum AgeBucket: String, Sendable, CaseIterable, Equatable {
    case under30
    case days30to90
    case days90to365
    case oneToTwoYears
    case overTwoYears
    case unknown

    public var title: String {
        switch self {
        case .under30: return "Under 30 days"
        case .days30to90: return "30–90 days"
        case .days90to365: return "90 days–1 year"
        case .oneToTwoYears: return "1–2 years"
        case .overTwoYears: return "Over 2 years"
        case .unknown: return "No date"
        }
    }

    /// Compact labels for heatmaps and chips (e.g. Find → Forgotten).
    public var shortTitle: String {
        switch self {
        case .under30: return "<30d"
        case .days30to90: return "30–90d"
        case .days90to365: return "90d–1y"
        case .oneToTwoYears: return "1–2y"
        case .overTwoYears: return "2y+"
        case .unknown: return "No date"
        }
    }
}

public enum AgeMap {
    public static func today(from date: Date = Date()) -> Int32 {
        Int32(date.timeIntervalSince1970 / 86400)
    }

    /// `modifiedDay` is days since epoch. 0 means the scan had no date.
    public static func bucket(modifiedDay: Int32, today: Int32) -> AgeBucket {
        guard modifiedDay > 0 else { return .unknown }
        let age = today - modifiedDay
        if age < 30 { return .under30 }
        if age < 90 { return .days30to90 }
        if age < 365 { return .days90to365 }
        if age < 730 { return .oneToTwoYears }
        return .overTwoYears
    }

    /// File ids older than a year, largest first, capped. Directories
    /// and unknown dates are excluded.
    public static func untouched(
        in tree: FileTree,
        totals: [Int64],
        today: Int32,
        limit: Int = 100
    ) -> [Int32] {
        guard tree.count == totals.count, limit > 0 else { return [] }
        var files: [Int32] = []
        for id in 1..<Int32(tree.count) {
            let index = Int(id)
            guard !tree.isDirectory[index] else { continue }
            let day = tree.modifiedDay[index]
            guard day > 0, today - day > 365, totals[index] > 0 else { continue }
            files.append(id)
        }
        files.sort { totals[Int($0)] > totals[Int($1)] }
        if files.count > limit { files.removeLast(files.count - limit) }
        return files
    }

    public static func bucketSizes(
        in tree: FileTree,
        totals: [Int64],
        today: Int32
    ) -> [AgeBucket: Int64] {
        var sizes: [AgeBucket: Int64] = [:]
        guard tree.count == totals.count else { return sizes }
        for id in 1..<tree.count {
            guard !tree.isDirectory[id] else { continue }
            let bucket = bucket(modifiedDay: tree.modifiedDay[id], today: today)
            sizes[bucket, default: 0] += totals[id]
        }
        return sizes
    }
}
