import Foundation

/// High-level storage category for Overview / Home.
public struct StorageCategory: Sendable, Equatable, Identifiable {
    public var id: String { key }
    public var key: String
    public var title: String
    public var bytes: Int64
    public var colorHint: String // semantic: library, downloads, developer, caches, apps, documents, filetype, other
    public var nodeID: Int32? // primary folder when known
    /// File-type categories carry their colour from file-type-categories.json.
    public var colorHex: String?
    /// The file-type id (`kind:` in Find) for a file-type category.
    public var fileKind: String?

    public init(key: String, title: String, bytes: Int64, colorHint: String, nodeID: Int32? = nil,
                colorHex: String? = nil, fileKind: String? = nil) {
        self.key = key
        self.title = title
        self.bytes = bytes
        self.colorHint = colorHint
        self.nodeID = nodeID
        self.colorHex = colorHex
        self.fileKind = fileKind
    }
}

/// How Overview splits a scan into categories (TASK-076). Folder names only
/// mean something at the top of a home folder or a disk; anywhere else the
/// root's children are arbitrary, so the split is by file type instead.
public enum CategoryMode: String, Sendable, Equatable {
    /// A home folder: Library, Downloads, Documents… by name.
    case home
    /// `/` (or the Data volume): the same name mapping, which knows System,
    /// Users and Applications.
    case wholeDisk
    /// Any other folder or an external drive: totals by file type.
    case folder

    /// Home when the root is the user's home or looks like one (at least
    /// two of Library, Downloads, Documents, Desktop as children).
    public static func detect(tree: FileTree, root: URL, home: String = NSHomeDirectory()) -> CategoryMode {
        let path = root.standardizedFileURL.path
        if path == "/" || path == "/System/Volumes/Data" { return .wholeDisk }
        if path == URL(fileURLWithPath: home).standardizedFileURL.path { return .home }
        guard tree.count > 0 else { return .folder }
        let homeNames: Set<String> = ["library", "downloads", "documents", "desktop"]
        var matches = 0
        var child = tree.firstChild[0]
        while child != -1 {
            if tree.isDirectory[Int(child)], homeNames.contains(tree.name(of: child).lowercased()) { matches += 1 }
            child = tree.nextSibling[Int(child)]
        }
        return matches >= 2 ? .home : .folder
    }
}

public struct StorageFileHit: Sendable, Equatable, Identifiable {
    public var id: Int32 { nodeID }
    public var nodeID: Int32
    public var name: String
    public var bytes: Int64
    public var relativePath: String
    public var modifiedDay: Int32

    public init(nodeID: Int32, name: String, bytes: Int64, relativePath: String, modifiedDay: Int32) {
        self.nodeID = nodeID
        self.name = name
        self.bytes = bytes
        self.relativePath = relativePath
        self.modifiedDay = modifiedDay
    }
}

public enum StorageHealth: String, Sendable, Equatable {
    case healthy
    case tight
    case low
    case critical

    public var title: String {
        switch self {
        case .healthy: return "Healthy"
        case .tight: return "Getting full"
        case .low: return "Low on space"
        case .critical: return "Critically full"
        }
    }
}

/// Canonical post-scan summary consumed by Overview and inspectors.
public struct AnalysisSnapshot: Sendable, Equatable {
    public var scanRootPath: String
    public var volume: VolumeStats?
    public var scannedBytes: Int64
    public var categories: [StorageCategory]
    /// How `categories` were made — the UI titles and routes rows by it.
    public var categoryMode: CategoryMode = .home
    public var topFiles: [StorageFileHit]
    public var topFolders: [StorageFileHit]
    public var reviewableBytes: Int64
    public var forgottenBytes: Int64
    public var quickWinBytes: Int64
    public var health: StorageHealth
    public var fileCount: Int
    public var folderCount: Int
    /// Root total on the ALLOCATED basis whatever `scannedBytes` shows, so it
    /// can be compared with `VolumeStats.usedBytes` (statfs is on-disk too).
    public var scannedOnDiskBytes: Int64 = 0
    /// Whether the scan read APFS clone facts, and what counting each clone
    /// family once removed (TASK-077).
    public var hasSharingInfo = false
    public var sharingCorrection: FileTree.SharingCorrection = .none

    /// Volume "used" versus what this scan accounts for (TASK-040).
    public struct VolumeReconciliation: Sendable, Equatable {
        public var usedBytes: Int64
        public var scannedBytes: Int64
        /// In use on the volume but not in this scan. 0 when the scan exceeds
        /// used space (see `scannedExceedsUsed`) — never negative.
        public var unaccountedBytes: Int64
        /// Pure APFS clones occupy one set of blocks but appear once per copy
        /// in a tree walk, so a scan can exceed what the volume reports used.
        public var scannedExceedsUsed: Bool
        public var coverageFraction: Double
    }

    /// Nil when there is no volume to compare against. Invariant from
    /// `categorize`: the gap is reported as its own figure and never folded
    /// into a category — nothing here inflates "Other" to fill the volume.
    public var reconciliation: VolumeReconciliation? {
        guard let volume, volume.usedBytes > 0 else { return nil }
        let used = Int64(clamping: volume.usedBytes)
        let scanned = max(0, scannedOnDiskBytes)
        return VolumeReconciliation(
            usedBytes: used,
            scannedBytes: scanned,
            unaccountedBytes: max(0, used - scanned),
            scannedExceedsUsed: scanned > used,
            coverageFraction: min(1, Double(scanned) / Double(used))
        )
    }

    public static let empty = AnalysisSnapshot(
        scanRootPath: "",
        volume: nil,
        scannedBytes: 0,
        categories: [],
        topFiles: [],
        topFolders: [],
        reviewableBytes: 0,
        forgottenBytes: 0,
        quickWinBytes: 0,
        health: .healthy,
        fileCount: 0,
        folderCount: 0
    )

    public static func build(
        tree: FileTree,
        root: URL,
        allocated: [Int64],
        logical: [Int64],
        basis: SizeBasis = .allocated,
        quickWins: [QuickWins.Hit] = [],
        fileTypes: [FileTypeTotals]? = nil,
        today: Int32 = AgeMap.today()
    ) -> AnalysisSnapshot {
        let totals = basis == .logical ? logical : allocated
        guard tree.count > 0, totals.count == tree.count else {
            return .empty
        }
        let volume = VolumeStats.forPath(root.path, includePurgeable: true)
        let scanned = totals[0]
        let mode = CategoryMode.detect(tree: tree, root: root)
        let cats: [StorageCategory]
        if mode == .folder {
            // Callers usually computed these already (ScanModel caches them);
            // they must be on the same basis as `totals`.
            let types = fileTypes ?? FileTypeCatalog.totals(in: tree, sizes: totals, categories: FileTypeCatalog.loadBundled())
            cats = categorizeByType(types, scanned: scanned)
        } else {
            cats = categorize(tree: tree, root: root, totals: totals)
        }
        let topFiles = topFileHits(tree: tree, root: root, totals: totals, limit: 12)
        let topFolders = topFolderHits(tree: tree, root: root, totals: totals, limit: 12)
        let forgottenCandidates = ForgottenFiles.candidates(
            tree: tree,
            root: root,
            totals: totals,
            today: today,
            limit: 200
        )
        let forgottenBytes = ForgottenFiles.summary(from: forgottenCandidates).reviewableBytes
        let qwBytes = quickWins.reduce(Int64(0)) { partial, hit in
            let i = Int(hit.id)
            return partial + (i < totals.count ? totals[i] : 0)
        }
        // Conservative: caches/quick-wins + half of forgotten (not "guaranteed reclaim").
        let reviewable = qwBytes + forgottenBytes / 2
        let health = health(for: volume)
        var files = 0
        var folders = 0
        for i in 0..<tree.count {
            if tree.isDirectory[i] { folders += 1 } else { files += 1 }
        }
        return AnalysisSnapshot(
            scanRootPath: root.path,
            volume: volume,
            scannedBytes: scanned,
            categories: cats,
            categoryMode: mode,
            topFiles: topFiles,
            topFolders: topFolders,
            reviewableBytes: reviewable,
            forgottenBytes: forgottenBytes,
            quickWinBytes: qwBytes,
            health: health,
            fileCount: files,
            folderCount: folders,
            scannedOnDiskBytes: allocated[0],
            hasSharingInfo: tree.hasSharingInfo,
            sharingCorrection: tree.sharing.isEmpty ? .none : tree.sharingCorrection()
        )
    }

    private static func health(for volume: VolumeStats?) -> StorageHealth {
        guard let volume, volume.totalBytes > 0 else { return .healthy }
        let freeFrac = Double(volume.freeBytes) / Double(volume.totalBytes)
        if freeFrac < 0.05 { return .critical }
        if freeFrac < 0.12 { return .low }
        if freeFrac < 0.20 { return .tight }
        return .healthy
    }

    /// Exclusive partition of **immediate children** of the scan root.
    /// One child contributes to exactly one category. Library peels Caches/Logs
    /// into caches (subtracted from library) so bytes stay exclusive.
    /// Skips empty Data-volume firmlink twin dirs (size 0 after skip-descend).
    private static func categorize(tree: FileTree, root: URL, totals: [Int64]) -> [StorageCategory] {
        var buckets: [String: (title: String, hint: String, bytes: Int64, node: Int32?)] = [
            "applications": ("Applications", "apps", 0, nil),
            "library": ("Library", "library", 0, nil),
            "downloads": ("Downloads", "downloads", 0, nil),
            "documents": ("Personal", "documents", 0, nil),
            "developer": ("Developer", "developer", 0, nil),
            "caches": ("Caches & Logs", "caches", 0, nil),
            "system": ("System", "system", 0, nil),
            "other": ("Other", "other", 0, nil),
        ]

        func add(_ key: String, bytes: Int64, node: Int32) {
            guard bytes > 0, var b = buckets[key] else { return }
            b.bytes += bytes
            if b.node == nil { b.node = node }
            buckets[key] = b
        }

        let children = tree.children(of: 0, totals: totals)
        for entry in children {
            let child = entry.id
            let name = tree.name(of: child)
            let bytes = entry.size
            guard bytes > 0 else { continue }
            let lower = name.lowercased()
            let path = tree.path(of: child, root: root).path

            // Ignore empty firmlink-twin shells under Data if present.
            if CanonicalPath.shouldSkipDescend(absolutePath: path, scanRootPath: root.path) {
                continue
            }

            if lower == "library" {
                var libBytes = bytes
                for gentry in tree.children(of: child, totals: totals) {
                    let gn = tree.name(of: gentry.id).lowercased()
                    if gn == "caches" || gn == "logs" {
                        add("caches", bytes: gentry.size, node: gentry.id)
                        libBytes = max(0, libBytes - gentry.size)
                    } else if gn == "developer" {
                        // Xcode under ~/Library/Developer
                        add("developer", bytes: gentry.size, node: gentry.id)
                        libBytes = max(0, libBytes - gentry.size)
                    }
                }
                add("library", bytes: libBytes, node: child)
            } else if lower == "downloads" {
                add("downloads", bytes: bytes, node: child)
            } else if lower == "documents" || lower == "desktop" || lower == "movies" || lower == "music" || lower == "pictures" {
                add("documents", bytes: bytes, node: child)
            } else if lower == "applications" || lower == "applications (parallels)" {
                add("applications", bytes: bytes, node: child)
            } else if lower.hasPrefix(".") && isDeveloperDot(lower) {
                add("developer", bytes: bytes, node: child)
            } else if lower == "developer" || lower == "dev" {
                add("developer", bytes: bytes, node: child)
            } else if lower == "caches" || lower.hasSuffix(".cache") {
                add("caches", bytes: bytes, node: child)
            } else if lower == "system" || lower == "private" || path.hasPrefix("/System") {
                add("system", bytes: bytes, node: child)
            } else if lower == "users" {
                // Whole-disk scan: attribute Users to personal/other breakdown via its children if shallow;
                // otherwise count as Personal container.
                add("documents", bytes: bytes, node: child)
            } else {
                add("other", bytes: bytes, node: child)
            }
        }

        let order = ["applications", "library", "downloads", "documents", "developer", "caches", "system", "other"]
        let cats = order.compactMap { key -> StorageCategory? in
            guard let b = buckets[key], b.bytes > 0 else { return nil }
            return StorageCategory(key: key, title: b.title, bytes: b.bytes, colorHint: b.hint, nodeID: b.node)
        }
        // Guarantee sum(categories) == sum of positive root children accounted
        // (exclusive by construction). Callers must use sum as bar denominator
        // when comparing to volume used — never inflate Other to fill volume.
        return cats
    }

    /// Folder mode: one category per file type, biggest first, then "Other"
    /// for files no type claims (and evicted folders). Rollups charge folders
    /// and repeated hard-link names nothing, so the rows sum to `scanned`.
    static func categorizeByType(_ types: [FileTypeTotals], scanned: Int64) -> [StorageCategory] {
        var cats = types
            .filter { $0.bytes > 0 }
            .sorted { $0.bytes > $1.bytes }
            .map { StorageCategory(key: "type:\($0.categoryID)", title: $0.label, bytes: $0.bytes,
                                   colorHint: "filetype", colorHex: $0.colorHex, fileKind: $0.categoryID) }
        let typed = cats.reduce(Int64(0)) { $0 + $1.bytes }
        if scanned - typed > 0 {
            cats.append(StorageCategory(key: "other", title: "Other", bytes: scanned - typed, colorHint: "other"))
        }
        return cats
    }

    private static func relativePath(_ url: URL, under root: URL) -> String {
        let full = url.path
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if full.hasPrefix(prefix) { return String(full.dropFirst(prefix.count)) }
        if full == root.path { return root.lastPathComponent }
        return url.lastPathComponent
    }

    private static func isDeveloperDot(_ lower: String) -> Bool {
        [
            ".npm", ".nvm", ".yarn", ".pnpm", ".cache", ".cargo", ".rustup",
            ".gradle", ".cocoapods", ".pub-cache", ".local", ".cursor", ".codex",
            ".docker", ".pyenv", ".conda", ".vscode"
        ].contains(lower)
    }

    private static func topFileHits(tree: FileTree, root: URL, totals: [Int64], limit: Int) -> [StorageFileHit] {
        var ids: [Int32] = []
        for id in 1..<Int32(tree.count) {
            let i = Int(id)
            guard !tree.isDirectory[i], totals[i] > 0 else { continue }
            ids.append(id)
        }
        ids.sort { totals[Int($0)] > totals[Int($1)] }
        if ids.count > limit { ids = Array(ids.prefix(limit)) }
        return ids.map { id in
            let i = Int(id)
            let abs = tree.path(of: id, root: root).path
            return StorageFileHit(
                nodeID: id,
                name: tree.name(of: id),
                bytes: totals[i],
                relativePath: CanonicalPath.displayPath(absolutePath: abs),
                modifiedDay: tree.modifiedDay[i]
            )
        }
    }

    private static func topFolderHits(tree: FileTree, root: URL, totals: [Int64], limit: Int) -> [StorageFileHit] {
        var ids: [Int32] = []
        for id in 1..<Int32(tree.count) {
            let i = Int(id)
            guard tree.isDirectory[i], totals[i] > 0 else { continue }
            ids.append(id)
        }
        ids.sort { totals[Int($0)] > totals[Int($1)] }
        if ids.count > limit { ids = Array(ids.prefix(limit)) }
        return ids.map { id in
            let i = Int(id)
            let abs = tree.path(of: id, root: root).path
            return StorageFileHit(
                nodeID: id,
                name: tree.name(of: id),
                bytes: totals[i],
                relativePath: CanonicalPath.displayPath(absolutePath: abs),
                modifiedDay: tree.modifiedDay[i]
            )
        }
    }
}
