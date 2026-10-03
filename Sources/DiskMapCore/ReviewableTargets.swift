import Foundation

public enum ReviewableCategory: String, Sendable, Equatable, CaseIterable, Identifiable {
    case caches
    case buildArtifacts
    case packageCaches
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .caches: return "Caches"
        case .buildArtifacts: return "Build artifacts"
        case .packageCaches: return "Package caches"
        case .other: return "Other reviewable"
        }
    }
}

public struct ReviewableTarget: Sendable, Equatable, Identifiable {
    public var id: String
    public var category: ReviewableCategory
    public var displayName: String
    public var detail: String
    public var bytes: Int64
    /// Primary path to stage / reveal (largest child path).
    public var primaryPath: String
    public var paths: [String]
    public var nodeIDs: [Int32]
    public var safety: SafetyAssessment
    public var consequence: String
    public var symbolName: String
    public var bundleHint: String?

    public var isGenerallySafe: Bool { safety.level == .safe }
    public var isReviewFirst: Bool { safety.level == .review }
    public var isProtected: Bool { safety.level == .protected }
}

public struct ReviewableSummary: Sendable, Equatable {
    public var totalBytes: Int64
    public var cacheBytes: Int64
    public var buildBytes: Int64
    public var packageBytes: Int64
    public var otherBytes: Int64
    public var targetCount: Int
    public var cacheAppCount: Int

    public static let empty = ReviewableSummary(
        totalBytes: 0, cacheBytes: 0, buildBytes: 0, packageBytes: 0, otherBytes: 0,
        targetCount: 0, cacheAppCount: 0
    )
}

public enum ReviewableCatalog {
    public static func build(
        tree: FileTree,
        root: URL,
        totals: [Int64],
        quickWins: [QuickWins.Hit]
    ) -> (targets: [ReviewableTarget], summary: ReviewableSummary) {
        guard totals.count == tree.count else { return ([], .empty) }

        var targets: [ReviewableTarget] = []
        var usedNodes = Set<Int32>()

        // 1) App-grouped caches under Library/Caches (+ DerivedData as Xcode)
        let cacheGroups = groupCaches(tree: tree, root: root, totals: totals)
        for group in cacheGroups {
            usedNodes.formUnion(group.nodeIDs)
            targets.append(group)
        }

        // 2) Quick-win directories not already covered
        for hit in quickWins {
            if usedNodes.contains(hit.id) { continue }
            let i = Int(hit.id)
            guard i < totals.count, tree.isDirectory[i] else { continue }
            let bytes = totals[i]
            guard bytes > 0 else { continue }
            let path = tree.path(of: hit.id, root: root).path
            let name = tree.name(of: hit.id)
            let safety = SafetyClassifier.assess(path: path, name: name, isDirectory: true)
            if safety.level == .protected { continue }
            let category = categorize(name: name, path: path)
            // Skip raw "Caches" folder — already expanded into apps
            if name.lowercased() == "caches" || path.lowercased().hasSuffix("/library/caches") {
                usedNodes.insert(hit.id)
                continue
            }
            if category == .caches, isUnderLibraryCaches(path) {
                // Child already grouped
                continue
            }
            let target = makeTarget(
                id: "qw-\(hit.id)",
                category: category,
                displayName: displayName(for: name, path: path, category: category),
                detail: detail(for: name, path: path, category: category),
                bytes: bytes,
                paths: [path],
                nodeIDs: [hit.id],
                safety: safety,
                consequence: consequence(for: category, name: name, safety: safety),
                symbol: symbol(for: category, name: name),
                bundleHint: nil
            )
            usedNodes.insert(hit.id)
            targets.append(target)
        }

        targets.sort { $0.bytes > $1.bytes }
        let summary = summarize(targets)
        return (targets, summary)
    }

    public static func summarize(_ targets: [ReviewableTarget]) -> ReviewableSummary {
        var cache: Int64 = 0
        var build: Int64 = 0
        var package: Int64 = 0
        var other: Int64 = 0
        var cacheApps = 0
        for t in targets {
            switch t.category {
            case .caches:
                cache += t.bytes
                cacheApps += 1
            case .buildArtifacts: build += t.bytes
            case .packageCaches: package += t.bytes
            case .other: other += t.bytes
            }
        }
        return ReviewableSummary(
            totalBytes: cache + build + package + other,
            cacheBytes: cache,
            buildBytes: build,
            packageBytes: package,
            otherBytes: other,
            targetCount: targets.count,
            cacheAppCount: cacheApps
        )
    }

    // MARK: - Cache grouping

    private struct Acc {
        var bytes: Int64 = 0
        var paths: [String] = []
        var nodeIDs: [Int32] = []
        var detail: String
        var safety: SafetyAssessment
        var symbol: String
        var bundleHint: String?
        var consequence: String
    }

    private static func groupCaches(
        tree: FileTree,
        root: URL,
        totals: [Int64]
    ) -> [ReviewableTarget] {
        var byApp: [String: Acc] = [:]

        // Library/Caches children (and one level under vendor folders like Google/)
        let vendorContainers: Set<String> = ["google", "adobe", "microsoft", "docker", "mozilla"]
        for id in cacheRootIDs(tree: tree, root: root) {
            var child = tree.firstChild[Int(id)]
            while child != -1 {
                let ci = Int(child)
                if tree.isDirectory[ci] {
                    let name = tree.name(of: child)
                    if vendorContainers.contains(name.lowercased()) {
                        var grand = tree.firstChild[ci]
                        while grand != -1 {
                            let gi = Int(grand)
                            if tree.isDirectory[gi], totals[gi] > 0 {
                                absorbCacheChild(
                                    id: grand,
                                    tree: tree,
                                    root: root,
                                    totals: totals,
                                    into: &byApp
                                )
                            }
                            grand = tree.nextSibling[gi]
                        }
                    } else if totals[ci] > 0 {
                        absorbCacheChild(
                            id: child,
                            tree: tree,
                            root: root,
                            totals: totals,
                            into: &byApp
                        )
                    }
                }
                child = tree.nextSibling[ci]
            }
        }

        // DerivedData
        for id in findNamedDirectories(tree: tree, root: root, names: ["DerivedData"], pathContains: "/developer/xcode/deriveddata") {
            let i = Int(id)
            let bytes = totals[i]
            guard bytes > 0 else { continue }
            let path = tree.path(of: id, root: root).path
            var acc = byApp["Xcode"] ?? Acc(
                detail: "Derived data, build cache",
                safety: SafetyClassifier.assess(path: path, name: "DerivedData", isDirectory: true),
                symbol: "chevron.left.forwardslash.chevron.right",
                bundleHint: "com.apple.dt.Xcode",
                consequence: "Xcode can recreate this. The next build or index may take longer."
            )
            acc.bytes += bytes
            acc.paths.append(path)
            acc.nodeIDs.append(id)
            if acc.detail == "Application cache" { acc.detail = "Derived data, build cache" }
            byApp["Xcode"] = acc
        }

        return byApp.map { app, acc in
            makeTarget(
                id: "cache-\(app)",
                category: .caches,
                displayName: app,
                detail: acc.detail,
                bytes: acc.bytes,
                paths: acc.paths.sorted(),
                nodeIDs: acc.nodeIDs,
                safety: acc.safety.level == .protected
                    ? SafetyAssessment(level: .review, reason: acc.safety.reason, title: app)
                    : acc.safety,
                consequence: acc.consequence,
                symbol: acc.symbol,
                bundleHint: acc.bundleHint
            )
        }.sorted { $0.bytes > $1.bytes }
    }


    private static func absorbCacheChild(
        id: Int32,
        tree: FileTree,
        root: URL,
        totals: [Int64],
        into byApp: inout [String: Acc]
    ) {
        let path = tree.path(of: id, root: root).path
        let name = tree.name(of: id)
        let bytes = totals[Int(id)]
        guard bytes > 0 else { return }
        let mapped = mapCacheFolder(name: name, path: path)
        var acc = byApp[mapped.app] ?? Acc(
            detail: mapped.detail,
            safety: SafetyClassifier.assess(path: path, name: name, isDirectory: true),
            symbol: mapped.symbol,
            bundleHint: mapped.bundleHint,
            consequence: mapped.consequence
        )
        acc.bytes += bytes
        acc.paths.append(path)
        acc.nodeIDs.append(id)
        let childSafety = SafetyClassifier.assess(path: path, name: name, isDirectory: true)
        if acc.safety.level == .safe, childSafety.level == .review {
            acc.safety = childSafety
        }
        byApp[mapped.app] = acc
    }

    private static func cacheRootIDs(tree: FileTree, root: URL) -> [Int32] {
        var roots: [Int32] = []
        for id in 0..<Int32(tree.count) {
            guard tree.isDirectory[Int(id)] else { continue }
            let name = tree.name(of: id)
            guard name == "Caches" else { continue }
            let path = tree.path(of: id, root: root).path.lowercased()
            if path.contains("/library/caches") {
                roots.append(id)
            }
        }
        return roots
    }

    private static func findNamedDirectories(
        tree: FileTree,
        root: URL,
        names: Set<String>,
        pathContains: String
    ) -> [Int32] {
        var out: [Int32] = []
        for id in 0..<Int32(tree.count) {
            guard tree.isDirectory[Int(id)] else { continue }
            let name = tree.name(of: id)
            guard names.contains(name) else { continue }
            let path = tree.path(of: id, root: root).path.lowercased()
            if path.contains(pathContains) {
                out.append(id)
            }
        }
        return out
    }

    private struct Mapped {
        var app: String
        var detail: String
        var symbol: String
        var bundleHint: String?
        var consequence: String
    }

    private static func mapCacheFolder(name: String, path: String) -> Mapped {
        let lower = name.lowercased()
        let pathLower = path.lowercased()

        func m(_ app: String, _ detail: String, _ symbol: String, _ bundle: String?, _ consequence: String) -> Mapped {
            Mapped(app: app, detail: detail, symbol: symbol, bundleHint: bundle, consequence: consequence)
        }

        if lower.contains("chrome") || lower.hasPrefix("com.google.chrome") || pathLower.contains("/google/chrome") {
            return m("Chrome", "Browser cache", "globe", "com.google.Chrome",
                     "Chrome can recreate this. Some sites may load more slowly next time.")
        }
        if lower.contains("chromium") { return m("Chromium", "Browser cache", "globe", nil, "Browser can recreate this cache.") }
        if lower.contains("firefox") || lower.hasPrefix("org.mozilla") {
            return m("Firefox", "Browser cache", "globe", "org.mozilla.firefox", "Firefox can recreate this cache.")
        }
        if lower.contains("safari") || lower.hasPrefix("com.apple.safari") {
            return m("Safari", "Browser cache", "safari", "com.apple.Safari", "Safari can recreate this cache.")
        }
        if lower.contains("spotify") || lower.hasPrefix("com.spotify") {
            return m("Spotify", "Cached media", "music.note", "com.spotify.client",
                     "Some songs or podcasts may need to be downloaded again.")
        }
        if lower.contains("adobe") || lower.hasPrefix("com.adobe") {
            return m("Adobe", "Application cache", "paintbrush.pointed", nil,
                     "Adobe apps can recreate cache data. First launch afterward may be slower.")
        }
        if lower.contains("vscode") || lower.contains("code.helper") || lower.hasPrefix("com.microsoft.vscode") {
            return m("VS Code", "Extension / application cache", "chevron.left.forwardslash.chevron.right",
                     "com.microsoft.VSCode", "VS Code can recreate extension and app caches.")
        }
        if lower.contains("slack") || lower.hasPrefix("com.tinyspeck") {
            return m("Slack", "Application cache", "bubble.left.and.bubble.right", "com.tinyspeck.slackmacgap",
                     "Slack can recreate this. Recent media may re-download.")
        }
        if lower.contains("discord") { return m("Discord", "Application cache", "bubble.left", nil, "Discord can recreate this cache.") }
        if lower.contains("zoom") || lower.hasPrefix("us.zoom") {
            return m("Zoom", "Application cache", "video", "us.zoom.xos", "Zoom can recreate this cache.")
        }
        if lower.hasPrefix("com.apple.dt") || lower.contains("xcode") || lower.contains("ibtool") {
            return m("Xcode", "Xcode cache", "chevron.left.forwardslash.chevron.right", "com.apple.dt.Xcode",
                     "Xcode can recreate this. Builds may be slower until caches refill.")
        }
        if lower.contains("docker") { return m("Docker", "Docker cache", "shippingbox", "com.docker.docker",
                                               "Prefer Docker’s own cleanup for images/volumes when possible.") }
        if lower.contains("figma") { return m("Figma", "Application cache", "paintpalette", nil, "Figma can recreate this cache.") }
        if lower.contains("notion") { return m("Notion", "Application cache", "doc.text", nil, "Notion can recreate this cache.") }
        if lower.contains("telegram") { return m("Telegram", "Application cache", "paperplane", nil, "Some media may re-download.") }
        if lower.contains("homebrew") || lower == "caches" && pathLower.contains("homebrew") {
            return m("Homebrew", "Package download cache", "shippingbox", nil, "Homebrew can re-download bottles as needed.")
        }

        // Bundle-id style: com.company.app → Company App-ish
        if lower.hasPrefix("com.") || lower.hasPrefix("org.") || lower.hasPrefix("net.") {
            let parts = name.split(separator: ".")
            let last = parts.last.map(String.init) ?? name
            let pretty = last.replacingOccurrences(of: "-", with: " ").capitalized
            return m(pretty, "Application cache", "internaldrive", name,
                     "The app can usually recreate this data. First launch afterward may be slower.")
        }

        return m(name, "Application cache", "internaldrive", nil,
                 "Apps can usually recreate this. You may see slower first runs or re-downloads.")
    }

    // MARK: - Helpers

    private static func categorize(name: String, path: String) -> ReviewableCategory {
        let n = name.lowercased()
        let p = path.lowercased()
        if n == "caches" || p.contains("/library/caches") || n == "deriveddata" { return .caches }
        if n == "node_modules" || n == "build" || n == "dist" || n == "target" || n == ".next" || n == ".venv" || n == "venv" {
            return .buildArtifacts
        }
        if n == ".npm" || n == ".pnpm-store" || n == ".cargo" || n == ".gradle" || n == ".pub-cache" || p.contains("/.cargo/registry") {
            return .packageCaches
        }
        return .other
    }

    private static func isUnderLibraryCaches(_ path: String) -> Bool {
        path.lowercased().contains("/library/caches/")
    }

    private static func displayName(for name: String, path: String, category: ReviewableCategory) -> String {
        switch category {
        case .caches: return name
        case .buildArtifacts:
            if name == "node_modules" { return "Node modules" }
            if name == "target" { return "Rust target" }
            if name == "build" { return "Build output" }
            if name == "DerivedData" { return "Xcode DerivedData" }
            return name
        case .packageCaches:
            if name == ".npm" { return "npm cache" }
            if name == ".cargo" { return "Cargo cache" }
            if name == ".gradle" { return "Gradle cache" }
            return name
        case .other: return name
        }
    }

    private static func detail(for name: String, path: String, category: ReviewableCategory) -> String {
        switch category {
        case .caches: return "Application cache"
        case .buildArtifacts:
            if name == "node_modules" { return "Project dependencies" }
            if name == "target" { return "Rust / Cargo build output" }
            return "Generated development output"
        case .packageCaches: return "Downloaded package data"
        case .other: return "Reviewable storage"
        }
    }

    private static func consequence(for category: ReviewableCategory, name: String, safety: SafetyAssessment) -> String {
        if !safety.consequences.isEmpty { return safety.consequences }
        switch category {
        case .caches:
            return "Apps can recreate this. First launch afterward may be slower or re-download data."
        case .buildArtifacts:
            if name == "node_modules" {
                return "Reinstall dependencies (npm/yarn/pnpm install) before the project runs again."
            }
            return "The project may need to rebuild. The next build can take longer."
        case .packageCaches:
            return "Package managers can re-download as needed."
        case .other:
            return "Inspect before clearing. DiskMap cannot guarantee this is unused."
        }
    }

    private static func symbol(for category: ReviewableCategory, name: String) -> String {
        switch category {
        case .caches: return "internaldrive"
        case .buildArtifacts: return "hammer"
        case .packageCaches: return "shippingbox"
        case .other: return "folder"
        }
    }

    private static func makeTarget(
        id: String,
        category: ReviewableCategory,
        displayName: String,
        detail: String,
        bytes: Int64,
        paths: [String],
        nodeIDs: [Int32],
        safety: SafetyAssessment,
        consequence: String,
        symbol: String,
        bundleHint: String?
    ) -> ReviewableTarget {
        ReviewableTarget(
            id: id,
            category: category,
            displayName: displayName,
            detail: detail,
            bytes: bytes,
            primaryPath: paths.first ?? "",
            paths: paths,
            nodeIDs: nodeIDs,
            safety: safety,
            consequence: consequence,
            symbolName: symbol,
            bundleHint: bundleHint
        )
    }
}
