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
    // Per-screen catalogs are NOT here: they are built on first visit
    // (TASK-043). Everything in this struct is what first paint needs.
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
    static let shared = ScanModel(scanCache: ScanCache(directory: ScanCache.defaultDirectory(), slot: "app"),
                                  recordsLastScan: true)

    @Published var tree: FileTree?
    @Published var allocatedTotals: [Int64] = []
    @Published var logicalTotals: [Int64] = []
    @Published var isScanning = false
    @Published var scannedCount = 0
    /// What the walk has found so far, a few times a second (TASK-044).
    @Published var liveProgress: ScanProgress?
    enum ScanPhase: Equatable { case idle, checkingChanges, walking, summarizing }

    /// Quick: start from the cached last scan and re-read only what changed
    /// (TASK-061), falling back to a full walk when that can't be trusted.
    enum ScanMode { case quick, full }

    /// How the tree on screen was produced — shown on Overview so a quick
    /// update is never mistaken for a fresh walk.
    enum ScanKind: Equatable {
        case full(seconds: Double, fallbackReason: String?)
        case quick(seconds: Double, changedFolders: Int, walkedFolders: Int)
    }
    @Published var lastScanKind: ScanKind?

    /// Where quick rescans start from. Nil for models made in tests, so they
    /// never write into the user's Application Support.
    let scanCache: ScanCache?
    private var cacheSave: Task<Void, Never>?
    /// The baseline that describes `tree`, so a Rescan can update the tree
    /// in memory instead of reading the cache back from disk.
    private var treeBaseline: ScanCache.Baseline?

    /// Only the app's own model remembers the last scan for the menu bar;
    /// models made in tests never write to the user's preferences.
    let recordsLastScan: Bool

    init(scanCache: ScanCache? = nil, recordsLastScan: Bool = false) {
        self.scanCache = scanCache
        self.recordsLastScan = recordsLastScan
    }
    /// Walking the disk, or turning the walk into the first screen (TASK-046).
    @Published var scanPhase: ScanPhase = .idle
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
    /// Full breakdown behind `reclaimableBytes`: what stays in use because
    /// other copies are not queued, and whether the figure is a lower bound.
    @Published var reclaimEstimate: CleanupQueue.ReclaimEstimate = .empty
    @Published var isStagingCleanup = false
    @Published var lastCommitLines: [String] = []
    @Published var sizeBasis: SizeBasis = .allocated
    @Published var currentNode: Int32 = 0
    @Published var selectedNode: Int32 = 0
    @Published var recentRoots: [URL] = ScanModel.loadRecentRoots()
    @Published var lastScanSeconds: Double?
    /// Directories the last scan could not open for lack of permission
    /// (TASK-039). Every total above them is short by what they hold.
    @Published var deniedDirectoryIDs: [Int32] = []
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
    /// New value per committed scan — views key one-shot work (the Search
    /// page's name index) to it instead of recomputing on every render (PR #16).
    @Published var scanID = UUID()
    /// The Find screen's query text (TASK-060). Lives here so ⌘K can hand a
    /// query over, and so it survives switching screens.
    @Published var findQuery = ""
    @Published var findSort: FileQuery.Sort = .largest
    /// The cleanup queue sheet; published so ⇧⌘⌫ can open it from the menu.
    @Published var isCleanupQueuePresented = false
    /// Nodes ⌘/⇧-selected together (MultiSelection.swift).
    @Published var multiSelection: Set<Int32> = []
    var selectionAnchor: Int32?
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
        scanPhase = .idle
        liveProgress = nil
        pendingRootURL = nil
        if tree == nil {
            rootURL = nil
            scannedCount = 0
        }
        log("scan cancelled")
    }

    func scan(_ url: URL, mode: ScanMode = .quick) async {
        // PR #16 guarded against a second concurrent scan. Here a different
        // folder still supersedes the running scan (the generation check
        // drops the old result), but a repeat request for the folder already
        // being scanned is ignored rather than starting a duplicate walk.
        if isScanning, let current = pendingRootURL ?? rootURL,
           current.standardizedFileURL.path == url.standardizedFileURL.path {
            log("scan ignored: already scanning \(url.path)")
            return
        }
        scanGeneration += 1
        let generation = scanGeneration
        let hasCommittedScan = tree != nil
        pendingRootURL = url
        if !hasCommittedScan { rootURL = url }
        isScanning = true
        scannedCount = 0
        liveProgress = nil
        scanPhase = .walking
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

        var quickUpdate: IncrementalScan.Update?
        var fallbackReason: String?
        if mode == .quick, let scanCache, !CanonicalPath.mayContainFirmlinkTwins(scanRootPath: url.path) {
            scanPhase = .checkingChanges
            let base = tree.flatMap { current in
                treeBaseline.map { IncrementalScan.Base(tree: current, baseline: $0) }
            }
            switch await IncrementalScan.update(root: url, cache: scanCache, base: base, sharing: CloneAccounting.mode) {
            case .updated(let update): quickUpdate = update
            case .fullScanNeeded(let reason): fallbackReason = reason
            }
            guard generation == scanGeneration else { return }
            log("quick rescan: \(quickUpdate.map { "updated, \($0.changedDirectories) folders re-read" } ?? "full walk — \(fallbackReason ?? "")")")
            if quickUpdate == nil { scanPhase = .walking }
        }

        let engine = ScanEngine()
        let live: @Sendable (ScanProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.deliverLive(progress, generation: generation) }
        }
        let counted: @Sendable (Int) -> Void = { [weak self] count in
            ScanModel.appendLog("scannedCount=\(count)")
            print("scannedCount=\(count)")
            fflush(stdout)
            Task { @MainActor in
                guard let self, self.scanGeneration == generation else { return }
                self.scannedCount = count
            }
        }
        let result: ScanEngine.Result
        if let quickUpdate {
            result = quickUpdate.scanResult
        } else {
            result = await engine.scan(root: url, sharing: CloneAccounting.mode, progress: counted, live: live)
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

        scanPhase = .summarizing
        let scannedTree = result.tree
        let categories = fileTypeCategories
        let basis = sizeBasis
        let postWalkStarted = ContinuousClock.now
        let prepared = await Task.detached(priority: .userInitiated) {
            let both = scannedTree.rollUpBoth()
            let counts = scannedTree.rollUpDescendantCounts()
            let quickWins = QuickWins.find(in: scannedTree, root: url, patterns: QuickWins.bundledPatterns())
            // Same basis as everything else on screen (was always allocated,
            // so File Types disagreed with sizes after a logical rescan).
            let fileTypes = FileTypeCatalog.totals(in: scannedTree, sizes: basis == .logical ? both.logical : both.allocated,
                                                   categories: categories)
            let analysis = AnalysisSnapshot.build(
                tree: scannedTree, root: url, allocated: both.allocated, logical: both.logical,
                basis: basis, quickWins: quickWins, fileTypes: fileTypes
            )
            return PreparedScan(
                allocated: both.allocated, logical: both.logical,
                fileCounts: counts.files, folderCounts: counts.folders,
                quickWins: quickWins, fileTypes: fileTypes, analysis: analysis
            )
        }.value
        guard generation == scanGeneration else {
            log("prepared scan discarded (cancelled) path=\(url.path)")
            return
        }
        logNotDownloadedContrast(tree: scannedTree, logical: prepared.logical, allocated: prepared.allocated)
        tree = scannedTree
        scanID = UUID()
        rootURL = url
        allocatedTotals = prepared.allocated
        logicalTotals = prepared.logical
        descendantFileCounts = prepared.fileCounts
        descendantFolderCounts = prepared.folderCounts
        cachedQuickWins = prepared.quickWins
        cachedFileTypes = prepared.fileTypes
        analysis = prepared.analysis
        // New tree: every per-screen catalog is stale. Screens rebuild theirs
        // on first visit (and any open screen immediately, via the generation).
        invalidateCatalogs()
        duplicateGroups = []
        duplicatePhase = .idle
        duplicateProgressDone = 0
        duplicateProgressTotal = 0
        duplicateError = nil
        duplicateDidRun = false
        folderFilterPath = nil
        selectedNode = 0
        currentNode = 0
        clearMultiSelection()   // node ids from the old tree mean nothing now
        lastScanSeconds = result.elapsedSeconds
        if let quickUpdate {
            lastScanKind = .quick(seconds: quickUpdate.elapsedSeconds, changedFolders: quickUpdate.changedDirectories,
                                  walkedFolders: quickUpdate.rewalkedSubtrees)
            saveScanCache(tree: scannedTree, baseline: quickUpdate.baseline)
        } else {
            lastScanKind = .full(seconds: result.elapsedSeconds, fallbackReason: mode == .quick ? fallbackReason : nil)
            if let baseline = IncrementalScan.baselineAfterFullScan(
                root: url, eventIDAtStart: result.eventIDAtStart,
                deniedPaths: result.deniedDirectoryIDs.map { scannedTree.path(of: $0, root: url).path }) {
                saveScanCache(tree: scannedTree, baseline: baseline)
            } else {
                treeBaseline = nil   // nothing describes this tree; the next Rescan walks
            }
        }
        deniedDirectoryIDs = result.deniedDirectoryIDs
        // Staging a folder from this tree can skip the walk when exact (TASK-082).
        let context = StorageSharing.ScanContext(
            tree: scannedTree, rootPath: url.path, eventID: result.eventIDAtStart,
            volumeUUID: FSEventHistory.volumeUUID(forPath: FSEventHistory.realPath(url.path)),
            deniedIDs: Set(result.deniedDirectoryIDs),
            barrierMarker: scanCache?.directory.appendingPathComponent(".event-barrier"),
            capturedAt: Date())
        Task { await cleanupQueue.setScanContext(context) }
        if recordsLastScan, let volume = VolumeStats.forPath(url.path) {
            LastScanRecord(rootPath: url.path, scannedAt: Date(), freeBytes: volume.freeBytes,
                           scannedBytes: prepared.allocated.first ?? 0).save()
        }
        rememberRecent(url)
        pendingRootURL = nil
        scanPhase = .idle
        liveProgress = nil
        isScanning = false
        let postWalk = postWalkStarted.duration(to: .now).components
        let postWalkSeconds = Double(postWalk.seconds) + Double(postWalk.attoseconds) / 1e18
        log("scan finished items=\(result.itemCount) walk_seconds=\(String(format: "%.3f", result.elapsedSeconds)) post_walk_seconds=\(String(format: "%.3f", postWalkSeconds))")
    }

    /// Writes the cache off the main thread, one save at a time, so the
    /// first screen never waits on a 100+ MB write.
    private func saveScanCache(tree: FileTree, baseline: ScanCache.Baseline) {
        treeBaseline = baseline
        guard let scanCache else { return }
        let previous = cacheSave
        cacheSave = Task.detached(priority: .utility) {
            await previous?.value
            do {
                try scanCache.save(tree: tree, baseline: baseline)
            } catch {
                ScanModel.appendLog("scan cache save failed: \(error.localizedDescription)")
            }
        }
    }

    /// For tests and the harness: the cache write started by the last scan.
    func waitForCacheSave() async {
        await cacheSave?.value
    }

    /// Drops reports from a scan that was cancelled or superseded.
    private func deliverLive(_ progress: ScanProgress, generation: Int) {
        guard scanGeneration == generation, isScanning else { return }
        liveProgress = progress
    }

    /// Display paths for a few unreadable directories, for the notice.
    func deniedDirectoryExamples(limit: Int = 3) -> [String] {
        guard let tree, let rootURL else { return [] }
        return deniedDirectoryIDs.prefix(limit).map {
            CanonicalPath.displayPath(absolutePath: tree.path(of: $0, root: rootURL).path)
        }
    }

    /// System Settings → Privacy & Security → Full Disk Access. Only opens
    /// the pane; granting access is the user's decision.
    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
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

    // MARK: - Per-screen catalogs, built on first visit (TASK-043)

    /// A catalog that backs one screen. Built only when that screen asks,
    /// off the main actor, and rebuilt when the tree or size basis changes.
    /// Measured before this (TASK-042): building all five eagerly held first
    /// paint for ~7.7 s on a home scan.
    enum Catalog: Hashable, CaseIterable, Sendable {
        case forgotten, reviewables, developer, oldDownloads, largeMedia
    }

    /// Catalogs whose cache matches the current tree and basis. Distinguishes
    /// "not built yet" from "built and genuinely empty" — the old `isEmpty`
    /// check rebuilt an empty catalog on every visit.
    @Published private(set) var readyCatalogs: Set<Catalog> = []
    /// Bumped whenever cached catalogs go stale; screens key their build
    /// request on it so an open screen refreshes by itself.
    @Published private(set) var catalogGeneration = 0
    private var catalogBuilds: [Catalog: Task<Void, Never>] = [:]

    func isCatalogReady(_ catalog: Catalog) -> Bool { readyCatalogs.contains(catalog) }

    /// Drop every per-screen catalog: new tree, or new size basis.
    func invalidateCatalogs() {
        catalogBuilds.values.forEach { $0.cancel() }
        catalogBuilds = [:]
        readyCatalogs = []
        cachedForgotten = []
        cachedForgottenSummary = .empty
        cachedReviewables = []
        cachedReviewableSummary = .empty
        cachedDeveloper = .empty
        cachedOldDownloads = .empty
        cachedLargeMedia = .empty
        catalogGeneration += 1
    }

    private enum BuiltCatalog: Sendable {
        case forgotten([ForgottenCandidate])
        case reviewables([ReviewableTarget], ReviewableSummary)
        case developer(DeveloperCatalogResult)
        case oldDownloads(OldDownloadsCatalogResult)
        case largeMedia(MediaCatalogResult)
    }

    /// Builds `catalog` if it is not ready, or waits for the build already in
    /// flight. Safe to call from every `.task` that shows the screen.
    func ensureCatalog(_ catalog: Catalog) async {
        if readyCatalogs.contains(catalog) { return }
        if let running = catalogBuilds[catalog] {
            await running.value
            return
        }
        guard let tree, let rootURL, selectedTotals.count == tree.count else { return }
        let generation = catalogGeneration
        let totals = selectedTotals
        let quickWins = cachedQuickWins
        let build = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                Self.build(catalog, tree: tree, root: rootURL, totals: totals, quickWins: quickWins)
            }.value
            guard let self, !Task.isCancelled, self.catalogGeneration == generation else { return }
            self.apply(built)
            self.readyCatalogs.insert(catalog)
            self.catalogBuilds[catalog] = nil
        }
        catalogBuilds[catalog] = build
        await build.value
    }

    /// Force a rebuild of one catalog (a screen's own "Rescan" button).
    func rebuildCatalog(_ catalog: Catalog) async {
        catalogBuilds[catalog]?.cancel()
        catalogBuilds[catalog] = nil
        readyCatalogs.remove(catalog)
        await ensureCatalog(catalog)
    }

    nonisolated private static func build(
        _ catalog: Catalog, tree: FileTree, root: URL, totals: [Int64], quickWins: [QuickWins.Hit]
    ) -> BuiltCatalog {
        switch catalog {
        case .forgotten:
            return .forgotten(ForgottenFiles.candidates(tree: tree, root: root, totals: totals, limit: 400))
        case .reviewables:
            let built = ReviewableCatalog.build(tree: tree, root: root, totals: totals, quickWins: quickWins)
            return .reviewables(built.targets, built.summary)
        case .developer:
            return .developer(DeveloperCatalog.build(tree: tree, root: root, totals: totals))
        case .oldDownloads:
            return .oldDownloads(OldDownloadsCatalog.build(tree: tree, root: root, totals: totals))
        case .largeMedia:
            return .largeMedia(MediaCatalog.build(tree: tree, root: root, totals: totals))
        }
    }

    private func apply(_ built: BuiltCatalog) {
        switch built {
        case .forgotten(let candidates):
            cachedForgotten = candidates
            cachedForgottenSummary = ForgottenFiles.summary(from: candidates)
        case .reviewables(let targets, let summary):
            cachedReviewables = targets
            cachedReviewableSummary = summary
        case .developer(let result):
            cachedDeveloper = result
        case .oldDownloads(let result):
            cachedOldDownloads = result
        case .largeMedia(let result):
            cachedLargeMedia = result
        }
    }

    /// Kept for callers and tests. With no tree it clears only this screen's
    /// cache — the TASK-041 bug was clearing Old Downloads here too.
    func refreshDeveloperCache() {
        guard let tree, selectedTotals.count == tree.count else {
            cachedDeveloper = .empty
            readyCatalogs.remove(.developer)
            return
        }
        Task { await rebuildCatalog(.developer) }
    }

    func refreshQueue() async {
        stagedItems = await cleanupQueue.allItems()
        reclaimEstimate = await cleanupQueue.reclaimEstimate()
        reclaimableBytes = reclaimEstimate.bytes
        if reclaimEstimate.isCalculating { watchMeasurements() }
    }

    private var measurementWatch: Task<Void, Never>?

    /// Staged folders are measured in the background; refresh once they are,
    /// so the figure — and the Move to Trash button — update by themselves.
    private func watchMeasurements() {
        guard measurementWatch == nil else { return }
        measurementWatch = Task { [weak self] in
            guard let self else { return }
            await self.cleanupQueue.waitForMeasurements()
            self.measurementWatch = nil
            await self.refreshQueue()
        }
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
        let report = await cleanupQueue.commitReport()
        let log = CleanupPreflight.logEntries(from: report)
        lastCommitLines = log.map { entry in
            if entry.succeeded {
                return "Moved to Trash: \(entry.path) (\(ByteFormat.string(entry.bytes))) — \(entry.reason)"
            }
            return "Failed \(entry.path): \(entry.errorDescription ?? "unknown error")"
        }
        if lastCommitLines.isEmpty {
            lastCommitLines = ["Nothing moved."]
        } else if log.contains(where: \.succeeded) {
            // Trash is not deletion: nothing is freed until it is emptied.
            let amount = ByteFormat.string(report.freedWhenTrashEmptied)
            lastCommitLines.append(
                "\(report.isLowerBound ? "At least " : "")\(amount) is freed when you empty the Trash."
            )
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
            .modifier(DropToScan(model: model))
            .task(id: model.sizeBasis) {
                guard let tree = model.tree, let root = model.rootURL,
                      model.allocatedTotals.count == tree.count else { return }
                let allocated = model.allocatedTotals
                let logical = model.logicalTotals
                let basis = model.sizeBasis
                let quickWins = model.cachedQuickWins
                let categories = model.fileTypeCategories
                // Every per-screen catalog was built from the other basis.
                // Before TASK-043 only Forgotten and Reviewables were rebuilt
                // here, so Developer, Old Downloads and Media went stale.
                model.invalidateCatalogs()
                let worker = Task.detached(priority: .userInitiated) {
                    let totals = basis == .logical ? logical : allocated
                    let types = FileTypeCatalog.totals(in: tree, sizes: totals, categories: categories)
                    let analysis = AnalysisSnapshot.build(tree: tree, root: root, allocated: allocated,
                        logical: logical, basis: basis, quickWins: quickWins, fileTypes: types)
                    return (analysis, types)
                }
                let result = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: { worker.cancel() }
                guard !Task.isCancelled, model.rootURL == root, model.sizeBasis == basis else { return }
                model.analysis = result.0
                model.cachedFileTypes = result.1
            }
    }
}
