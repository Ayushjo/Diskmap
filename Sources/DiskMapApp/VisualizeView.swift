import AppKit
import DiskMapCore
import SwiftUI

/// Explore → Visualize: the chart is the page. Modes and colour on one row,
/// the path and folder total on the next, then the canvas.
struct VisualizeView: View {
    @ObservedObject var model: ScanModel
    @Environment(\.diskMapContentWidth) private var contentWidth
    var pickFolder: () -> Void

    @State private var showInspector = true
    @State private var showsLargestItems = false
    @State private var history: [Int32] = [0]
    @State private var historyIndex: Int = 0
    @State private var isMovingThroughHistory = false

    private var totals: [Int64] { model.selectedTotals }
    private var currentID: Int32 { model.currentNode }
    private var canGoBack: Bool { historyIndex > 0 }
    private var canGoForward: Bool { historyIndex + 1 < history.count }

    private var folderBytes: Int64 {
        let i = Int(currentID)
        guard i >= 0, i < totals.count else { return 0 }
        return totals[i]
    }

    private var itemCount: Int {
        let i = Int(currentID)
        let files = model.descendantFileCounts.indices.contains(i) ? model.descendantFileCounts[i] : 0
        let folders = model.descendantFolderCounts.indices.contains(i) ? model.descendantFolderCounts[i] : 0
        return files + folders
    }

    private var largestRows: [(id: Int32, size: Int64)] {
        guard let tree = model.tree, totals.count == tree.count else { return [] }
        return tree.children(of: currentID, totals: totals).filter { $0.size > 0 }.sorted { $0.size > $1.size }
    }

    var body: some View {
        Group {
            if model.tree == nil {
                FirstScanHero(model: model, pickFolder: pickFolder, onScanMac: {
                    Task { await model.scan(FileManager.default.homeDirectoryForCurrentUser) }
                })
            } else if showInspector {
                AdaptiveInspectorSplit(windowWidth: contentWidth, inspectionToken: String(model.selectedNode),
                                       main: mainColumn, inspector: inspector)
            } else {
                mainColumn
            }
        }
        .background(DiskMapTheme.canvas)
        .onAppear {
            syncHistory()
            if !ExploreViewMode.visualizeModes.contains(model.exploreMode) { model.exploreMode = .treemap }
        }
        .onChange(of: model.currentNode) { _, newValue in recordNavigation(newValue) }
    }

    private var mainColumn: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    Text("Visualize")
                        .font(DiskMapType.title)
                        .foregroundStyle(DiskMapTheme.ink)
                    Spacer(minLength: 12)
                    modePicker
                    Rectangle().fill(DiskMapTheme.line).frame(width: 1, height: 18)
                    // Age Map always colours by age, so the choice would do nothing there.
                    if model.exploreMode != .ageMap {
                        DiskMapMenu(label: "Color", options: ExploreColorMode.allCases,
                                    selection: $model.colorMode, title: { $0.rawValue })
                    }
                    DiskMapMenu(label: "Size", options: SizeBasis.allCases,
                                selection: $model.sizeBasis, title: { $0 == .allocated ? "On disk" : "Logical" })
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showInspector.toggle() }
                    } label: { Label("Inspector", systemImage: "sidebar.right") }
                        .buttonStyle(IconButtonStyle())
                        .help(showInspector ? "Hide inspector" : "Show inspector")
                }
                if let tree = model.tree, let root = model.rootURL, totals.count == tree.count {
                    HStack(spacing: 4) {
                        Button(action: goBack) { Label("Back", systemImage: "chevron.left") }
                            .disabled(!canGoBack).help("Back")
                        Button(action: goForward) { Label("Forward", systemImage: "chevron.right") }
                            .disabled(!canGoForward).help("Forward")
                        BreadcrumbBar(tree: tree, currentNode: currentID) { id in
                            model.currentNode = id
                            model.selectedNode = id
                        }
                        .padding(.leading, 6)
                        Spacer(minLength: 8)
                        HeaderSummary(parts: [ByteFormat.string(folderBytes), countLabel(itemCount, "item")])
                    }
                    .buttonStyle(IconButtonStyle())
                    ExploreCanvas(model: model, tree: tree, totals: totals, rootURL: root, hideTreemapChrome: true)
                        .id("\(model.sizeBasis):\(tree.count)")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                        .clipShape(RoundedRectangle(cornerRadius: DiskMapRadius.card, style: .continuous))
                    NodeSelectionToolbar(model: model)
                    HStack(spacing: 8) {
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { showsLargestItems.toggle() }
                        } label: {
                            Label("Largest items", systemImage: showsLargestItems ? "chevron.down" : "chevron.right")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(QuietButtonStyle())
                        Spacer()
                        Text("Area is \(model.sizeBasis == .allocated ? "space on disk" : "logical size")  ·  double-click a folder to open it")
                            .font(DiskMapType.figureSmall)
                            .foregroundStyle(DiskMapTheme.ink3)
                    }
                    if showsLargestItems {
                        ScrollView { largestList(tree: tree, root: root) }
                            .frame(height: min(220, geometry.size.height * 0.3))
                    }
                } else if model.isScanning {
                    DiskMapLoadingState(title: "Scanning…", detail: "\(model.scannedCount.formatted()) items so far")
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, DiskMapSpace.pageTop)
            .padding(.bottom, 16)
        }
    }

    private var modePicker: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 2) {
                ForEach(ExploreViewMode.visualizeModes) { mode in
                    Chip(title: mode.rawValue, isOn: model.exploreMode == mode) { model.exploreMode = mode }
                        .help(mode.blurb)
                }
            }
            DiskMapMenu(label: "View", options: ExploreViewMode.visualizeModes,
                        selection: $model.exploreMode, title: { $0.rawValue })
        }
    }

    private func largestList(tree: FileTree, root: URL) -> some View {
        let rows = Array(largestRows.prefix(6))
        let parent = max(1, folderBytes)
        return VStack(spacing: 0) {
            ForEach(rows, id: \.id) { row in
                let isDir = tree.isDirectory[Int(row.id)]
                let name = tree.name(of: row.id)
                let abs = tree.path(of: row.id, root: root).path
                let share = Double(row.size) / Double(parent)
                Button { model.selectedNode = row.id } label: {
                    KitRow(title: name, subtitle: nil, selected: row.id == model.selectedNode, path: abs,
                           onStage: nil, height: DiskMapSpace.row) {
                        if isDir {
                            Image(systemName: "folder")
                                .font(.system(size: DiskMapType.scaled(13)))
                                .foregroundStyle(DiskMapTheme.ink2)
                                .frame(width: 20, height: 20)
                        } else {
                            FileIdentityIcon(url: URL(fileURLWithPath: abs), size: 20)
                        }
                    } trailing: {
                        ProportionBar(fraction: share).frame(width: 64)
                        MonoColumn(text: String(format: "%.1f%%", share * 100), width: 52)
                        MonoColumn(text: ByteFormat.string(row.size), width: 74, emphasis: true)
                    }
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture(count: 2).onEnded { if isDir { model.currentNode = row.id } })
                .accessibilityLabel("\(name), \(ByteFormat.string(row.size)), \(String(format: "%.1f", share * 100)) percent")
                .accessibilityAddTraits(row.id == model.selectedNode ? .isSelected : [])
                .accessibilityAction(named: "Open") {
                    model.selectedNode = row.id
                    if isDir { model.currentNode = row.id }
                }
                RowSeparator(indent: 42)
            }
            HStack {
                Spacer()
                Button("Open in File Browser →") { model.destination = .fileBrowser }
                    .buttonStyle(LinkButtonStyle())
                    .font(DiskMapType.secondary)
            }
            .padding(.top, 6)
        }
    }

    private var inspector: some View {
        Group {
            if let tree = model.tree, let root = model.rootURL,
               model.selectedNode >= 0, Int(model.selectedNode) < tree.count {
                let id = model.selectedNode
                if tree.isDirectory[Int(id)] {
                    FolderInspector(model: model, tree: tree, rootURL: root, id: id, reason: "Visualize: " + tree.name(of: id))
                } else {
                    FileInspector(model: model, tree: tree, rootURL: root, id: id,
                                  size: Int(id) < totals.count ? totals[Int(id)] : 0,
                                  reason: "Visualize: " + tree.name(of: id))
                }
            } else {
                DiskMapEmptyState(symbol: "square.grid.2x2", title: "Select an item", message: "Click a tile to inspect it.")
            }
        }
        .background(DiskMapTheme.canvas)
    }

    // MARK: History

    private func syncHistory() {
        history = [model.currentNode]
        historyIndex = 0
    }

    private func recordNavigation(_ id: Int32) {
        if isMovingThroughHistory { isMovingThroughHistory = false; return }
        if historyIndex < history.count - 1 { history = Array(history.prefix(historyIndex + 1)) }
        if history.last != id { history.append(id) }
        historyIndex = history.count - 1
    }

    private func goBack() {
        guard canGoBack else { return }
        isMovingThroughHistory = true
        historyIndex -= 1
        model.currentNode = history[historyIndex]
        model.selectedNode = history[historyIndex]
    }

    private func goForward() {
        guard canGoForward else { return }
        isMovingThroughHistory = true
        historyIndex += 1
        model.currentNode = history[historyIndex]
        model.selectedNode = history[historyIndex]
    }
}
