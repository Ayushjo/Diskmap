import Foundation

/// Sidecar metadata for a saved DiskMap analytical snapshot (not APFS).
public struct SnapshotMeta: Codable, Sendable, Equatable {
    public var name: String
    public var note: String
    public var favorite: Bool
    public var volumeName: String?
    public var totalBytes: UInt64?
    public var freeBytes: UInt64?
    public var usedBytes: UInt64?
    public var scannedBytes: Int64?
    public var fileCount: Int?
    public var folderCount: Int?
    public var scanSeconds: Double?
    public var diskMapVersion: String?

    public init(
        name: String,
        note: String = "",
        favorite: Bool = false,
        volumeName: String? = nil,
        totalBytes: UInt64? = nil,
        freeBytes: UInt64? = nil,
        usedBytes: UInt64? = nil,
        scannedBytes: Int64? = nil,
        fileCount: Int? = nil,
        folderCount: Int? = nil,
        scanSeconds: Double? = nil,
        diskMapVersion: String? = nil
    ) {
        self.name = name
        self.note = note
        self.favorite = favorite
        self.volumeName = volumeName
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.usedBytes = usedBytes
        self.scannedBytes = scannedBytes
        self.fileCount = fileCount
        self.folderCount = folderCount
        self.scanSeconds = scanSeconds
        self.diskMapVersion = diskMapVersion
    }

    public static func defaultName(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return "Today — \(date.formatted(date: .omitted, time: .shortened))"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

public struct SnapshotRecord: Sendable, Equatable, Identifiable {
    public var id: String { url.path }
    public var url: URL
    public var header: SnapshotHeader
    public var meta: SnapshotMeta
    /// Live current scan (not persisted).
    public var isCurrent: Bool

    public init(url: URL, header: SnapshotHeader, meta: SnapshotMeta, isCurrent: Bool) {
        self.url = url
        self.header = header
        self.meta = meta
        self.isCurrent = isCurrent
    }

    public var displayName: String { meta.name.isEmpty ? SnapshotMeta.defaultName(for: header.capturedAt) : meta.name }

    /// Short label for compare pickers (avoids truncating to "Curre…").
    public var pickerLabel: String {
        let size = ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)
        let name = isCurrent ? "Current" : displayName
        let clipped = name.count > 22 ? String(name.prefix(20)) + "…" : name
        return "\(clipped) · \(size)"
    }

    public var usedBytes: Int64 {
        if let u = meta.usedBytes { return Int64(u) }
        return meta.scannedBytes ?? 0
    }

    public var freeBytes: Int64 {
        if let f = meta.freeBytes { return Int64(f) }
        return 0
    }

    public var totalBytes: Int64 {
        if let t = meta.totalBytes { return Int64(t) }
        return usedBytes + freeBytes
    }
}

public enum SnapshotChangeKind: String, Sendable, Equatable, CaseIterable, Identifiable {
    case added, removed, grew, shrunk

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .added: return "Added"
        case .removed: return "Removed"
        case .grew: return "Grew"
        case .shrunk: return "Shrank"
        }
    }
}

extension SnapshotChange {
    public var kind: SnapshotChangeKind {
        if before == 0 && after > 0 { return .added }
        if after == 0 && before > 0 { return .removed }
        if delta > 0 { return .grew }
        return .shrunk
    }

    public var displayPath: String {
        CanonicalPath.displayPath(absolutePath: path)
    }
}

public struct SnapshotCategoryDelta: Sendable, Equatable, Identifiable {
    public var id: String { key }
    public var key: String
    public var title: String
    public var colorHint: String
    public var before: Int64
    public var after: Int64
    public var delta: Int64 { after - before }

    public init(key: String, title: String, colorHint: String, before: Int64, after: Int64) {
        self.key = key
        self.title = title
        self.colorHint = colorHint
        self.before = before
        self.after = after
    }
}

public struct SnapshotCompareReport: Sendable, Equatable {
    public var beforeUsed: Int64
    public var afterUsed: Int64
    public var beforeFree: Int64
    public var afterFree: Int64
    public var beforeTotal: Int64
    public var afterTotal: Int64
    public var categoryDeltas: [SnapshotCategoryDelta]
    public var folderChanges: [SnapshotChange]
    public var incomplete: Bool
    public var incompleteReason: String?

    public init(
        beforeUsed: Int64, afterUsed: Int64,
        beforeFree: Int64, afterFree: Int64,
        beforeTotal: Int64, afterTotal: Int64,
        categoryDeltas: [SnapshotCategoryDelta],
        folderChanges: [SnapshotChange],
        incomplete: Bool,
        incompleteReason: String?
    ) {
        self.beforeUsed = beforeUsed
        self.afterUsed = afterUsed
        self.beforeFree = beforeFree
        self.afterFree = afterFree
        self.beforeTotal = beforeTotal
        self.afterTotal = afterTotal
        self.categoryDeltas = categoryDeltas
        self.folderChanges = folderChanges
        self.incomplete = incomplete
        self.incompleteReason = incompleteReason
    }

    public var usedDelta: Int64 { afterUsed - beforeUsed }
    public var freeDelta: Int64 { afterFree - beforeFree }

    public static let empty = SnapshotCompareReport(
        beforeUsed: 0, afterUsed: 0, beforeFree: 0, afterFree: 0,
        beforeTotal: 0, afterTotal: 0, categoryDeltas: [], folderChanges: [],
        incomplete: false, incompleteReason: nil
    )
}

public enum SnapshotCompare {
    public static func report(
        before: DiskSnapshot,
        after: DiskSnapshot,
        beforeMeta: SnapshotMeta?,
        afterMeta: SnapshotMeta?,
        basis: SizeBasis,
        minAbsDelta: Int64 = 0
    ) -> SnapshotCompareReport {
        let beforeRoll = before.tree.rollUpBoth()
        let afterRoll = after.tree.rollUpBoth()
        let beforeTotals = basis == .logical ? beforeRoll.logical : beforeRoll.allocated
        let afterTotals = basis == .logical ? afterRoll.logical : afterRoll.allocated

        let beforeRoot = URL(fileURLWithPath: before.rootPath, isDirectory: true)
        let afterRoot = URL(fileURLWithPath: after.rootPath, isDirectory: true)

        let beforeAnalysis = AnalysisSnapshot.build(
            tree: before.tree,
            root: beforeRoot,
            allocated: beforeRoll.allocated,
            logical: beforeRoll.logical,
            basis: basis,
            quickWins: []
        )
        let afterAnalysis = AnalysisSnapshot.build(
            tree: after.tree,
            root: afterRoot,
            allocated: afterRoll.allocated,
            logical: afterRoll.logical,
            basis: basis,
            quickWins: []
        )

        var catMap: [String: SnapshotCategoryDelta] = [:]
        for c in beforeAnalysis.categories {
            catMap[c.key] = SnapshotCategoryDelta(
                key: c.key, title: c.title, colorHint: c.colorHint,
                before: c.bytes, after: 0
            )
        }
        for c in afterAnalysis.categories {
            if var existing = catMap[c.key] {
                existing = SnapshotCategoryDelta(
                    key: c.key, title: c.title, colorHint: c.colorHint,
                    before: existing.before, after: c.bytes
                )
                catMap[c.key] = existing
            } else {
                catMap[c.key] = SnapshotCategoryDelta(
                    key: c.key, title: c.title, colorHint: c.colorHint,
                    before: 0, after: c.bytes
                )
            }
        }
        let categories = catMap.values
            .filter { $0.delta != 0 }
            .sorted { abs($0.delta) > abs($1.delta) }

        var folders = SnapshotDiff.changes(before: before, after: after, basis: basis)
        if minAbsDelta > 0 {
            folders = folders.filter { abs($0.delta) >= minAbsDelta }
        }

        let beforeUsed = beforeMeta?.usedBytes.map(Int64.init)
            ?? (beforeTotals.first ?? beforeAnalysis.scannedBytes)
        let afterUsed = afterMeta?.usedBytes.map(Int64.init)
            ?? (afterTotals.first ?? afterAnalysis.scannedBytes)
        let beforeFree = beforeMeta?.freeBytes.map(Int64.init) ?? 0
        let afterFree = afterMeta?.freeBytes.map(Int64.init) ?? 0
        let beforeTotal = beforeMeta?.totalBytes.map(Int64.init) ?? (beforeUsed + beforeFree)
        let afterTotal = afterMeta?.totalBytes.map(Int64.init) ?? (afterUsed + afterFree)

        var incomplete = false
        var reason: String?
        if before.rootPath != after.rootPath {
            incomplete = true
            reason = "These snapshots used different scan roots, so some paths may not align."
        }

        return SnapshotCompareReport(
            beforeUsed: beforeUsed,
            afterUsed: afterUsed,
            beforeFree: beforeFree,
            afterFree: afterFree,
            beforeTotal: beforeTotal,
            afterTotal: afterTotal,
            categoryDeltas: categories,
            folderChanges: folders,
            incomplete: incomplete,
            incompleteReason: reason
        )
    }

    public static func filterChanges(
        _ changes: [SnapshotChange],
        kind: SnapshotChangeKind?,
        query: String,
        minAbsDelta: Int64
    ) -> [SnapshotChange] {
        var list = changes
        if let kind {
            list = list.filter { $0.kind == kind }
        }
        if minAbsDelta > 0 {
            list = list.filter { abs($0.delta) >= minAbsDelta }
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.path.lowercased().contains(q) || $0.displayPath.lowercased().contains(q)
            }
        }
        return list
    }

    public static func narrative(for report: SnapshotCompareReport) -> String {
        guard abs(report.usedDelta) > 0 else {
            return "Your storage is effectively unchanged between these snapshots."
        }
        let top = report.categoryDeltas.prefix(3)
        if top.isEmpty {
            let dir = report.usedDelta > 0 ? "increased" : "decreased"
            return "Storage \(dir) by \(byteString(abs(report.usedDelta))), but DiskMap couldn’t confidently attribute the main categories."
        }
        let parts = top.map { "\($0.title) (\(signed($0.delta)))" }
        let dir = report.usedDelta > 0 ? "increased" : "decreased"
        return "Storage \(dir) by \(byteString(abs(report.usedDelta))). Largest contributors: \(parts.joined(separator: ", "))."
    }

    private static func signed(_ delta: Int64) -> String {
        let sign = delta >= 0 ? "+" : "−"
        return "\(sign)\(byteString(abs(delta)))"
    }

    private static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
