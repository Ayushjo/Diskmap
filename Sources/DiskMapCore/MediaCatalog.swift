import Foundation

// MARK: - Media kinds (not FileKind — media-only taxonomy)

public enum MediaKind: String, Sendable, Equatable, CaseIterable, Identifiable {
    case video
    case image
    case audio
    case project
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .video: return "Video"
        case .image: return "Images"
        case .audio: return "Audio"
        case .project: return "Media Projects"
        case .other: return "Other"
        }
    }

    public var shortTitle: String {
        switch self {
        case .video: return "Video"
        case .image: return "Image"
        case .audio: return "Audio"
        case .project: return "Project"
        case .other: return "Media"
        }
    }

    public var symbolName: String {
        switch self {
        case .video: return "film"
        case .image: return "photo"
        case .audio: return "waveform"
        case .project: return "rectangle.stack"
        case .other: return "play.rectangle"
        }
    }
}

public enum MediaTypeFilter: String, Sendable, Equatable, CaseIterable, Identifiable {
    case all, video, image, audio, project, other
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: return "All"
        case .video: return "Video"
        case .image: return "Images"
        case .audio: return "Audio"
        case .project: return "Projects"
        case .other: return "Other"
        }
    }
    public func matches(_ kind: MediaKind) -> Bool {
        switch self {
        case .all: return true
        case .video: return kind == .video
        case .image: return kind == .image
        case .audio: return kind == .audio
        case .project: return kind == .project
        case .other: return kind == .other
        }
    }
}

public enum MediaSizeFilter: String, Sendable, Equatable, CaseIterable, Identifiable {
    case any, mb100, mb500, gb1, gb5, gb10
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .any: return "Any"
        case .mb100: return ">100 MB"
        case .mb500: return ">500 MB"
        case .gb1: return ">1 GB"
        case .gb5: return ">5 GB"
        case .gb10: return ">10 GB"
        }
    }
    public var minBytes: Int64 {
        switch self {
        case .any: return 0
        case .mb100: return 100_000_000
        case .mb500: return 500_000_000
        case .gb1: return 1_000_000_000
        case .gb5: return 5_000_000_000
        case .gb10: return 10_000_000_000
        }
    }
}

public enum MediaAgeFilter: String, Sendable, Equatable, CaseIterable, Identifiable {
    case all, days30, days90, months6, year1
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: return "Any"
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

public enum MediaLocationFilter: String, Sendable, Equatable, CaseIterable, Identifiable {
    case any, downloads, desktop, movies, pictures, music, documents, other
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .any: return "Any"
        case .downloads: return "Downloads"
        case .desktop: return "Desktop"
        case .movies: return "Movies"
        case .pictures: return "Pictures"
        case .music: return "Music"
        case .documents: return "Documents"
        case .other: return "Other"
        }
    }
    public func matches(_ loc: MediaLocationBucket) -> Bool {
        switch self {
        case .any: return true
        case .downloads: return loc == .downloads
        case .desktop: return loc == .desktop
        case .movies: return loc == .movies
        case .pictures: return loc == .pictures
        case .music: return loc == .music
        case .documents: return loc == .documents
        case .other: return loc == .other
        }
    }
}

public enum MediaLocationBucket: String, Sendable, Equatable, CaseIterable, Identifiable {
    case downloads, desktop, movies, pictures, music, documents, other
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .downloads: return "Downloads"
        case .desktop: return "Desktop"
        case .movies: return "Movies"
        case .pictures: return "Pictures"
        case .music: return "Music"
        case .documents: return "Documents"
        case .other: return "Other"
        }
    }
}

public enum MediaSort: String, Sendable, Equatable, CaseIterable, Identifiable {
    case largest, oldest, newest, name, opportunities
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .largest: return "Largest first"
        case .oldest: return "Oldest first"
        case .newest: return "Newest first"
        case .name: return "Name"
        case .opportunities: return "Best cleanup opportunities"
        }
    }
}

/// Personal media is Review first. Never "safe to delete" from age alone.
public enum MediaStatus: String, Sendable, Equatable {
    case reviewFirst
    case likelyDisposable

    public var title: String {
        switch self {
        case .reviewFirst: return "Review first"
        case .likelyDisposable: return "Likely disposable"
        }
    }
}

public struct MediaCandidate: Sendable, Equatable, Identifiable {
    public var id: Int32 { nodeID }
    public var nodeID: Int32
    public var name: String
    public var absolutePath: String
    public var displayPath: String
    public var bytes: Int64
    public var modifiedDay: Int32
    public var ageDays: Int32
    public var kind: MediaKind
    public var location: MediaLocationBucket
    public var status: MediaStatus
    public var safety: SafetyAssessment
    public var whyHere: String
    public var recommendation: String
    public var isDirectory: Bool
    public var score: Double
    /// Optional UI hint (filled lazily in the app layer).
    public var durationLabel: String?
    public var dimensionsLabel: String?

    public init(
        nodeID: Int32,
        name: String,
        absolutePath: String,
        displayPath: String,
        bytes: Int64,
        modifiedDay: Int32,
        ageDays: Int32,
        kind: MediaKind,
        location: MediaLocationBucket,
        status: MediaStatus,
        safety: SafetyAssessment,
        whyHere: String,
        recommendation: String,
        isDirectory: Bool,
        score: Double,
        durationLabel: String? = nil,
        dimensionsLabel: String? = nil
    ) {
        self.nodeID = nodeID
        self.name = name
        self.absolutePath = absolutePath
        self.displayPath = displayPath
        self.bytes = bytes
        self.modifiedDay = modifiedDay
        self.ageDays = ageDays
        self.kind = kind
        self.location = location
        self.status = status
        self.safety = safety
        self.whyHere = whyHere
        self.recommendation = recommendation
        self.isDirectory = isDirectory
        self.score = score
        self.durationLabel = durationLabel
        self.dimensionsLabel = dimensionsLabel
    }
}

public struct MediaBucket: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var bytes: Int64
    public var count: Int
    public var fraction: Double

    public init(id: String, title: String, bytes: Int64, count: Int, fraction: Double) {
        self.id = id
        self.title = title
        self.bytes = bytes
        self.count = count
        self.fraction = fraction
    }
}

public struct MediaSummary: Sendable, Equatable {
    public var totalBytes: Int64
    public var totalCount: Int
    public var videoBytes: Int64
    public var videoCount: Int
    public var imageBytes: Int64
    public var imageCount: Int
    public var audioBytes: Int64
    public var audioCount: Int
    public var projectBytes: Int64
    public var projectCount: Int
    public var over1GBCount: Int
    public var typeBuckets: [MediaBucket]
    public var locationBuckets: [MediaBucket]
    public var ageBuckets: [MediaBucket]
    public var insightLines: [String]

    public static let empty = MediaSummary(
        totalBytes: 0, totalCount: 0,
        videoBytes: 0, videoCount: 0,
        imageBytes: 0, imageCount: 0,
        audioBytes: 0, audioCount: 0,
        projectBytes: 0, projectCount: 0,
        over1GBCount: 0,
        typeBuckets: [], locationBuckets: [], ageBuckets: [],
        insightLines: []
    )

    public init(
        totalBytes: Int64, totalCount: Int,
        videoBytes: Int64, videoCount: Int,
        imageBytes: Int64, imageCount: Int,
        audioBytes: Int64, audioCount: Int,
        projectBytes: Int64, projectCount: Int,
        over1GBCount: Int,
        typeBuckets: [MediaBucket], locationBuckets: [MediaBucket], ageBuckets: [MediaBucket],
        insightLines: [String]
    ) {
        self.totalBytes = totalBytes
        self.totalCount = totalCount
        self.videoBytes = videoBytes
        self.videoCount = videoCount
        self.imageBytes = imageBytes
        self.imageCount = imageCount
        self.audioBytes = audioBytes
        self.audioCount = audioCount
        self.projectBytes = projectBytes
        self.projectCount = projectCount
        self.over1GBCount = over1GBCount
        self.typeBuckets = typeBuckets
        self.locationBuckets = locationBuckets
        self.ageBuckets = ageBuckets
        self.insightLines = insightLines
    }
}

public struct MediaCatalogResult: Sendable, Equatable {
    public var candidates: [MediaCandidate]
    public var summary: MediaSummary
    public var opportunities: [MediaCandidate]

    public static let empty = MediaCatalogResult(candidates: [], summary: .empty, opportunities: [])

    public init(candidates: [MediaCandidate], summary: MediaSummary, opportunities: [MediaCandidate]) {
        self.candidates = candidates
        self.summary = summary
        self.opportunities = opportunities
    }
}

public enum MediaCatalog {
    /// Floor for inclusion in the catalog (images can be smaller than videos).
    public static let listingFloorBytes: Int64 = 500_000

    // Explicit non-media — never appear even if large.
    private static let nonMediaExtensions: Set<String> = [
        "dmg", "iso", "pkg", "img", "app", "zip", "tar", "gz", "tgz", "7z", "rar", "bz2",
        "exe", "msi", "deb", "rpm", "apk", "ipa",
        "vmdk", "vdi", "qcow2", "sparseimage", "sparsebundle",
        "sqlite", "db", "sql", "pdf", "doc", "docx", "pages", "txt", "rtf", "md",
        "csv", "json", "xml", "plist", "log", "bin", "dat"
    ]

    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "mkv", "avi", "m4v", "webm", "wmv", "flv", "mpeg", "mpg", "m2ts", "mts", "ts", "vob", "3gp"
    ]
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tiff", "tif", "bmp", "dng", "cr2", "nef", "orf", "arw", "rw2", "psd", "ico"
    ]
    private static let audioExtensions: Set<String> = [
        "mp3", "wav", "flac", "aac", "m4a", "ogg", "aiff", "aif", "wma", "alac", "opus", "caf"
    ]
    private static let projectExtensions: Set<String> = [
        "fcpbundle", "logicx", "band", "photoslibrary", "imovielibrary", "tvlibrary", "musiclibrary",
        "finalcutproject", "fcpxml", "prproj", "aep", "drp"
    ]

    public static func classify(fileName: String, path: String = "", isDirectory: Bool = false) -> MediaKind? {
        let n = fileName.lowercased()
        let ext = (n as NSString).pathExtension
        let p = path.lowercased()

        // Packages / libraries treated as media projects (often directories).
        if projectExtensions.contains(ext)
            || n.hasSuffix(".photoslibrary")
            || n.hasSuffix(".imovielibrary")
            || n.hasSuffix(".fcpbundle")
            || n.hasSuffix(".logicx")
            || n.hasSuffix(".band")
            || p.contains("/final cut") && isDirectory {
            return .project
        }

        if isDirectory { return nil }

        if nonMediaExtensions.contains(ext) { return nil }
        // Clone/installer naming without relying on extension alone.
        if n.contains(".clone.") && (ext == "dmg" || n.hasSuffix(".dmg")) { return nil }

        if videoExtensions.contains(ext) { return .video }
        if imageExtensions.contains(ext) { return .image }
        if audioExtensions.contains(ext) { return .audio }

        // UTType-ish fallbacks via name patterns (no AppKit in Core).
        if n.hasPrefix("img_") && (ext.isEmpty || imageExtensions.contains(ext) || videoExtensions.contains(ext)) {
            if videoExtensions.contains(ext) { return .video }
            if imageExtensions.contains(ext) || ext.isEmpty { return .image }
        }

        return nil
    }

    public static func locationBucket(for path: String) -> MediaLocationBucket {
        let lower = path.lowercased()
        if lower.contains("/downloads/") || lower.hasSuffix("/downloads") { return .downloads }
        if lower.contains("/desktop/") || lower.hasSuffix("/desktop") { return .desktop }
        if lower.contains("/movies/") || lower.hasSuffix("/movies") { return .movies }
        if lower.contains("/pictures/") || lower.hasSuffix("/pictures") { return .pictures }
        if lower.contains("/music/") || lower.hasSuffix("/music") { return .music }
        if lower.contains("/documents/") || lower.hasSuffix("/documents") { return .documents }
        return .other
    }

    public static func isExcludedSystemPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.hasPrefix("/system/") { return true }
        if lower.contains("/system/volumes/preboot") { return true }
        if lower.contains("/system/volumes/vm") { return true }
        if lower.hasPrefix("/private/var/vm") { return true }
        if lower.hasPrefix("/library/") && !lower.contains("/users/") { return true }
        return false
    }

    public static func build(
        tree: FileTree,
        root: URL,
        totals: [Int64],
        today: Int32 = AgeMap.today(),
        limit: Int = 2000
    ) -> MediaCatalogResult {
        guard totals.count == tree.count else { return .empty }

        var hits: [MediaCandidate] = []
        for id in 0..<Int32(tree.count) {
            let i = Int(id)
            let isDir = tree.isDirectory[i]
            let bytes = totals[i]
            guard bytes >= listingFloorBytes else { continue }
            let abs = tree.path(of: id, root: root).path
            if isExcludedSystemPath(abs) { continue }
            let name = tree.name(of: id)
            guard let kind = classify(fileName: name, path: abs, isDirectory: isDir) else { continue }
            // For directories, only keep media projects (already gated in classify).
            if isDir, kind != .project { continue }

            let safety = SafetyClassifier.assess(path: abs, name: name, isDirectory: isDir)
            if safety.level == .protected { continue }

            let day = tree.modifiedDay[i]
            let age = day > 0 ? max(0, today - day) : 0
            let loc = locationBucket(for: abs)
            let status = classifyStatus(kind: kind, ageDays: age, name: name)
            let why = whyHere(kind: kind, bytes: bytes, ageDays: age, location: loc)
            let rec = recommendation(status: status, kind: kind)
            let score = opportunityScore(bytes: bytes, ageDays: age, kind: kind, location: loc, status: status)

            hits.append(MediaCandidate(
                nodeID: id,
                name: name,
                absolutePath: abs,
                displayPath: CanonicalPath.displayPath(absolutePath: abs),
                bytes: bytes,
                modifiedDay: day,
                ageDays: age,
                kind: kind,
                location: loc,
                status: status,
                safety: safety,
                whyHere: why,
                recommendation: rec,
                isDirectory: isDir,
                score: score
            ))
        }

        hits.sort { $0.bytes > $1.bytes }
        if hits.count > limit { hits = Array(hits.prefix(limit)) }
        let summary = summarize(hits)
        let opportunities = Array(hits.filter { $0.bytes >= 1_000_000_000 }.prefix(5))
        let opp = opportunities.isEmpty ? Array(hits.prefix(5)) : opportunities
        return MediaCatalogResult(candidates: hits, summary: summary, opportunities: opp)
    }

    public static func classifyStatus(kind: MediaKind, ageDays: Int32, name: String) -> MediaStatus {
        let n = name.lowercased()
        // Never mark personal video/photos as disposable from age alone.
        if kind == .video || kind == .image || kind == .project {
            return .reviewFirst
        }
        // Screen recordings / scratch audio mixes sometimes disposable when old.
        if kind == .audio, ageDays >= 365,
           n.contains("mix") || n.contains("bounce") || n.contains("render") || n.contains("scratch") {
            return .likelyDisposable
        }
        return .reviewFirst
    }

    public static func whyHere(kind: MediaKind, bytes: Int64, ageDays: Int32, location: MediaLocationBucket) -> String {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let age = ageLabel(ageDays)
        switch kind {
        case .video:
            return "Large video (\(size)) in \(location.title) that hasn’t been modified in \(age)."
        case .image:
            return "Large image (\(size)) in \(location.title). Unusual size for a still — review before removing."
        case .audio:
            return "Audio file (\(size)) in \(location.title), last modified \(age) ago."
        case .project:
            return "Media project/library (\(size)). Projects often contain caches and media — review inside the creator app when possible."
        case .other:
            return "Media-related item (\(size)) in \(location.title)."
        }
    }

    public static func recommendation(status: MediaStatus, kind: MediaKind) -> String {
        switch status {
        case .reviewFirst:
            return "Personal media. DiskMap can’t determine whether you still need it — review first."
        case .likelyDisposable:
            return "Looks like scratch/export media that may be safe to review, but confirm before removing."
        }
    }

    public static func opportunityScore(
        bytes: Int64, ageDays: Int32, kind: MediaKind,
        location: MediaLocationBucket, status: MediaStatus
    ) -> Double {
        var s = Double(bytes) / 1_000_000.0 * (1.0 + Double(ageDays) / 60.0)
        if location == .downloads || location == .desktop { s *= 1.25 }
        if kind == .video { s *= 1.1 }
        if status == .likelyDisposable { s *= 1.3 }
        return s
    }

    public static func ageLabel(_ days: Int32) -> String {
        if days < 30 { return "\(days)d" }
        if days < 365 {
            let m = max(1, days / 30)
            return "\(m)m"
        }
        let y = days / 365
        let m = (days % 365) / 30
        if m == 0 { return "\(y)y" }
        return "\(y)y \(m)m"
    }

    public static func filter(
        _ items: [MediaCandidate],
        type: MediaTypeFilter,
        size: MediaSizeFilter,
        age: MediaAgeFilter,
        location: MediaLocationFilter,
        query: String
    ) -> [MediaCandidate] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { c in
            guard type.matches(c.kind) else { return false }
            guard c.bytes >= size.minBytes else { return false }
            guard c.ageDays >= age.minAgeDays else { return false }
            guard location.matches(c.location) else { return false }
            if q.isEmpty { return true }
            if q == "video" { return c.kind == .video }
            if q == "image" || q == "photo" || q == "photos" { return c.kind == .image }
            if q == "audio" || q == "music" { return c.kind == .audio || c.location == .music }
            if q == "downloads" { return c.location == .downloads }
            return c.name.lowercased().contains(q)
                || c.displayPath.lowercased().contains(q)
                || c.absolutePath.lowercased().contains(q)
                || c.kind.title.lowercased().contains(q)
                || c.location.title.lowercased().contains(q)
        }
    }

    public static func sorted(_ items: [MediaCandidate], by sort: MediaSort) -> [MediaCandidate] {
        switch sort {
        case .largest: return items.sorted { $0.bytes > $1.bytes }
        case .oldest: return items.sorted { $0.ageDays > $1.ageDays }
        case .newest: return items.sorted { $0.ageDays < $1.ageDays }
        case .name: return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .opportunities: return items.sorted { $0.score > $1.score }
        }
    }

    public static func summarize(_ items: [MediaCandidate]) -> MediaSummary {
        var total: Int64 = 0
        var videoB: Int64 = 0, imageB: Int64 = 0, audioB: Int64 = 0, projectB: Int64 = 0, otherB: Int64 = 0
        var videoC = 0, imageC = 0, audioC = 0, projectC = 0, otherC = 0
        var over1 = 0
        var locBytes: [MediaLocationBucket: Int64] = [:]
        var locCount: [MediaLocationBucket: Int] = [:]
        var ageA: Int64 = 0, ageB: Int64 = 0, ageC: Int64 = 0, ageD: Int64 = 0, ageE: Int64 = 0
        var ageAc = 0, ageBc = 0, ageCc = 0, ageDc = 0, ageEc = 0

        for c in items {
            total += c.bytes
            if c.bytes >= 1_000_000_000 { over1 += 1 }
            switch c.kind {
            case .video: videoB += c.bytes; videoC += 1
            case .image: imageB += c.bytes; imageC += 1
            case .audio: audioB += c.bytes; audioC += 1
            case .project: projectB += c.bytes; projectC += 1
            case .other: otherB += c.bytes; otherC += 1
            }
            locBytes[c.location, default: 0] += c.bytes
            locCount[c.location, default: 0] += 1
            switch c.ageDays {
            case ..<30: ageA += c.bytes; ageAc += 1
            case 30..<90: ageB += c.bytes; ageBc += 1
            case 90..<365: ageC += c.bytes; ageCc += 1
            case 365..<730: ageD += c.bytes; ageDc += 1
            default: ageE += c.bytes; ageEc += 1
            }
        }

        func frac(_ b: Int64) -> Double { total > 0 ? Double(b) / Double(total) : 0 }

        let typeBuckets: [MediaBucket] = [
            MediaBucket(id: "video", title: "Video", bytes: videoB, count: videoC, fraction: frac(videoB)),
            MediaBucket(id: "image", title: "Images", bytes: imageB, count: imageC, fraction: frac(imageB)),
            MediaBucket(id: "audio", title: "Audio", bytes: audioB, count: audioC, fraction: frac(audioB)),
            MediaBucket(id: "project", title: "Media Projects", bytes: projectB, count: projectC, fraction: frac(projectB)),
            MediaBucket(id: "other", title: "Other", bytes: otherB, count: otherC, fraction: frac(otherB)),
        ].filter { $0.bytes > 0 || $0.count > 0 }

        let locOrder: [MediaLocationBucket] = [.downloads, .desktop, .movies, .pictures, .music, .documents, .other]
        let locationBuckets = locOrder.compactMap { loc -> MediaBucket? in
            let b = locBytes[loc] ?? 0
            let c = locCount[loc] ?? 0
            guard b > 0 else { return nil }
            return MediaBucket(id: loc.rawValue, title: loc.title, bytes: b, count: c, fraction: frac(b))
        }

        let ageBuckets: [MediaBucket] = [
            MediaBucket(id: "a30", title: "< 30 days", bytes: ageA, count: ageAc, fraction: frac(ageA)),
            MediaBucket(id: "a90", title: "30–90 days", bytes: ageB, count: ageBc, fraction: frac(ageB)),
            MediaBucket(id: "a365", title: "90 days–1 year", bytes: ageC, count: ageCc, fraction: frac(ageC)),
            MediaBucket(id: "a730", title: "1–2 years", bytes: ageD, count: ageDc, fraction: frac(ageD)),
            MediaBucket(id: "a2p", title: "2+ years", bytes: ageE, count: ageEc, fraction: frac(ageE)),
        ].filter { $0.bytes > 0 }

        var insights: [String] = []
        if let topLoc = locationBuckets.first {
            insights.append("\(ByteCountFormatter.string(fromByteCount: topLoc.bytes, countStyle: .file)) of media is in \(topLoc.title).")
        }
        if ageE > 0 {
            insights.append("\(ByteCountFormatter.string(fromByteCount: ageE, countStyle: .file)) of media hasn’t been modified in over 2 years.")
        } else if ageD > 0 {
            insights.append("\(ByteCountFormatter.string(fromByteCount: ageD, countStyle: .file)) of media hasn’t been modified in over a year.")
        }
        if videoB > 0 {
            insights.append("Video accounts for \(Int((frac(videoB) * 100).rounded()))% of media storage.")
        }

        return MediaSummary(
            totalBytes: total, totalCount: items.count,
            videoBytes: videoB, videoCount: videoC,
            imageBytes: imageB, imageCount: imageC,
            audioBytes: audioB, audioCount: audioC,
            projectBytes: projectB, projectCount: projectC,
            over1GBCount: over1,
            typeBuckets: typeBuckets, locationBuckets: locationBuckets, ageBuckets: ageBuckets,
            insightLines: insights
        )
    }
}
