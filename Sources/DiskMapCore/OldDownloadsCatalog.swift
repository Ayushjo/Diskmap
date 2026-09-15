import Foundation

public enum OldDownloadsAgeFilter: String, Sendable, Equatable, CaseIterable, Identifiable {
    case all
    case days30
    case days90
    case months6
    case year1

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "All"
        case .days30: return "30d+"
        case .days90: return "90d+"
        case .months6: return "6mo+"
        case .year1: return "1y+"
        }
    }

    public var minAgeDays: Int32 {
        switch self {
        case .all: return 0
        case .days30: return 30
        case .days90: return 90
        case .months6: return 180
        case .year1: return 365
        }
    }
}

public enum OldDownloadsSizeFilter: String, Sendable, Equatable, CaseIterable, Identifiable {
    case any
    case mb100
    case mb500
    case gb1
    case gb5

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .any: return "Any"
        case .mb100: return ">100 MB"
        case .mb500: return ">500 MB"
        case .gb1: return ">1 GB"
        case .gb5: return ">5 GB"
        }
    }

    public var minBytes: Int64 {
        switch self {
        case .any: return 0
        case .mb100: return 100_000_000
        case .mb500: return 500_000_000
        case .gb1: return 1_000_000_000
        case .gb5: return 5_000_000_000
        }
    }
}

public enum OldDownloadsTypeFilter: String, Sendable, Equatable, CaseIterable, Identifiable {
    case all
    case video
    case archive
    case installer
    case document
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "All"
        case .video: return "Videos"
        case .archive: return "Archives"
        case .installer: return "Installers"
        case .document: return "Documents"
        case .other: return "Other"
        }
    }

    public func matches(_ kind: FileKind) -> Bool {
        switch self {
        case .all: return true
        case .video: return kind == .video
        case .archive: return kind == .archive
        case .installer: return kind == .diskImage
        case .document: return kind == .document
        case .other: return kind != .video && kind != .archive && kind != .diskImage && kind != .document
        }
    }
}

public enum OldDownloadsSort: String, Sendable, Equatable, CaseIterable, Identifiable {
    case largest
    case oldest
    case newest
    case name
    case smart

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .largest: return "Largest first"
        case .oldest: return "Oldest first"
        case .newest: return "Newest first"
        case .name: return "Name"
        case .smart: return "Smart (space × age)"
        }
    }
}

/// Inclusion status for Old Downloads — never "safe to delete" for personal media.
public enum OldDownloadsStatus: String, Sendable, Equatable {
    case reviewFirst
    case likelyDisposable

    public var title: String {
        switch self {
        case .reviewFirst: return "Review first"
        case .likelyDisposable: return "Likely disposable"
        }
    }
}

public struct OldDownloadsCandidate: Sendable, Equatable, Identifiable {
    public var id: Int32 { nodeID }
    public var nodeID: Int32
    public var name: String
    public var absolutePath: String
    public var displayPath: String
    public var bytes: Int64
    public var modifiedDay: Int32
    public var ageDays: Int32
    public var kind: FileKind
    public var status: OldDownloadsStatus
    public var safety: SafetyAssessment
    public var whyHere: String
    public var recommendation: String
    public var score: Double

    public init(
        nodeID: Int32,
        name: String,
        absolutePath: String,
        displayPath: String,
        bytes: Int64,
        modifiedDay: Int32,
        ageDays: Int32,
        kind: FileKind,
        status: OldDownloadsStatus,
        safety: SafetyAssessment,
        whyHere: String,
        recommendation: String,
        score: Double
    ) {
        self.nodeID = nodeID
        self.name = name
        self.absolutePath = absolutePath
        self.displayPath = displayPath
        self.bytes = bytes
        self.modifiedDay = modifiedDay
        self.ageDays = ageDays
        self.kind = kind
        self.status = status
        self.safety = safety
        self.whyHere = whyHere
        self.recommendation = recommendation
        self.score = score
    }
}

public struct OldDownloadsAgeBucket: Sendable, Equatable, Identifiable {
    public var id: String { title }
    public var title: String
    public var bytes: Int64
    public var count: Int
}

public struct OldDownloadsTypeBucket: Sendable, Equatable, Identifiable {
    public var id: String { kind.rawValue }
    public var kind: FileKind
    public var bytes: Int64
    public var count: Int
}

public struct OldDownloadsSummary: Sendable, Equatable {
    public var totalBytes: Int64
    public var totalCount: Int
    public var bytes30: Int64
    public var count30: Int
    public var bytes90: Int64
    public var count90: Int
    public var bytes365: Int64
    public var count365: Int
    public var reviewCount: Int
    public var ageBuckets: [OldDownloadsAgeBucket]
    public var typeBuckets: [OldDownloadsTypeBucket]
    public var insightLines: [String]

    public static let empty = OldDownloadsSummary(
        totalBytes: 0, totalCount: 0,
        bytes30: 0, count30: 0, bytes90: 0, count90: 0, bytes365: 0, count365: 0,
        reviewCount: 0, ageBuckets: [], typeBuckets: [], insightLines: []
    )

    public init(
        totalBytes: Int64, totalCount: Int,
        bytes30: Int64, count30: Int, bytes90: Int64, count90: Int, bytes365: Int64, count365: Int,
        reviewCount: Int, ageBuckets: [OldDownloadsAgeBucket], typeBuckets: [OldDownloadsTypeBucket],
        insightLines: [String]
    ) {
        self.totalBytes = totalBytes
        self.totalCount = totalCount
        self.bytes30 = bytes30
        self.count30 = count30
        self.bytes90 = bytes90
        self.count90 = count90
        self.bytes365 = bytes365
        self.count365 = count365
        self.reviewCount = reviewCount
        self.ageBuckets = ageBuckets
        self.typeBuckets = typeBuckets
        self.insightLines = insightLines
    }
}

public struct OldDownloadsCatalogResult: Sendable, Equatable {
    public var candidates: [OldDownloadsCandidate]
    public var summary: OldDownloadsSummary

    public static let empty = OldDownloadsCatalogResult(candidates: [], summary: .empty)

    public init(candidates: [OldDownloadsCandidate], summary: OldDownloadsSummary) {
        self.candidates = candidates
        self.summary = summary
    }
}

public enum OldDownloadsCatalog {
    /// Minimum size to appear when age is young; always include older files above this floor.
    public static let listingFloorBytes: Int64 = 1_000_000

    public static func build(
        tree: FileTree,
        root: URL,
        totals: [Int64],
        today: Int32 = AgeMap.today(),
        limit: Int = 500
    ) -> OldDownloadsCatalogResult {
        guard totals.count == tree.count else { return .empty }

        var hits: [OldDownloadsCandidate] = []
        for id in 0..<Int32(tree.count) {
            let i = Int(id)
            if tree.isDirectory[i] { continue }
            let bytes = totals[i]
            guard bytes >= listingFloorBytes else { continue }
            let abs = tree.path(of: id, root: root).path
            guard isUnderDownloads(abs) else { continue }
            let name = tree.name(of: id)
            let day = tree.modifiedDay[i]
            let age = day > 0 ? max(0, today - day) : 0
            let kind = FileKind.classify(fileName: name, path: abs)
            let safety = SafetyClassifier.assess(path: abs, name: name, isDirectory: false)
            if safety.level == .protected { continue }
            let status = classifyStatus(kind: kind, ageDays: age, name: name)
            let why = whyHere(name: name, kind: kind, bytes: bytes, ageDays: age)
            let rec = recommendation(status: status, kind: kind)
            let score = Double(bytes) / 1_000_000.0 * (1.0 + Double(age) / 30.0)
                * (status == .likelyDisposable ? 1.4 : 1.0)
            hits.append(OldDownloadsCandidate(
                nodeID: id,
                name: name,
                absolutePath: abs,
                displayPath: CanonicalPath.displayPath(absolutePath: abs),
                bytes: bytes,
                modifiedDay: day,
                ageDays: age,
                kind: kind,
                status: status,
                safety: safety,
                whyHere: why,
                recommendation: rec,
                score: score
            ))
        }

        hits.sort { $0.bytes > $1.bytes }
        if hits.count > limit { hits = Array(hits.prefix(limit)) }
        let summary = summarize(hits)
        return OldDownloadsCatalogResult(candidates: hits, summary: summary)
    }

    public static func isUnderDownloads(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.contains("/downloads/") || lower.hasSuffix("/downloads")
            || lower.contains("/downloads")
    }

    public static func classifyStatus(kind: FileKind, ageDays: Int32, name: String) -> OldDownloadsStatus {
        let n = name.lowercased()
        // Installers / disk images older than 90 days → likely disposable
        if kind == .diskImage, ageDays >= 90 { return .likelyDisposable }
        if kind == .archive, ageDays >= 180,
           n.contains("installer") || n.contains("setup") || n.hasSuffix(".pkg.zip") {
            return .likelyDisposable
        }
        return .reviewFirst
    }

    public static func whyHere(name: String, kind: FileKind, bytes: Int64, ageDays: Int32) -> String {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let age = ageLabel(ageDays)
        switch kind {
        case .video:
            return "Large video (\(size)) in Downloads that hasn’t been modified recently (\(age))."
        case .diskImage:
            return "Installer or disk image (\(size)) in Downloads, last modified \(age)."
        case .archive:
            return "Archive (\(size)) in Downloads, last modified \(age)."
        case .document:
            return "Document (\(size)) in Downloads, last modified \(age). Review carefully — it may still matter."
        default:
            return "\(name) (\(size)) in Downloads, last modified \(age)."
        }
    }

    public static func recommendation(status: OldDownloadsStatus, kind: FileKind) -> String {
        switch status {
        case .likelyDisposable:
            return "If the software is already installed and you don’t need the installer again, this may be reasonable to remove via Cleanup Review."
        case .reviewFirst:
            if kind == .video || kind == .document {
                return "This looks like a personal file. DiskMap can’t determine whether you still need it. Review before removing."
            }
            return "Review first. Old doesn’t mean unused — confirm you no longer need this before staging."
        }
    }

    public static func ageLabel(_ days: Int32) -> String {
        if days <= 0 { return "unknown age" }
        if days < 30 { return "\(days)d ago" }
        if days < 365 {
            let m = days / 30
            return "\(m)mo ago"
        }
        let y = days / 365
        let m = (days % 365) / 30
        if m == 0 { return "\(y)y ago" }
        return "\(y)y \(m)m ago"
    }

    public static func filter(
        _ candidates: [OldDownloadsCandidate],
        age: OldDownloadsAgeFilter,
        size: OldDownloadsSizeFilter,
        type: OldDownloadsTypeFilter,
        query: String
    ) -> [OldDownloadsCandidate] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return candidates.filter { c in
            guard c.ageDays >= age.minAgeDays else { return false }
            guard c.bytes >= size.minBytes else { return false }
            guard type.matches(c.kind) else { return false }
            if q.isEmpty { return true }
            return c.name.lowercased().contains(q)
                || c.displayPath.lowercased().contains(q)
                || c.kind.title.lowercased().contains(q)
        }
    }

    public static func sorted(_ candidates: [OldDownloadsCandidate], by sort: OldDownloadsSort) -> [OldDownloadsCandidate] {
        switch sort {
        case .largest: return candidates.sorted { $0.bytes > $1.bytes }
        case .oldest: return candidates.sorted { $0.ageDays > $1.ageDays }
        case .newest: return candidates.sorted { $0.ageDays < $1.ageDays }
        case .name: return candidates.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .smart: return candidates.sorted { $0.score > $1.score }
        }
    }

    public static func summarize(_ candidates: [OldDownloadsCandidate]) -> OldDownloadsSummary {
        var total: Int64 = 0
        var b30: Int64 = 0, c30 = 0
        var b90: Int64 = 0, c90 = 0
        var b365: Int64 = 0, c365 = 0
        var ageMap: [String: (Int64, Int)] = [
            "<30 days": (0, 0),
            "30–90 days": (0, 0),
            "90d–1 year": (0, 0),
            "1–2 years": (0, 0),
            "2+ years": (0, 0),
        ]
        var typeMap: [FileKind: (Int64, Int)] = [:]

        for c in candidates {
            total += c.bytes
            if c.ageDays >= 30 { b30 += c.bytes; c30 += 1 }
            if c.ageDays >= 90 { b90 += c.bytes; c90 += 1 }
            if c.ageDays >= 365 { b365 += c.bytes; c365 += 1 }

            let bucket: String
            if c.ageDays < 30 { bucket = "<30 days" }
            else if c.ageDays < 90 { bucket = "30–90 days" }
            else if c.ageDays < 365 { bucket = "90d–1 year" }
            else if c.ageDays < 730 { bucket = "1–2 years" }
            else { bucket = "2+ years" }
            var a = ageMap[bucket] ?? (0, 0)
            a.0 += c.bytes
            a.1 += 1
            ageMap[bucket] = a

            var t = typeMap[c.kind] ?? (0, 0)
            t.0 += c.bytes
            t.1 += 1
            typeMap[c.kind] = t
        }

        let ageOrder = ["<30 days", "30–90 days", "90d–1 year", "1–2 years", "2+ years"]
        let ageBuckets = ageOrder.compactMap { title -> OldDownloadsAgeBucket? in
            guard let v = ageMap[title], v.0 > 0 else { return nil }
            return OldDownloadsAgeBucket(title: title, bytes: v.0, count: v.1)
        }
        let typeBuckets = typeMap
            .map { OldDownloadsTypeBucket(kind: $0.key, bytes: $0.value.0, count: $0.value.1) }
            .sorted { $0.bytes > $1.bytes }

        var insights: [String] = []
        if total > 0 {
            insights.append("Downloads has \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) of files matching this view.")
        }
        let videos = candidates.filter { $0.kind == .video }.sorted { $0.bytes > $1.bytes }
        if videos.count >= 1 {
            let top = videos.prefix(3)
            let vBytes = top.reduce(Int64(0)) { $0 + $1.bytes }
            insights.append("\(ByteCountFormatter.string(fromByteCount: vBytes, countStyle: .file)) comes from \(top.count) large video file\(top.count == 1 ? "" : "s").")
        }
        if b365 > 0 {
            insights.append("\(ByteCountFormatter.string(fromByteCount: b365, countStyle: .file)) hasn’t been modified in over a year.")
        }
        insights.append("Nothing here is automatically considered safe to delete.")

        return OldDownloadsSummary(
            totalBytes: total,
            totalCount: candidates.count,
            bytes30: b30, count30: c30,
            bytes90: b90, count90: c90,
            bytes365: b365, count365: c365,
            reviewCount: candidates.count,
            ageBuckets: ageBuckets,
            typeBuckets: typeBuckets,
            insightLines: insights
        )
    }
}
