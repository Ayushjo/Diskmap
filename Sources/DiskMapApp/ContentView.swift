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
    /// New value per scan — views key one-shot work (index builds,
    /// whole-tree queries) to it instead of recomputing on every render.
    @Published var scanID = UUID()

    let cleanupQueue = CleanupQueue()

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
        // A second concurrent scan would race both `tree` and the
        // progress reporting — the picker is disabled while scanning,
        // this is the belt to that suspenders.
        guard !isScanning else { return }
        rootURL = url
        isScanning = true
        scannedCount = 0
        currentNode = 0
        allocatedTotals = []
        logicalTotals = []
        duplicateGroups = []
        scanID = UUID()
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

        // Rollups walk every node; keep the main actor responsive while
        // they run. FileTree is a value type — the detached task shares
        // the packed arrays, it does not copy them.
        let scannedTree = result.tree
        let rolled = await Task.detached(priority: .userInitiated) {
            (scannedTree.rollUpSizes(basis: .allocated), scannedTree.rollUpSizes(basis: .logical))
        }.value
        logNotDownloadedContrast(tree: scannedTree, logical: rolled.1, allocated: rolled.0)
        tree = scannedTree
        allocatedTotals = rolled.0
        logicalTotals = rolled.1
        isScanning = false
        log("scan finished items=\(result.itemCount)")
    }

    func findDuplicates() async {
        guard let tree, let rootURL else { return }
        isFindingDuplicates = true
        // Candidate collection walks the whole tree; size-colliding only
        // keeps `path` building off the files that can never match.
        duplicateGroups = await Task.detached(priority: .userInitiated) { () async -> [DuplicateGroup] in
            let files = DuplicateFinder.sizeCollidingCandidates(in: tree, root: rootURL)
            return await DuplicateFinder.findDuplicates(candidates: files)
        }.value
        isFindingDuplicates = false
    }

    func refreshQueue() async {
        stagedItems = await cleanupQueue.allItems()
        reclaimableBytes = await cleanupQueue.totalSize()
    }

    func commitCleanup() async {
        let results = await cleanupQueue.commit()
        lastCommitLines = results.map { result in
            if let error = result.error {
                return "Failed \(result.item.url.path): \(error.localizedDescription)"
            }
            return "Moved to Trash \(result.item.url.path)"
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

private enum WorkspacePage: String, CaseIterable, Identifiable {
    case map = "Map"
    case search = "Search"
    case topSizes = "Top Sizes"
    case folders = "Folders"
    case ageMap = "Age Map"
    case sunburst = "Sunburst"
    case flame = "Flame"
    case bubbles = "Bubbles"
    case mindMap = "Mind Map"
    case snapshots = "Snapshots"
    case duplicates = "Duplicates"
    case quickWins = "Quick Wins"
    case developer = "Developer"
    case apps = "Apps"
    case cleanup = "Cleanup"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .map: return "square.grid.3x3.fill"
        case .search: return "magnifyingglass"
        case .topSizes: return "list.number"
        case .folders: return "folder"
        case .ageMap: return "calendar"
        case .sunburst: return "sun.max"
        case .flame: return "chart.bar.xaxis"
        case .bubbles: return "circle.grid.2x2"
        case .mindMap: return "point.3.connected.trianglepath.dotted"
        case .snapshots: return "clock.arrow.circlepath"
        case .duplicates: return "doc.on.doc"
        case .quickWins: return "bolt"
        case .developer: return "wrench.and.screwdriver"
        case .apps: return "app"
        case .cleanup: return "trash"
        }
    }
}

struct ContentView: View {
    @ObservedObject private var model = ScanModel.shared
    @State private var page: WorkspacePage = .map

    var body: some View {
        NavigationSplitView {
            List(WorkspacePage.allCases, selection: $page) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 168, ideal: 188, max: 240)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    if model.tree != nil {
                        Picker("Size", selection: $model.sizeBasis) {
                            Text("Logical").tag(SizeBasis.logical)
                            Text("On Disk").tag(SizeBasis.allocated)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 180)
                        .accessibilityIdentifier("size-basis")
                    }
                    Spacer()
                    Button("Choose Folder…") { pickFolder() }
                        .disabled(model.isScanning)
                }
                .padding(8)
                pageContent
            }
        }
        .frame(minWidth: 900, minHeight: 640)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .map:
            mapPage
        case .search:
            scannedPage { tree, totals, root in
                SearchView(model: model, tree: tree, totals: totals, rootURL: root, currentNode: $model.currentNode) {
                    page = .map
                }
            }
        case .topSizes:
            scannedPage { tree, totals, root in
                TopSizesView(tree: tree, totals: totals, rootURL: root)
            }
        case .folders:
            scannedPage { tree, totals, root in
                FoldersView(tree: tree, totals: totals, rootURL: root, currentNode: $model.currentNode)
            }
        case .ageMap:
            scannedPage { tree, totals, root in
                AgeMapView(model: model, tree: tree, totals: totals, rootURL: root)
            }
        case .sunburst:
            chartPage(.sunburst)
        case .flame:
            chartPage(.flame)
        case .bubbles:
            chartPage(.bubbles)
        case .mindMap:
            chartPage(.mindMap)
        case .snapshots:
            scannedPage { tree, _, root in
                SnapshotDiffView(tree: tree, rootURL: root, basis: model.sizeBasis)
            }
        case .duplicates:
            if let tree = model.tree, let rootURL = model.rootURL {
                DuplicatesView(model: model, tree: tree, rootURL: rootURL)
            } else {
                needsScan
            }
        case .quickWins:
            if let tree = model.tree, let rootURL = model.rootURL,
               model.allocatedTotals.count == tree.count {
                QuickWinsView(model: model, tree: tree, totals: model.allocatedTotals, rootURL: rootURL)
            } else {
                needsScan
            }
        case .developer:
            scannedPage { tree, totals, root in
                DeveloperView(model: model, tree: tree, totals: totals, rootURL: root)
            }
        case .apps:
            AppsView(model: model)
        case .cleanup:
            CleanupQueueView(model: model)
        }
    }

    @ViewBuilder
    private var mapPage: some View {
        if let tree = model.tree,
           let rootURL = model.rootURL,
           model.selectedTotals.count == tree.count,
           tree.count > 0 {
            TreemapContainerView(
                tree: tree,
                totals: model.selectedTotals,
                rootURL: rootURL,
                currentNode: $model.currentNode
            )
        } else if model.isScanning {
            scanning
        } else {
            needsScan
        }
    }

    @ViewBuilder
    private func scannedPage<Content: View>(
        @ViewBuilder content: (FileTree, [Int64], URL) -> Content
    ) -> some View {
        if let tree = model.tree, let rootURL = model.rootURL,
           model.selectedTotals.count == tree.count, tree.count > 0 {
            content(tree, model.selectedTotals, rootURL)
        } else if model.isScanning {
            scanning
        } else {
            needsScan
        }
    }

    @ViewBuilder
    private func chartPage(_ kind: LayoutChartKind) -> some View {
        scannedPage { tree, totals, _ in
            LayoutChartView(kind: kind, tree: tree, totals: totals, currentNode: $model.currentNode)
        }
    }

    private var scanning: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Scanning… \(model.scannedCount) items")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("scan-progress")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var needsScan: some View {
        Text("Pick a folder to see what's using space")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.scan(url) }
    }
}

/// Single-level treemap of `currentNode`'s direct children. Tap a
/// directory to drill in; the breadcrumb jumps back to any ancestor.
struct TreemapContainerView: View {
    let tree: FileTree
    let totals: [Int64]
    let rootURL: URL
    @Binding var currentNode: Int32

    @State private var layoutRects: [TreemapRect] = []
    @State private var canvasSize: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                BreadcrumbBar(tree: tree, currentNode: currentNode) { id in
                    currentNode = id
                    cacheLayout()
                }
                Spacer(minLength: 8)
                Text(byteString(currentSize))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("current-size")
            }
            .padding(8)

            Canvas { context, size in
                let items = tree.children(of: currentNode, totals: totals)
                let rects = SquarifiedTreemap.layout(items: items, in: CGRect(origin: .zero, size: size))

                for r in rects {
                    let inset = r.rect.insetBy(dx: 1, dy: 1)
                    let path = Path(inset)
                    context.fill(path, with: .color(colorFor(id: r.id)))
                    context.stroke(path, with: .color(.black.opacity(0.25)), lineWidth: 1)

                    if inset.width > 40 && inset.height > 16 {
                        context.draw(
                            Text(tree.name(of: r.id)).font(.caption).foregroundStyle(.white),
                            at: CGPoint(x: inset.minX + 4, y: inset.minY + 4),
                            anchor: .topLeading
                        )
                    }
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { cacheLayout(in: proxy.size) }
                        .onChange(of: proxy.size) { _, newSize in
                            cacheLayout(in: newSize)
                        }
                }
            }
            // Registered before the single-tap so two quick taps on a
            // file reveal it in Finder instead of tapping it twice.
            .onTapGesture(count: 2) { location in
                guard let hit = SquarifiedTreemap.hitTest(layoutRects, at: location) else { return }
                guard !tree.isDirectory[Int(hit)] else { return }
                revealDownloadedFile(hit, tree: tree, root: rootURL)
            }
            .onTapGesture { location in
                guard let hit = SquarifiedTreemap.hitTest(layoutRects, at: location) else { return }
                guard tree.isDirectory[Int(hit)] else { return }
                currentNode = hit
                cacheLayout()
            }
        }
        .onChange(of: currentNode) { _, _ in cacheLayout() }
        .onChange(of: totals) { _, _ in cacheLayout() }
    }

    private var currentSize: Int64 {
        guard currentNode >= 0, Int(currentNode) < totals.count else { return 0 }
        return totals[Int(currentNode)]
    }

    private func cacheLayout(in size: CGSize? = nil) {
        if let size, size.width > 0, size.height > 0 {
            canvasSize = size
        }
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            layoutRects = []
            return
        }
        let items = tree.children(of: currentNode, totals: totals)
        layoutRects = SquarifiedTreemap.layout(items: items, in: CGRect(origin: .zero, size: canvasSize))
    }

    private func colorFor(id: Int32) -> Color {
        // Hash-to-hue only. Semantic coloring is still TASK-023.
        nodeColor(id: id)
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
