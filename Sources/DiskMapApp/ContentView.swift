import SwiftUI
import AppKit
import DiskMapCore

private struct PreparedScan: Sendable {
    var allocated: [Int64]
    var logical: [Int64]
    var fileCounts: [Int]
    var folderCounts: [Int]
    var quickWins: [QuickWins.Hit]
    var fileTypes: [FileTypeTotals]
    var analysis: AnalysisSnapshot
    var forgotten: [ForgottenCandidate]
    var forgottenSummary: ForgottenSummary
    var reviewables: [ReviewableTarget]
    var reviewableSummary: ReviewableSummary
    var developer: DeveloperCatalogResult
    var oldDownloads: OldDownloadsCatalogResult
    var largeMedia: MediaCatalogResult
}

struct CleanupStageRequest: Sendable {
    var url: URL
    var size: Int64
    var reason: String
    var sharesStorageGroup: String? = nil
    var groupCopyCount: Int = 1
}

struct CleanupStageSummary: Sendable {
    var added = 0
    var alreadyPresent = 0
    var rejected = 0
    var wasBusy = false
    var addedURLs: [URL] = []
    var rejectedURLs: [URL] = []
}

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
    @Published var pendingRootURL: URL?
    @Published var duplicateGroups: [DuplicateGroup] = []
    @Published var isFindingDuplicates = false
    @Published var duplicatePhase: DuplicateScanPhase = .idle
    @Published var duplicateProgressDone = 0
    @Published var duplicateProgressTotal = 0
    @Published var duplicateFilesExamined = 0
    @Published var duplicateCandidateCount = 0
    @Published var duplicateStartedAt: Date?
    @Published var duplicateLastProgressAt: Date?
    @Published var duplicateError: String?
    @Published var duplicateDidRun = false
    private var duplicateTask: Task<Void, Never>?
    private var duplicateOperationID: UUID?
    @Published var stagedItems: [CleanupQueue.StagedItem] = []
    @Published var reclaimableBytes: Int64 = 0
    @Published var isStagingCleanup = false
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
    @Published var cachedLargeMedia: MediaCatalogResult = .empty

    let cleanupQueue = CleanupQueue()
    let fileTypeCategories = FileTypeCatalog.loadBundled()

    var selectedTotals: [Int64] {
        sizeBasis == .logical ? logicalTotals : allocatedTotals
    }

    private var didStartLaunchScan = false
    private let logURL = URL(fileURLWithPath: "/tmp/diskmap-scan.log")
    /// Bumped on cancel / new scan so a finished walk can discard stale results.
    private var scanGeneration = 0

    func startIfRequested() {
        guard !didStartLaunchScan else { return }
        let args = CommandLine.arguments
        log("launch args: \(args.joined(separator: " | "))")
        guard let index = args.firstIndex(of: "--scan"), args.indices.contains(index + 1) else { return }
        didStartLaunchScan = true
        let url = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        Task { await scan(url) }
    }

    func cancelScan() {
        scanGeneration += 1
        isScanning = false
        pendingRootURL = nil
        if tree == nil {
            rootURL = nil
            scannedCount = 0
        }
        log("scan cancelled")
    }

    func scan(_ url: URL) async {
        scanGeneration += 1
        let generation = scanGeneration
        let hasCommittedScan = tree != nil
        pendingRootURL = url
        if !hasCommittedScan { rootURL = url }
        isScanning = true
        scannedCount = 0
        cancelDuplicateSearch()
        if !hasCommittedScan {
            currentNode = 0
            allocatedTotals = []
            logicalTotals = []
            descendantFileCounts = []
            descendantFolderCounts = []
            cachedQuickWins = []
            cachedFileTypes = []
            folderFilterPath = nil
            cachedForgotten = []
            cachedForgottenSummary = .empty
            cachedReviewables = []
            cachedReviewableSummary = .empty
            cachedDeveloper = .empty
            cachedOldDownloads = .empty
            cachedLargeMedia = .empty
        }
        log("scan start \(url.path)")

        let before = ProcessMemory.current()
        log("rss_before_scan=\(before?.residentBytes ?? 0)")

        let engine = ScanEngine()
        let result = await engine.scan(root: url) { count in
            ScanModel.appendLog("scannedCount=\(count)")
            print("scannedCount=\(count)")
            fflush(stdout)
            Task { @MainActor in
                guard ScanModel.shared.scanGeneration == generation else { return }
                ScanModel.shared.scannedCount = count
            }
        }
        guard generation == scanGeneration else {
            log("scan discarded (cancelled) path=\(url.path)")
            return
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

        let scannedTree = result.tree
        let categories = fileTypeCategories
        let basis = sizeBasis
        let prepared = await Task.detached(priority: .userInitiated) {
            let both = scannedTree.rollUpBoth()
            let counts = scannedTree.rollUpDescendantCounts()
            let quickWins = QuickWins.find(in: scannedTree, root: url, patterns: QuickWins.bundledPatterns())
            let fileTypes = FileTypeCatalog.totals(in: scannedTree, sizes: both.allocated, categories: categories)
            let analysis = AnalysisSnapshot.build(
                tree: scannedTree, root: url, allocated: both.allocated, logical: both.logical,
                basis: basis, quickWins: quickWins
            )
            let forgotten = ForgottenFiles.candidates(tree: scannedTree, root: url, totals: both.allocated, limit: 400)
            let reviewable = ReviewableCatalog.build(tree: scannedTree, root: url, totals: both.allocated, quickWins: quickWins)
            return PreparedScan(
                allocated: both.allocated, logical: both.logical,
                fileCounts: counts.files, folderCounts: counts.folders,
                quickWins: quickWins, fileTypes: fileTypes, analysis: analysis,
                forgotten: forgotten, forgottenSummary: ForgottenFiles.summary(from: forgotten),
                reviewables: reviewable.targets, reviewableSummary: reviewable.summary,
                developer: DeveloperCatalog.build(tree: scannedTree, root: url, totals: both.allocated),
                oldDownloads: OldDownloadsCatalog.build(tree: scannedTree, root: url, totals: both.allocated),
                largeMedia: MediaCatalog.build(tree: scannedTree, root: url, totals: both.allocated)
            )
        }.value
        guard generation == scanGeneration else {
            log("prepared scan discarded (cancelled) path=\(url.path)")
            return
        }
        logNotDownloadedContrast(tree: scannedTree, logical: prepared.logical, allocated: prepared.allocated)
        tree = scannedTree
        rootURL = url
        allocatedTotals = prepared.allocated
        logicalTotals = prepared.logical
        descendantFileCounts = prepared.fileCounts
        descendantFolderCounts = prepared.folderCounts
        cachedQuickWins = prepared.quickWins
        cachedFileTypes = prepared.fileTypes
        analysis = prepared.analysis
        cachedForgotten = prepared.forgotten
        cachedForgottenSummary = prepared.forgottenSummary
        cachedReviewables = prepared.reviewables
        cachedReviewableSummary = prepared.reviewableSummary
        cachedDeveloper = prepared.developer
        cachedOldDownloads = prepared.oldDownloads
        cachedLargeMedia = prepared.largeMedia
        duplicateGroups = []
        duplicatePhase = .idle
        duplicateProgressDone = 0
        duplicateProgressTotal = 0
        duplicateError = nil
        duplicateDidRun = false
        folderFilterPath = nil
        selectedNode = 0
        currentNode = 0
        lastScanSeconds = result.elapsedSeconds
        rememberRecent(url)
        pendingRootURL = nil
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
        guard tree != nil, rootURL != nil else { return }
        cancelDuplicateSearch()
        let operationID = UUID()
        duplicateOperationID = operationID
        duplicateError = nil
        duplicateDidRun = false
        isFindingDuplicates = true
        duplicatePhase = .preparing
        duplicateProgressDone = 0
        duplicateProgressTotal = 0
        duplicateFilesExamined = 0
        duplicateCandidateCount = 0
        duplicateStartedAt = Date()
        duplicateLastProgressAt = Date()

        let task = Task { @MainActor in
            guard let tree = self.tree, let rootURL = self.rootURL else {
                self.isFindingDuplicates = false
                self.duplicatePhase = .idle
                return
            }
            do {
                self.duplicatePhase = .collecting
                let files = try await DuplicateFinder.candidatesAsync(in: tree, root: rootURL) { examined, candidates in
                    Task { @MainActor in
                        guard self.duplicateOperationID == operationID else { return }
                        self.duplicateFilesExamined = examined
                        self.duplicateCandidateCount = candidates
                        self.duplicateLastProgressAt = Date()
                    }
                }
                try Task.checkCancellation()
                guard self.duplicateOperationID == operationID else { return }
                self.duplicatePhase = .grouping
                let groups = try await DuplicateFinder.findDuplicates(candidates: files) { phase, done, total in
                    Task { @MainActor in
                        guard self.duplicateOperationID == operationID else { return }
                        self.duplicatePhase = phase
                        self.duplicateProgressDone = done
                        self.duplicateProgressTotal = total
                        self.duplicateLastProgressAt = Date()
                    }
                }
                try Task.checkCancellation()
                guard self.duplicateOperationID == operationID else { return }
                self.duplicatePhase = .assembling
                self.duplicateGroups = groups
                self.duplicatePhase = groups.isEmpty ? .noResults : .complete
                self.duplicateDidRun = true
                self.isFindingDuplicates = false
                self.duplicateOperationID = nil
            } catch is CancellationError {
                guard self.duplicateOperationID == operationID else { return }
                self.duplicatePhase = .cancelled
                self.isFindingDuplicates = false
                self.duplicateDidRun = true
                self.duplicateOperationID = nil
            } catch {
                guard self.duplicateOperationID == operationID else { return }
                self.duplicateError = error.localizedDescription
                self.duplicatePhase = .failed
                self.isFindingDuplicates = false
                self.duplicateDidRun = true
                self.duplicateOperationID = nil
            }
        }
        duplicateTask = task
        await task.value
    }

    func cancelDuplicateSearch() {
        duplicateOperationID = nil
        duplicateTask?.cancel()
        duplicateTask = nil
        if isFindingDuplicates {
            isFindingDuplicates = false
            duplicatePhase = .cancelled
            duplicateDidRun = true
        }
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

    func refreshLargeMediaCache() {
        guard let tree, let rootURL, selectedTotals.count == tree.count else {
            cachedLargeMedia = .empty
            return
        }
        cachedLargeMedia = MediaCatalog.build(
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

    func stageForCleanup(_ requests: [CleanupStageRequest]) async -> CleanupStageSummary {
        guard !isStagingCleanup else { return CleanupStageSummary(wasBusy: true) }
        isStagingCleanup = true
        defer { isStagingCleanup = false }
        var summary = CleanupStageSummary()
        for request in requests {
            let url = request.url.standardizedFileURL
            if isStaged(url) {
                summary.alreadyPresent += 1
                continue
            }
            let added = await cleanupQueue.stage(
                url,
                size: request.size,
                reason: request.reason,
                sharesStorageGroup: request.sharesStorageGroup,
                groupCopyCount: request.groupCopyCount
            )
            if added {
                summary.added += 1
                summary.addedURLs.append(url)
            } else {
                summary.rejected += 1
                summary.rejectedURLs.append(url)
            }
        }
        await refreshQueue()
        return summary
    }

    func unstageFromCleanup(_ item: CleanupQueue.StagedItem) async {
        await cleanupQueue.unstage(id: item.id)
        await refreshQueue()
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
        case .treemap: return "Compare storage by size"
        case .sunburst: return "See nested folder hierarchy"
        case .flame: return "Find deep storage-heavy paths"
        case .bubbles: return "Large items as proportional bubbles"
        case .folders: return "Browse folder by folder"
        case .ageMap: return "See storage by age"
        case .topSizes: return "The biggest items, ranked"
        case .mindMap: return "Explore folder relationships"
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
            .task(id: model.sizeBasis) {
                guard let tree = model.tree, let root = model.rootURL,
                      model.allocatedTotals.count == tree.count else { return }
                let allocated = model.allocatedTotals
                let logical = model.logicalTotals
                let basis = model.sizeBasis
                let quickWins = model.cachedQuickWins
                let categories = model.fileTypeCategories
                let worker = Task.detached(priority: .userInitiated) {
                    let totals = basis == .logical ? logical : allocated
                    let analysis = AnalysisSnapshot.build(tree: tree, root: root, allocated: allocated,
                        logical: logical, basis: basis, quickWins: quickWins)
                    let forgotten = ForgottenFiles.candidates(tree: tree, root: root, totals: totals, limit: 400)
                    let review = ReviewableCatalog.build(tree: tree, root: root, totals: totals, quickWins: quickWins)
                    let types = FileTypeCatalog.totals(in: tree, sizes: totals, categories: categories)
                    return (analysis, forgotten, review, types)
                }
                let result = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: { worker.cancel() }
                guard !Task.isCancelled, model.rootURL == root, model.sizeBasis == basis else { return }
                model.analysis = result.0
                model.cachedForgotten = result.1
                model.cachedForgottenSummary = ForgottenFiles.summary(from: result.1)
                model.cachedReviewables = result.2.targets
                model.cachedReviewableSummary = result.2.summary
                model.cachedFileTypes = result.3
            }
    }
}
