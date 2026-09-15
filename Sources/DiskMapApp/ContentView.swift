import SwiftUI
import AppKit
import DiskMapCore

/// Shared so launch-argument scans start from `applicationDidFinishLaunching`
/// (the window may not be on screen yet) and the view still shows live
/// `scannedCount` updates.
@MainActor
final class ScanModel: ObservableObject {
    static let shared = ScanModel()

    @Published var tree: FileTree?
    @Published var allocatedTotals: [Int64] = []
    @Published var logicalTotals: [Int64] = []
    @Published var isScanning = false
    @Published var scannedCount = 0
    @Published var rootURL: URL?
    @Published var duplicateGroups: [DuplicateGroup] = []
    @Published var isFindingDuplicates = false
    @Published var stagedItems: [CleanupQueue.StagedItem] = []
    @Published var reclaimableBytes: Int64 = 0
    @Published var lastCommitLines: [String] = []
    @Published var sizeBasis: SizeBasis = .allocated
    @Published var currentNode: Int32 = 0
    @Published var selectedNode: Int32 = 0
    @Published var recentRoots: [URL] = ScanModel.loadRecentRoots()
    @Published var lastScanSeconds: Double?
    @Published var descendantFileCounts: [Int] = []
    @Published var descendantFolderCounts: [Int] = []
    @Published var cachedQuickWins: [QuickWins.Hit] = []
    @Published var cachedFileTypes: [FileTypeTotals] = []
    @Published var toastMessage: String?
    @Published var exploreMode: ExploreViewMode = .treemap
    @Published var colorMode: ExploreColorMode = .folder
    @Published var depthLevel: Double = 7
    @Published var topNav: TopNavTab = .explore
    @Published var destination: AppDestination = .overview
    @Published var analysis: AnalysisSnapshot = .empty
    /// When set, Biggest Files filters to files under this absolute path prefix.
    @Published var folderFilterPath: String? = nil
    /// Precomputed after scan — Forgotten Files must not re-walk the tree on every click.
    @Published var cachedForgotten: [ForgottenCandidate] = []
    @Published var cachedForgottenSummary: ForgottenSummary = .empty
    @Published var cachedReviewables: [ReviewableTarget] = []
    @Published var cachedReviewableSummary: ReviewableSummary = .empty
    @Published var cachedDeveloper: DeveloperCatalogResult = .empty
    @Published var cachedOldDownloads: OldDownloadsCatalogResult = .empty

    let cleanupQueue = CleanupQueue()
    let fileTypeCategories = FileTypeCatalog.loadBundled()

    var selectedTotals: [Int64] {
        sizeBasis == .logical ? logicalTotals : allocatedTotals
    }

    private var didStartLaunchScan = false
    private let logURL = URL(fileURLWithPath: "/tmp/diskmap-scan.log")

    func startIfRequested() {
        guard !didStartLaunchScan else { return }
        let args = CommandLine.arguments
        log("launch args: \(args.joined(separator: " | "))")
        guard let index = args.firstIndex(of: "--scan"), args.indices.contains(index + 1) else { return }
        didStartLaunchScan = true
        let url = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        Task { await scan(url) }
    }

    func scan(_ url: URL) async {
        rootURL = url
        isScanning = true
        scannedCount = 0
        currentNode = 0
        allocatedTotals = []
        logicalTotals = []
        descendantFileCounts = []
        descendantFolderCounts = []
        cachedQuickWins = []
        cachedFileTypes = []
        duplicateGroups = []
        folderFilterPath = nil
        cachedForgotten = []
        cachedForgottenSummary = .empty
        cachedReviewables = []
        cachedReviewableSummary = .empty
        cachedDeveloper = .empty
        cachedOldDownloads = .empty
        log("scan start \(url.path)")

        let before = ProcessMemory.current()
        log("rss_before_scan=\(before?.residentBytes ?? 0)")

        let engine = ScanEngine()
        let result = await engine.scan(root: url) { count in
            ScanModel.appendLog("scannedCount=\(count)")
            print("scannedCount=\(count)")
            fflush(stdout)
            Task { @MainActor in ScanModel.shared.scannedCount = count }
        }
        // Immediately after scan() returns: tree is retained, the
        // enumerator is not. Do this before rollUpSizes, which allocates
        // another array and would blend into the steady-state number.
        let afterReturn = ProcessMemory.current()
        let footprint = result.tree.storageFootprint()
        let summary = """
        DiskMap rss_before_scan=\(before?.residentBytes ?? 0)
        DiskMap rss_during_walk_peak=\(result.peakResidentBytesDuringWalk)
        DiskMap rss_after_scan_returns=\(afterReturn?.residentBytes ?? 0)
        DiskMap filetree_nodes=\(footprint.nodeCount) unique_names=\(footprint.uniqueNameCount) stride=\(FileTree.packedNodeStride)
        DiskMap filetree_packed_exact=\(footprint.packedNodeBytesExact)
        DiskMap filetree_packed_reserved=\(footprint.packedNodeBytesReserved)
        DiskMap filetree_name_headers=\(footprint.nameTableHeaderBytes)
        DiskMap filetree_name_utf8=\(footprint.nameUTF8Bytes)
        """
        print(summary)
        fflush(stdout)
        log(summary)

        let both = result.tree.rollUpBoth()
        let allocated = both.allocated
        let logical = both.logical
        logNotDownloadedContrast(tree: result.tree, logical: logical, allocated: allocated)
        tree = result.tree
        allocatedTotals = allocated
        logicalTotals = logical
        let counts = result.tree.rollUpDescendantCounts()
        descendantFileCounts = counts.files
        descendantFolderCounts = counts.folders
        let patterns = QuickWins.bundledPatterns()
        cachedQuickWins = QuickWins.find(in: result.tree, root: url, patterns: patterns)
        cachedFileTypes = FileTypeCatalog.totals(
            in: result.tree,
            sizes: allocated,
            categories: fileTypeCategories
        )
        analysis = AnalysisSnapshot.build(
            tree: result.tree,
            root: url,
            allocated: allocated,
            logical: logical,
            basis: sizeBasis,
            quickWins: cachedQuickWins
        )
        let forgotten = ForgottenFiles.candidates(
            tree: result.tree,
            root: url,
            totals: allocated,
            limit: 400
        )
        cachedForgotten = forgotten
        cachedForgottenSummary = ForgottenFiles.summary(from: forgotten)
        let reviewable = ReviewableCatalog.build(
            tree: result.tree,
            root: url,
            totals: allocated,
            quickWins: cachedQuickWins
        )
        cachedReviewables = reviewable.targets
        cachedReviewableSummary = reviewable.summary
        cachedDeveloper = DeveloperCatalog.build(
            tree: result.tree,
            root: url,
            totals: allocated
        )
        cachedOldDownloads = OldDownloadsCatalog.build(
            tree: result.tree,
            root: url,
            totals: allocated
        )
        selectedNode = 0
        currentNode = 0
        lastScanSeconds = result.elapsedSeconds
        rememberRecent(url)
        isScanning = false
        log("scan finished items=\(result.itemCount)")
    }

    func isStaged(_ url: URL) -> Bool {
        stagedItems.contains { $0.url.standardizedFileURL == url.standardizedFileURL }
    }

    func showToast(_ message: String) {
        toastMessage = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if toastMessage == message { toastMessage = nil }
        }
    }

    private func rememberRecent(_ url: URL) {
        var next = recentRoots.filter { $0.standardizedFileURL != url.standardizedFileURL }
        next.insert(url, at: 0)
        if next.count > 8 { next = Array(next.prefix(8)) }
        recentRoots = next
        Self.saveRecentRoots(next)
    }

    private static let recentKey = "diskmap.recentRoots"

    static func loadRecentRoots() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func saveRecentRoots(_ urls: [URL]) {
        UserDefaults.standard.set(urls.map(\.path), forKey: recentKey)
    }

    func findDuplicates() async {
        guard let tree, let rootURL else { return }
        isFindingDuplicates = true
        let files = DuplicateFinder.candidates(in: tree, root: rootURL)
        duplicateGroups = await DuplicateFinder.findDuplicates(candidates: files)
        isFindingDuplicates = false
    }

    func rebuildAnalysis() {
        guard let tree, let rootURL,
              allocatedTotals.count == tree.count,
              logicalTotals.count == tree.count else {
            analysis = .empty
            return
        }
        analysis = AnalysisSnapshot.build(
            tree: tree,
            root: rootURL,
            allocated: allocatedTotals,
            logical: logicalTotals,
            basis: sizeBasis,
            quickWins: cachedQuickWins
        )
    }

    func refreshReviewableCache() {
        guard let tree, let rootURL, selectedTotals.count == tree.count else {
            cachedReviewables = []
            cachedReviewableSummary = .empty
            return
        }
        let built = ReviewableCatalog.build(
            tree: tree,
            root: rootURL,
            totals: selectedTotals,
            quickWins: cachedQuickWins
        )
        cachedReviewables = built.targets
        cachedReviewableSummary = built.summary
    }

    func refreshOldDownloadsCache() {
        guard let tree, let rootURL, selectedTotals.count == tree.count else {
            cachedOldDownloads = .empty
            return
        }
        cachedOldDownloads = OldDownloadsCatalog.build(
            tree: tree,
            root: rootURL,
            totals: selectedTotals
        )
    }

    func refreshDeveloperCache() {
        guard let tree, let rootURL, selectedTotals.count == tree.count else {
            cachedDeveloper = .empty
        cachedOldDownloads = .empty
            return
        }
        cachedDeveloper = DeveloperCatalog.build(
            tree: tree,
            root: rootURL,
            totals: selectedTotals
        )
    }

    func refreshForgottenCache() {
        guard let tree, let rootURL, selectedTotals.count == tree.count else {
            cachedForgotten = []
            cachedForgottenSummary = .empty
            return
        }
        let forgotten = ForgottenFiles.candidates(
            tree: tree,
            root: rootURL,
            totals: selectedTotals,
            limit: 400
        )
        cachedForgotten = forgotten
        cachedForgottenSummary = ForgottenFiles.summary(from: forgotten)
    }

    func refreshQueue() async {
        stagedItems = await cleanupQueue.allItems()
        reclaimableBytes = await cleanupQueue.totalSize()
    }

    func commitCleanup() async {
        let results = await cleanupQueue.commit()
        let log = CleanupPreflight.logEntries(from: results)
        lastCommitLines = log.map { entry in
            if entry.succeeded {
                return "Trashed \(entry.path) (\(ByteFormat.string(entry.bytes))) — \(entry.reason)"
            }
            return "Failed \(entry.path): \(entry.errorDescription ?? "unknown error")"
        }
        if lastCommitLines.isEmpty {
            lastCommitLines = ["Nothing moved."]
        }
        await refreshQueue()
    }

    /// Confirms the size toggle against evicted iCloud nodes: a file's
    /// logical total is its cloud size, its allocated total is the local
    /// footprint. Paths are not logged.
    private func logNotDownloadedContrast(tree: FileTree, logical: [Int64], allocated: [Int64]) {
        var files = 0
        var directories = 0
        var cloudOnly = 0
        var partial = 0
        var emptyLogical = 0
        var cloudOnlyLogicalTotal: Int64 = 0
        var example: String?
        var partialExample: String?
        for id in 0..<tree.count {
            guard tree.flags[id] & NodeFlags.notDownloaded != 0 else { continue }
            if tree.isDirectory[id] {
                directories += 1
                continue
            }
            files += 1
            if logical[id] == 0 {
                emptyLogical += 1
                if emptyLogical == 1 {
                    log("not_downloaded_empty_logical allocated=\(allocated[id])")
                }
            } else if allocated[id] == 0 {
                cloudOnly += 1
                cloudOnlyLogicalTotal += logical[id]
                if example == nil {
                    let parent = tree.parent[id]
                    let parentLogical = parent >= 0 ? logical[Int(parent)] : -1
                    let parentAllocated = parent >= 0 ? allocated[Int(parent)] : -1
                    example = "not_downloaded_example logical=\(logical[id]) allocated=\(allocated[id]) parent_logical=\(parentLogical) parent_allocated=\(parentAllocated)"
                }
            } else {
                partial += 1
                if partialExample == nil {
                    partialExample = "not_downloaded_partial logical=\(logical[id]) allocated=\(allocated[id])"
                }
            }
        }
        log("not_downloaded_files=\(files) not_downloaded_dirs=\(directories) files_logical_positive_allocated_zero=\(cloudOnly) files_partial=\(partial) files_logical_zero=\(emptyLogical) cloud_only_logical_total=\(cloudOnlyLogicalTotal)")
        if let example { log(example) }
        if let partialExample { log(partialExample) }
    }

    private func log(_ line: String) {
        Self.appendLog(line)
    }

    nonisolated static func appendLog(_ line: String) {
        let url = URL(fileURLWithPath: "/tmp/diskmap-scan.log")
        let data = Data((line + "\n").utf8)
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

enum TopNavTab: String, CaseIterable, Identifiable {
    case explore = "Explore"
    case duplicates = "Duplicates"
    case applications = "Applications"
    case monitor = "Monitor"
    case snapshots = "Snapshots"
    var id: String { rawValue }
}

enum ExploreViewMode: String, CaseIterable, Identifiable {
    case treemap = "Treemap"
    case sunburst = "Sunburst"
    case flame = "Flame"
    case bubbles = "Bubbles"
    case mindMap = "Mind Map"
    case topSizes = "Top Sizes"
    case ageMap = "Age Map"
    case folders = "Folders"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .treemap: return "square.grid.3x3.fill"
        case .sunburst: return "sun.max"
        case .flame: return "chart.bar.xaxis"
        case .bubbles: return "circle.grid.2x2"
        case .mindMap: return "point.3.connected.trianglepath.dotted"
        case .topSizes: return "list.number"
        case .ageMap: return "calendar"
        case .folders: return "folder"
        }
    }

    var blurb: String {
        switch self {
        case .treemap: return "See what's taking space"
        case .sunburst: return "See how it's nested"
        case .flame: return "Trace folder depth"
        case .bubbles: return "Compare visually"
        case .folders: return "Browse folder by folder"
        case .ageMap: return "Find old data"
        case .topSizes: return "The biggest items, ranked"
        case .mindMap: return "Explore structure"
        }
    }

    var showsLayoutControls: Bool {
        switch self {
        case .treemap, .sunburst, .flame, .bubbles, .mindMap: return true
        default: return false
        }
    }

    /// Modes shown in the Visualize workspace picker (not File Browser / Find lists).
    static var visualizeModes: [ExploreViewMode] {
        [.treemap, .sunburst, .flame, .bubbles, .mindMap, .ageMap]
    }
}

enum ExploreColorMode: String, CaseIterable, Identifiable {
    case type = "By type"
    case folder = "By folder"
    case age = "By age"
    var id: String { rawValue }
}

struct ContentView: View {
    @ObservedObject private var model = ScanModel.shared

    var body: some View {
        AppShellView(model: model)
            .onChange(of: model.sizeBasis) { _, _ in
                model.rebuildAnalysis()
                model.refreshForgottenCache()
                model.refreshReviewableCache()
            }
    }
}
