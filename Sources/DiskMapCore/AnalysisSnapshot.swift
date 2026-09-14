import Foundation

/// High-level storage category for Overview / Home.
public struct StorageCategory: Sendable, Equatable, Identifiable {
    public var id: String { key }
    public var key: String
    public var title: String
    public var bytes: Int64
    public var colorHint: String // semantic: library, downloads, developer, caches, apps, documents, other
    public var nodeID: Int32? // primary folder when known

    public init(key: String, title: String, bytes: Int64, colorHint: String, nodeID: Int32? = nil) {
        self.key = key
        self.title = title
        self.bytes = bytes
        self.colorHint = colorHint
        self.nodeID = nodeID
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
    public var topFiles: [StorageFileHit]
    public var topFolders: [StorageFileHit]
    public var reviewableBytes: Int64
    public var forgottenBytes: Int64
    public var quickWinBytes: Int64
    public var health: StorageHealth
    public var fileCount: Int
    public var folderCount: Int

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
        today: Int32 = AgeMap.today()
    ) -> AnalysisSnapshot {
        let totals = basis == .logical ? logical : allocated
        guard tree.count > 0, totals.count == tree.count else {
            return .empty
        }
        let volume = VolumeStats.forPath(root.path)
        let scanned = totals[0]
        let cats = categorize(tree: tree, root: root, totals: totals)
        let topFiles = topFileHits(tree: tree, root: root, totals: totals, limit: 12)
        let topFolders = topFolderHits(tree: tree, root: root, totals: totals, limit: 12)
        let forgotten = AgeMap.untouched(in: tree, totals: totals, today: today, limit: 200)
        let forgottenBytes = forgotten.reduce(Int64(0)) { $0 + totals[Int($1)] }
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
            topFiles: topFiles,
            topFolders: topFolders,
            reviewableBytes: reviewable,
            forgottenBytes: forgottenBytes,
            quickWinBytes: qwBytes,
            health: health,
            fileCount: files,
            folderCount: folders
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

    /// Map immediate children of scan root (and known nested developer/cache paths) into Overview categories.
    private static func categorize(tree: FileTree, root: URL, totals: [Int64]) -> [StorageCategory] {
        var buckets: [String: (title: String, hint: String, bytes: Int64, node: Int32?)] = [
            "library": ("Library", "library", 0, nil),
            "downloads": ("Downloads", "downloads", 0, nil),
            "developer": ("Developer", "developer", 0, nil),
            "caches": ("Caches & Logs", "caches", 0, nil),
            "applications": ("Applications", "apps", 0, nil),
            "documents": ("Documents", "documents", 0, nil),
            "other": ("Other", "other", 0, nil),
        ]

        func add(_ key: String, bytes: Int64, node: Int32) {
            guard var b = buckets[key] else { return }
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
            if lower == "library" {
                add("library", bytes: bytes, node: child)
                // Peel caches from Library when present as direct child.
                for gentry in tree.children(of: child, totals: totals) {
                    let grand = gentry.id
                    let gn = tree.name(of: grand).lowercased()
                    if gn == "caches" || gn == "logs" {
                        let gbytes = gentry.size
                        add("caches", bytes: gbytes, node: grand)
                        // subtract from library display so bar doesn't double-count visually
                        if var lib = buckets["library"] {
                            lib.bytes = max(0, lib.bytes - gbytes)
                            buckets["library"] = lib
                        }
                    }
                }
            } else if lower == "downloads" {
                add("downloads", bytes: bytes, node: child)
            } else if lower == "documents" {
                add("documents", bytes: bytes, node: child)
            } else if lower == "applications" || lower == "applications (parallels)" {
                add("applications", bytes: bytes, node: child)
            } else if lower.hasPrefix(".") && isDeveloperDot(lower) {
                add("developer", bytes: bytes, node: child)
            } else if lower == "developer" || lower == "dev" {
                add("developer", bytes: bytes, node: child)
            } else if lower == "caches" || lower.hasSuffix(".cache") {
                add("caches", bytes: bytes, node: child)
            } else {
                add("other", bytes: bytes, node: child)
            }
        }

        let order = ["library", "downloads", "developer", "caches", "applications", "documents", "other"]
        return order.compactMap { key in
            guard let b = buckets[key], b.bytes > 0 else { return nil }
            return StorageCategory(key: key, title: b.title, bytes: b.bytes, colorHint: b.hint, nodeID: b.node)
        }
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
            return StorageFileHit(
                nodeID: id,
                name: tree.name(of: id),
                bytes: totals[i],
                relativePath: relativePath(tree.path(of: id, root: root), under: root),
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
            return StorageFileHit(
                nodeID: id,
                name: tree.name(of: id),
                bytes: totals[i],
                relativePath: relativePath(tree.path(of: id, root: root), under: root),
                modifiedDay: tree.modifiedDay[i]
            )
        }
    }
}
