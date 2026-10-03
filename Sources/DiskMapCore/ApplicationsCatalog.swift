import Foundation

public enum ApplicationSource: String, Sendable, Equatable, CaseIterable, Identifiable {
    case system
    case appStore
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "System"
        case .appStore: return "App Store"
        case .other: return "Other"
        }
    }
}

public enum ApplicationStatus: String, Sendable, Equatable, CaseIterable, Identifiable {
    case keep
    case reviewFirst
    case system

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .keep: return "Keep"
        case .reviewFirst: return "Review first"
        case .system: return "System"
        }
    }
}

public enum ApplicationFilter: String, Sendable, Equatable, CaseIterable, Identifiable {
    case all
    case large
    case notRecentlyUsed
    case system
    case appStore
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "All Applications"
        case .large: return "Large Apps"
        case .notRecentlyUsed: return "Not Recently Used"
        case .system: return "System Apps"
        case .appStore: return "App Store"
        case .other: return "Other Sources"
        }
    }
}

public enum ApplicationRelatedKind: String, Sendable, Equatable, Identifiable {
    case caches
    case applicationSupport
    case containers
    case preferences
    case derivedData
    case simulators
    case archives
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .caches: return "Caches"
        case .applicationSupport: return "Application Support"
        case .containers: return "Containers"
        case .preferences: return "Preferences"
        case .derivedData: return "Derived Data"
        case .simulators: return "Simulators"
        case .archives: return "Archives"
        case .other: return "Other"
        }
    }
}

public struct ApplicationRelatedItem: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var kind: ApplicationRelatedKind
    public var path: String
    public var displayName: String
    public var bytes: Int64

    public init(kind: ApplicationRelatedKind, path: String, displayName: String, bytes: Int64) {
        self.kind = kind
        self.path = path
        self.displayName = displayName
        self.bytes = bytes
    }
}

public struct ApplicationEntry: Sendable, Equatable, Identifiable {
    public var id: String { bundlePath }
    public var name: String
    public var publisher: String?
    public var version: String?
    public var bundleID: String?
    public var bundlePath: String
    public var bundleBytes: Int64
    public var relatedBytes: Int64
    public var source: ApplicationSource
    public var status: ApplicationStatus
    public var lastUsed: Date?
    public var installed: Date?
    public var related: [ApplicationRelatedItem]
    public var blurb: String
    public var whyLarge: String
    public var removalGuidance: String
    /// True while allocated size is still being measured.
    public var sizePending: Bool

    public init(
        name: String,
        publisher: String?,
        version: String?,
        bundleID: String?,
        bundlePath: String,
        bundleBytes: Int64,
        relatedBytes: Int64,
        source: ApplicationSource,
        status: ApplicationStatus,
        lastUsed: Date?,
        installed: Date?,
        related: [ApplicationRelatedItem],
        blurb: String,
        whyLarge: String,
        removalGuidance: String,
        sizePending: Bool
    ) {
        self.name = name
        self.publisher = publisher
        self.version = version
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.bundleBytes = bundleBytes
        self.relatedBytes = relatedBytes
        self.source = source
        self.status = status
        self.lastUsed = lastUsed
        self.installed = installed
        self.related = related
        self.blurb = blurb
        self.whyLarge = whyLarge
        self.removalGuidance = removalGuidance
        self.sizePending = sizePending
    }

    public var totalBytes: Int64 { bundleBytes + relatedBytes }

    public var isLarge: Bool { totalBytes >= ApplicationsCatalog.largeThresholdBytes }

    public var isNotRecentlyUsed: Bool {
        ApplicationsCatalog.isNotRecentlyUsed(lastUsed: lastUsed)
    }

    public var canStageForCleanup: Bool { status != .system }
}

public struct ApplicationSummary: Sendable, Equatable {
    public var appCount: Int
    public var totalBytes: Int64
    public var reviewableBytes: Int64
    public var largeCount: Int
    public var notRecentlyUsedCount: Int
    public var systemCount: Int
    public var appStoreCount: Int
    public var otherCount: Int
    public var reviewCandidateCount: Int

    public init(
        appCount: Int,
        totalBytes: Int64,
        reviewableBytes: Int64,
        largeCount: Int,
        notRecentlyUsedCount: Int,
        systemCount: Int,
        appStoreCount: Int,
        otherCount: Int,
        reviewCandidateCount: Int
    ) {
        self.appCount = appCount
        self.totalBytes = totalBytes
        self.reviewableBytes = reviewableBytes
        self.largeCount = largeCount
        self.notRecentlyUsedCount = notRecentlyUsedCount
        self.systemCount = systemCount
        self.appStoreCount = appStoreCount
        self.otherCount = otherCount
        self.reviewCandidateCount = reviewCandidateCount
    }

    public static let empty = ApplicationSummary(
        appCount: 0, totalBytes: 0, reviewableBytes: 0,
        largeCount: 0, notRecentlyUsedCount: 0,
        systemCount: 0, appStoreCount: 0, otherCount: 0,
        reviewCandidateCount: 0
    )
}

public enum ApplicationsCatalog {
    public static let largeThresholdBytes: Int64 = 1_000_000_000
    public static let notRecentlyUsedDays: Int = 180

    public static func isNotRecentlyUsed(lastUsed: Date?, now: Date = Date()) -> Bool {
        guard let lastUsed else { return false }
        let days = Calendar.current.dateComponents([.day], from: lastUsed, to: now).day ?? 0
        return days >= notRecentlyUsedDays
    }

    public static func classifySource(bundlePath: String, bundleID: String?) -> ApplicationSource {
        let path = bundlePath
        if path.hasPrefix("/System/") {
            return .system
        }
        if path.hasPrefix("/Applications/") {
            let name = (path as NSString).lastPathComponent.lowercased()
            let systemNames: Set<String> = [
                "safari.app", "mail.app", "messages.app", "facetime.app", "maps.app",
                "photos.app", "preview.app", "music.app", "tv.app", "podcasts.app",
                "books.app", "app store.app", "system settings.app", "system preferences.app",
                "finder.app", "calendar.app", "contacts.app", "notes.app", "reminders.app",
                "freeform.app", "home.app", "shortcuts.app", "voice memos.app", "clock.app",
                "weather.app", "stocks.app", "calculator.app", "dictionary.app", "chess.app",
                "textedit.app", "terminal.app", "console.app", "activity monitor.app",
                "disk utility.app", "script editor.app", "automator.app", "font book.app",
                "image capture.app", "quicktime player.app", "photo booth.app", "stickies.app",
                "tips.app", "news.app"
            ]
            if systemNames.contains(name) { return .system }
            if let bid = bundleID?.lowercased(), bid.hasPrefix("com.apple."), !bid.contains("xcode") {
                // Many Apple apps in /Applications are system-ish; Xcode is App Store / other.
                if bid == "com.apple.safari" || bid.hasPrefix("com.apple.iwork") || bid.hasPrefix("com.apple.dt") {
                    // iWork / Xcode handled below
                } else if !bid.contains("garageband") && !bid.contains("iwork") && !bid.contains("finalcut") {
                    // leave for receipt check
                }
            }
        }
        let receipt = URL(fileURLWithPath: bundlePath)
            .appendingPathComponent("Contents/_MASReceipt/receipt")
        if FileManager.default.fileExists(atPath: receipt.path) {
            return .appStore
        }
        if path.hasPrefix("/System/") { return .system }
        return .other
    }

    public static func classifyStatus(
        source: ApplicationSource,
        totalBytes: Int64,
        lastUsed: Date?,
        bundleID: String?
    ) -> ApplicationStatus {
        if source == .system { return .system }
        if let bid = bundleID?.lowercased(), bid.hasPrefix("com.apple."), source != .appStore {
            // Protected Apple tooling still reviewable if third-party location, else system
            if bid.contains("xcode") || bid.contains("instruments") { return .keep }
        }
        let stale = isNotRecentlyUsed(lastUsed: lastUsed)
        let large = totalBytes >= largeThresholdBytes
        if large && stale { return .reviewFirst }
        if stale && totalBytes >= 500_000_000 { return .reviewFirst }
        if large && lastUsed == nil { return .reviewFirst }
        return .keep
    }

    public static func relatedKind(forPath path: String) -> ApplicationRelatedKind {
        let lower = path.lowercased()
        if lower.contains("deriveddata") { return .derivedData }
        if lower.contains("coresimulator") || lower.contains("simulator") { return .simulators }
        if lower.contains("/archives") || lower.hasSuffix("archives") { return .archives }
        if lower.contains("/library/caches") || lower.contains("/caches/") { return .caches }
        if lower.contains("application support") { return .applicationSupport }
        if lower.contains("/containers") || lower.contains("group containers") { return .containers }
        if lower.contains("/preferences") || lower.hasSuffix(".plist") { return .preferences }
        return .other
    }

    public static func relatedItems(from leftovers: AppLeftovers) -> [ApplicationRelatedItem] {
        leftovers.leftoverEntries.map { entry in
            let path = entry.url.path
            let kind = relatedKind(forPath: path)
            return ApplicationRelatedItem(
                kind: kind,
                path: path,
                displayName: kind.title == "Other" ? entry.url.lastPathComponent : kind.title,
                bytes: entry.bytes
            )
        }
        .sorted { $0.bytes > $1.bytes }
    }

    /// Collapse same-kind leftovers into rollups for inspector breakdown.
    public static func relatedRollups(from items: [ApplicationRelatedItem]) -> [(kind: ApplicationRelatedKind, bytes: Int64)] {
        var map: [ApplicationRelatedKind: Int64] = [:]
        for item in items {
            map[item.kind, default: 0] += item.bytes
        }
        return map.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }

    public static func blurb(forName name: String, bundleID: String?) -> String {
        let n = name.lowercased()
        let bid = bundleID?.lowercased() ?? ""
        if n.contains("xcode") || bid.contains("xcode") {
            return "Xcode is Apple's development environment for building apps for Apple platforms."
        }
        if n.contains("docker") { return "Docker provides container tooling for running isolated development environments." }
        if n.contains("chrome") { return "Google Chrome is a web browser." }
        if n.contains("safari") { return "Safari is Apple's web browser." }
        if n.contains("spotify") { return "Spotify is a music streaming application." }
        if n.contains("slack") { return "Slack is a team messaging and collaboration app." }
        if n.contains("visual studio code") || n == "code" || bid.contains("vscode") {
            return "Visual Studio Code is a code editor from Microsoft."
        }
        if n.contains("android studio") { return "Android Studio is Google's IDE for Android development." }
        if n.contains("final cut") { return "Final Cut Pro is Apple's professional video editor." }
        if n.contains("figma") { return "Figma is a collaborative interface design app." }
        if n.contains("notion") { return "Notion is a notes and workspace app." }
        if n.contains("zoom") { return "Zoom is a video conferencing application." }
        return "\(name) is an installed macOS application."
    }

    public static func whyLarge(name: String, bundleBytes: Int64, related: [ApplicationRelatedItem]) -> String {
        let relatedTotal = related.reduce(Int64(0)) { $0 + $1.bytes }
        if relatedTotal <= 0 {
            return "Most of \(name)'s measured storage is the application bundle itself (\(ByteCountFormatter.string(fromByteCount: bundleBytes, countStyle: .file)))."
        }
        let top = related.prefix(3).map { "\($0.displayName) (\(ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file)))" }
        return "\(name)'s bundle is \(ByteCountFormatter.string(fromByteCount: bundleBytes, countStyle: .file)). Related data adds \(ByteCountFormatter.string(fromByteCount: relatedTotal, countStyle: .file)), mainly \(top.joined(separator: ", "))."
    }

    public static func removalGuidance(status: ApplicationStatus, name: String) -> String {
        switch status {
        case .system:
            return "This is a system application. DiskMap will not stage it for cleanup."
        case .reviewFirst:
            return "Review first. Removing \(name) deletes the application bundle; related user data may remain until you clear it separately."
        case .keep:
            return "Removing \(name) will delete the application bundle. Related caches and support files may remain. Stage only if you no longer need the app."
        }
    }

    public static func makeEntry(
        leftovers: AppLeftovers,
        publisher: String?,
        version: String?,
        lastUsed: Date?,
        installed: Date?,
        sizePending: Bool = false
    ) -> ApplicationEntry {
        let related = sizePending ? [] : relatedItems(from: leftovers)
        let relatedBytes = sizePending ? Int64(0) : related.reduce(Int64(0)) { $0 + $1.bytes }
        let source = classifySource(bundlePath: leftovers.bundlePath.path, bundleID: leftovers.bundleID)
        let total = leftovers.bundleSize + relatedBytes
        let status = classifyStatus(
            source: source,
            totalBytes: total,
            lastUsed: lastUsed,
            bundleID: leftovers.bundleID
        )
        return ApplicationEntry(
            name: leftovers.appName,
            publisher: publisher,
            version: version,
            bundleID: leftovers.bundleID,
            bundlePath: leftovers.bundlePath.path,
            bundleBytes: leftovers.bundleSize,
            relatedBytes: relatedBytes,
            source: source,
            status: status,
            lastUsed: lastUsed,
            installed: installed,
            related: related,
            blurb: blurb(forName: leftovers.appName, bundleID: leftovers.bundleID),
            whyLarge: whyLarge(name: leftovers.appName, bundleBytes: leftovers.bundleSize, related: related),
            removalGuidance: removalGuidance(status: status, name: leftovers.appName),
            sizePending: sizePending
        )
    }

    public static func summarize(_ apps: [ApplicationEntry]) -> ApplicationSummary {
        var total: Int64 = 0
        var reviewable: Int64 = 0
        var large = 0
        var stale = 0
        var system = 0
        var store = 0
        var other = 0
        var reviewCandidates = 0
        for app in apps {
            total += app.totalBytes
            if app.status == .reviewFirst {
                reviewable += app.totalBytes
                reviewCandidates += 1
            }
            if app.isLarge { large += 1 }
            if app.isNotRecentlyUsed { stale += 1 }
            switch app.source {
            case .system: system += 1
            case .appStore: store += 1
            case .other: other += 1
            }
        }
        return ApplicationSummary(
            appCount: apps.count,
            totalBytes: total,
            reviewableBytes: reviewable,
            largeCount: large,
            notRecentlyUsedCount: stale,
            systemCount: system,
            appStoreCount: store,
            otherCount: other,
            reviewCandidateCount: reviewCandidates
        )
    }

    public static func filter(_ apps: [ApplicationEntry], _ filter: ApplicationFilter) -> [ApplicationEntry] {
        switch filter {
        case .all: return apps
        case .large: return apps.filter(\.isLarge)
        case .notRecentlyUsed: return apps.filter(\.isNotRecentlyUsed)
        case .system: return apps.filter { $0.source == .system }
        case .appStore: return apps.filter { $0.source == .appStore }
        case .other: return apps.filter { $0.source == .other }
        }
    }

    public enum Sort: String, Sendable, CaseIterable, Identifiable {
        case sizeDesc, sizeAsc, nameAsc, lastUsedDesc, lastUsedAsc, source

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .sizeDesc: return "Size · Largest"
            case .sizeAsc: return "Size · Smallest"
            case .nameAsc: return "Name"
            case .lastUsedDesc: return "Recently used"
            case .lastUsedAsc: return "Least recently used"
            case .source: return "Source"
            }
        }
    }

    public static func sorted(_ apps: [ApplicationEntry], by sort: Sort) -> [ApplicationEntry] {
        switch sort {
        case .sizeDesc: return apps.sorted { $0.totalBytes > $1.totalBytes }
        case .sizeAsc: return apps.sorted { $0.totalBytes < $1.totalBytes }
        case .nameAsc: return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .lastUsedDesc:
            return apps.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
        case .lastUsedAsc:
            return apps.sorted { ($0.lastUsed ?? .distantFuture) < ($1.lastUsed ?? .distantFuture) }
        case .source:
            return apps.sorted {
                if $0.source.title == $1.source.title {
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return $0.source.title < $1.source.title
            }
        }
    }
}
