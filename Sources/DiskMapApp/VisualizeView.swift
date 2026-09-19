import AppKit
import DiskMapCore
import SwiftUI

/// Explore → Visualize: storage exploration workspace (ref DiskMapVisualize.png).
/// No Explore secondary sidebar — viz is the hero.
struct VisualizeView: View {
    @ObservedObject var model: ScanModel
    @Environment(\.diskMapContentWidth) private var contentWidth
    var pickFolder: () -> Void
    var onOpenCleanup: () -> Void = {}

    @State private var showInspector = true
    @State private var showsLargestItems = false
    @State private var history: [Int32] = [0]
    @State private var historyIndex: Int = 0
    @State private var isMovingThroughHistory = false
    @State private var folderComposition: [FileTypeTotals] = []
    @State private var compositionLoading = false
    @State private var compositionCache: [Int32: [FileTypeTotals]] = [:]
    @State private var compositionTask: Task<Void, Never>?
    @State private var selectedComposition: [FileTypeTotals] = []
    @State private var selectedCompositionTask: Task<Void, Never>?

    private var totals: [Int64] { model.selectedTotals }

    private var usedDenominator: Int64 {
        if let vol = model.analysis.volume { return max(1, Int64(vol.usedBytes)) }
        return max(1, model.analysis.scannedBytes)
    }

    private var currentID: Int32 { model.currentNode }

    private var canGoBack: Bool { historyIndex > 0 }
    private var canGoForward: Bool { historyIndex + 1 < history.count }

    private var folderBytes: Int64 {
        let i = Int(currentID)
        guard i >= 0, i < totals.count else { return 0 }
        return totals[i]
    }

    private var folderName: String {
        if currentID == 0 {
            return VolumeStats.forPath(model.rootURL?.path ?? "/")?.volumeName ?? "Macintosh HD"
        }
        guard let tree = model.tree else { return "—" }
        return tree.name(of: currentID)
    }

    private var fileCount: Int {
        let i = Int(currentID)
        return model.descendantFileCounts.indices.contains(i) ? model.descendantFileCounts[i] : 0
    }

    private var folderCount: Int {
        let i = Int(currentID)
        return model.descendantFolderCounts.indices.contains(i) ? model.descendantFolderCounts[i] : 0
    }

    private var largestRows: [(id: Int32, size: Int64)] {
        guard let tree = model.tree, totals.count == tree.count else { return [] }
        return tree.children(of: currentID, totals: totals)
            .filter { $0.size > 0 }
            .sorted { $0.size > $1.size }
    }

    var body: some View {
        Group {
            if showInspector {
                AdaptiveInspectorSplit(windowWidth: contentWidth, inspectionToken: String(model.selectedNode), main: mainColumn, inspector: inspector)
            } else {
                mainColumn
            }
        }
        .background(DiskMapTheme.cream)
        .onAppear {
            syncHistory()
            if !ExploreViewMode.visualizeModes.contains(model.exploreMode) {
                model.exploreMode = .treemap
            }
            scheduleFolderComposition(for: currentID)
            if model.selectedNode != currentID {
                scheduleSelectedComposition(for: model.selectedNode)
            }
        }
        .onChange(of: model.currentNode) { _, newValue in
            recordNavigation(newValue)
            scheduleFolderComposition(for: newValue)
        }
        .onChange(of: model.selectedNode) { _, newValue in
            scheduleSelectedComposition(for: newValue)
        }
        .onDisappear {
            compositionTask?.cancel()
            selectedCompositionTask?.cancel()
        }
    }

    private var mainColumn: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Visualize Storage").font(DiskMapType.title)
                        Text("Select to inspect · Double-click a folder to explore")
                            .font(DiskMapType.caption).foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                    Spacer()
                    DiskMapMenu(label: "Size", options: SizeBasis.allCases,
                                selection: $model.sizeBasis, title: { $0 == .allocated ? "On Disk" : "Logical" })
                }
                navToolbar
                modePicker
                if let tree = model.tree, let root = model.rootURL, totals.count == tree.count {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill").foregroundStyle(DiskMapTheme.info)
                        Text(tree.name(of: currentID)).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(ByteFormat.string(folderBytes)).font(.system(size: 14, weight: .semibold).monospacedDigit())
                        Text("· \(formatCount(fileCount + folderCount)) items")
                            .font(DiskMapType.caption).foregroundStyle(DiskMapTheme.mutedLabel)
                        Spacer()
                        DiskMapMenu(label: "Color", options: ExploreColorMode.allCases,
                                    selection: $model.colorMode, title: { $0.rawValue })
                    }
                    ExploreCanvas(model: model, tree: tree, totals: totals, rootURL: root, hideTreemapChrome: true)
                        .id("\(model.sizeBasis):\(tree.count)")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                        .background(DiskMapTheme.cardFill)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DiskMapTheme.cardStroke, lineWidth: 1))
                    HStack {
                        Button {
                            showsLargestItems.toggle()
                        } label: {
                            Label("Largest items", systemImage: showsLargestItems ? "chevron.down" : "chevron.right")
                        }.buttonStyle(.plain)
                        Spacer()
                        Text("Area represents \(model.sizeBasis == .allocated ? "space on disk" : "logical file size")")
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    }.font(DiskMapType.caption).frame(height: 24)
                    if showsLargestItems {
                        ScrollView { largestTable(tree: tree, root: root) }
                            .frame(height: min(190, geometry.size.height * 0.28))
                    }
                } else if model.isScanning {
                    scanningState
                } else {
                    emptyScan
                }
            }
            .padding(18)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Visualize Storage")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(DiskMapTheme.ink)
            Text("Explore where your Mac’s storage is going. Click any item to drill down.")
                .font(.system(size: 12))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            HStack(spacing: 6) {
                Circle()
                    .fill(model.isScanning ? DiskMapTheme.review : DiskMapTheme.safe)
                    .frame(width: 7, height: 7)
                if model.isScanning {
                    Text("Scanning… \(model.scannedCount.formatted(.number.locale(Locale(identifier: "en_US")))) items")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                } else {
                    Text("Scan completed · \(formatCount(model.analysis.fileCount)) files · \(formatCount(model.analysis.folderCount)) folders")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var navToolbar: some View {
        HStack(spacing: 8) {
            navBtn("chevron.left", enabled: canGoBack) { goBack() }
            navBtn("chevron.right", enabled: canGoForward) { goForward() }
            breadcrumb
            Spacer(minLength: 8)

        }
    }

    private func navBtn(_ system: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(enabled ? DiskMapTheme.ink : DiskMapTheme.mutedLabel.opacity(0.4))
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(DiskMapTheme.cardFill)
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(DiskMapTheme.cardStroke, lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var breadcrumb: some View {
        Group {
            if let tree = model.tree, let root = model.rootURL {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        let crumbs = tree.ancestorIDs(of: currentID)
                        ForEach(Array(crumbs.enumerated()), id: \.element) { i, id in
                            if i > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(DiskMapTheme.mutedLabel)
                            }
                            Button {
                                model.currentNode = id
                                model.selectedNode = id
                            } label: {
                                Text(crumbLabel(id, tree: tree, root: root))
                                    .font(.system(size: 12, weight: id == currentID ? .semibold : .medium))
                                    .foregroundStyle(id == currentID ? DiskMapTheme.ink : DiskMapTheme.info)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func crumbLabel(_ id: Int32, tree: FileTree, root: URL) -> String {
        if id == 0 {
            return tree.name(of: id)
        }
        return tree.name(of: id)
    }

    // MARK: - Mode picker (reference)

    private var modePicker: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                ForEach(ExploreViewMode.visualizeModes) { mode in
                    Button { model.exploreMode = mode } label: {
                        Label(mode.rawValue, systemImage: mode.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10).frame(height: 32)
                            .foregroundStyle(model.exploreMode == mode ? Color.white : DiskMapTheme.ink)
                            .background(model.exploreMode == mode ? DiskMapTheme.ink : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).help(mode.blurb)
                }
            }
            DiskMapMenu(label: "View", options: ExploreViewMode.visualizeModes,
                        selection: $model.exploreMode, title: { $0.rawValue })
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color(red: 0.32, green: 0.56, blue: 0.98))
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(red: 0.32, green: 0.56, blue: 0.98).opacity(0.12))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(folderName)
                        .font(.system(size: 16, weight: .semibold))
                    Text("\(ByteFormat.string(folderBytes)) · \(formatCount(fileCount + folderCount)) items (\(formatCount(fileCount)) files, \(formatCount(folderCount)) folders)")
                        .font(.system(size: 11))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
                Spacer()
                if compositionLoading && folderComposition.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }
            if !folderComposition.isEmpty {
                compositionBar(folderComposition)
                HStack(spacing: 10) {
                    ForEach(Array(folderComposition.prefix(5)), id: \.categoryID) { row in
                        HStack(spacing: 4) {
                            Circle().fill(DiskMapTheme.hex(row.colorHex)).frame(width: 6, height: 6)
                            Text("\(row.label) \(ByteFormat.string(row.bytes))")
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DiskMapTheme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func compositionBar(_ rows: [FileTypeTotals]) -> some View {
        let total = max(1, rows.reduce(Int64(0)) { $0 + $1.bytes })
        return Color.clear
            .frame(height: 8)
            .overlay {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(Array(rows.prefix(6)), id: \.categoryID) { row in
                            let w = geo.size.width * CGFloat(Double(row.bytes) / Double(total))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(DiskMapTheme.hex(row.colorHex))
                                .frame(width: max(4, w))
                        }
                    }
                }
            }
    }

    // MARK: - Largest items table

    private func largestTable(tree: FileTree, root: URL) -> some View {
        let rows = Array(largestRows.prefix(6))
        let parent = max(1, folderBytes)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Largest items in this folder")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("View in File Browser →") {
                    model.destination = .fileBrowser
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DiskMapTheme.info)
            }
            .padding(.horizontal, 16)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("#").frame(width: 22, alignment: .leading)
                    Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Kind").frame(width: 80, alignment: .leading)
                    Text("Size").frame(width: 72, alignment: .trailing)
                    Text("%").frame(width: 48, alignment: .trailing)
                    Text("Modified").frame(width: 90, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)

                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                    let selected = row.id == model.selectedNode
                    let isDir = tree.isDirectory[Int(row.id)]
                    let name = tree.name(of: row.id)
                    let pct = Double(row.size) / Double(parent) * 100
                    HStack(spacing: 8) {
                        Text("\(idx + 1)")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                            .frame(width: 22, alignment: .leading)
                        HStack(spacing: 6) {
                            Image(systemName: isDir ? "folder.fill" : "doc")
                                .font(.system(size: 11))
                                .foregroundStyle(isDir ? Color(red: 0.32, green: 0.56, blue: 0.98) : DiskMapTheme.mutedLabel)
                            Text(name)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(isDir ? "Folder" : FileKind.classify(fileName: name, path: tree.path(of: row.id, root: root).path).title)
                            .font(.system(size: 11))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                            .frame(width: 80, alignment: .leading)
                        Text(ByteFormat.string(row.size))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .frame(width: 72, alignment: .trailing)
                        Text(String(format: "%.1f%%", pct))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                            .frame(width: 48, alignment: .trailing)
                        Text(relativeModified(tree.modifiedDay[Int(row.id)]))
                            .font(.system(size: 11))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                            .frame(width: 90, alignment: .trailing)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(selected ? DiskMapTheme.ink.opacity(0.06) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        model.selectedNode = row.id
                        if isDir { model.currentNode = row.id }
                    }
                    .onTapGesture(count: 1) {
                        model.selectedNode = row.id
                    }
                    Divider().overlay(DiskMapTheme.cardStroke.opacity(0.5)).padding(.leading, 40)
                }
            }
            .padding(.bottom, 8)
        }
        .background(DiskMapTheme.cardFill.opacity(0.55))
    }

    // MARK: - Inspector

    private var inspector: some View {
        Group {
            if let tree = model.tree, let root = model.rootURL,
               model.selectedNode >= 0, Int(model.selectedNode) < tree.count {
                let id = model.selectedNode
                if tree.isDirectory[Int(id)] {
                    VisualizeFolderInspector(
                        model: model,
                        tree: tree,
                        rootURL: root,
                        nodeID: id,
                        usedDenominator: usedDenominator,
                        composition: id == currentID ? folderComposition : selectedComposition,
                        compositionLoading: compositionLoading,
                        onOpenCleanup: onOpenCleanup
                    )
                } else {
                    VisualizeFileInspector(
                        model: model,
                        tree: tree,
                        rootURL: root,
                        nodeID: id,
                        usedDenominator: usedDenominator,
                        onOpenCleanup: onOpenCleanup
                    )
                }
            } else {
                VStack {
                    Text("Select an item")
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DiskMapTheme.cardFill)
    }

    private var emptyScan: some View {
        VStack(spacing: 14) {
            Text("Scan your Mac to visualize storage")
                .font(.system(size: 16, weight: .semibold))
            Text("Treemap and the other views use the same scan as Overview and Find.")
                .font(DiskMapType.body)
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Scan Full Mac") {
                Task { await model.scan(URL(fileURLWithPath: "/", isDirectory: true)) }
            }
            .buttonStyle(InkButtonStyle())
            Button("Choose Folder…", action: pickFolder)
                .buttonStyle(InkButtonStyle(filled: false))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanningState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Scanning your Mac…")
                .font(.system(size: 14, weight: .semibold))
            Text("\(model.scannedCount.formatted(.number.locale(Locale(identifier: "en_US")))) items discovered")
                .font(.system(size: 12))
                .foregroundStyle(DiskMapTheme.mutedLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - History / composition

    private func syncHistory() {
        history = [model.currentNode]
        historyIndex = 0
    }

    private func recordNavigation(_ id: Int32) {
        if isMovingThroughHistory { isMovingThroughHistory = false; return }
        if historyIndex < history.count - 1 {
            history = Array(history.prefix(historyIndex + 1))
        }
        if history.last != id {
            history.append(id)
            historyIndex = history.count - 1
        } else {
            historyIndex = history.count - 1
        }
    }

    private func goBack() {
        guard canGoBack else { return }
        isMovingThroughHistory = true
        historyIndex -= 1
        let id = history[historyIndex]
        model.currentNode = id
        model.selectedNode = id
    }

    private func goForward() {
        guard canGoForward else { return }
        isMovingThroughHistory = true
        historyIndex += 1
        let id = history[historyIndex]
        model.currentNode = id
        model.selectedNode = id
    }

    private func scheduleFolderComposition(for id: Int32) {
        guard let tree = model.tree, totals.count == tree.count else { return }
        if id == 0, !model.cachedFileTypes.isEmpty {
            folderComposition = model.cachedFileTypes
            compositionCache[id] = model.cachedFileTypes
            compositionLoading = false
            return
        }
        if let cached = compositionCache[id] {
            folderComposition = cached
            compositionLoading = false
            return
        }
        folderComposition = []
        compositionLoading = true
        compositionTask?.cancel()
        let categories = model.fileTypeCategories
        let totals = self.totals
        compositionTask = Task.detached(priority: .userInitiated) {
            let result = FileTypeCatalog.totals(under: id, in: tree, sizes: totals, categories: categories)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                compositionCache[id] = result
                if model.currentNode == id {
                    folderComposition = result
                    compositionLoading = false
                }
            }
        }
    }

    private func scheduleSelectedComposition(for id: Int32) {
        guard let tree = model.tree, totals.count == tree.count,
              id >= 0, Int(id) < tree.count, tree.isDirectory[Int(id)] else {
            selectedComposition = []
            return
        }
        if let cached = compositionCache[id] {
            selectedComposition = cached
            return
        }
        if id == currentID {
            // The inspector reads folderComposition directly for the current
            // folder. Never launch a second full-subtree traversal for it.
            selectedComposition = []
            return
        }
        selectedCompositionTask?.cancel()
        let categories = model.fileTypeCategories
        let totals = self.totals
        selectedCompositionTask = Task.detached(priority: .utility) {
            let result = FileTypeCatalog.totals(under: id, in: tree, sizes: totals, categories: categories)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                compositionCache[id] = result
                if model.selectedNode == id {
                    selectedComposition = result
                }
            }
        }
    }

    private func formatCount(_ n: Int) -> String {
        n.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    private func relativeModified(_ day: Int32) -> String {
        guard day > 0 else { return "—" }
        let age = AgeMap.today() - day
        if age <= 0 { return "Today" }
        if age == 1 { return "Yesterday" }
        if age < 30 { return "\(age) days ago" }
        if age < 365 {
            let m = max(1, age / 30)
            return m == 1 ? "1 month ago" : "\(m) months ago"
        }
        let y = max(1, age / 365)
        return y == 1 ? "1 year ago" : "\(y) years ago"
    }
}

// MARK: - Inspectors

private struct VisualizeFolderInspector: View {
    @ObservedObject var model: ScanModel
    let tree: FileTree
    let rootURL: URL
    let nodeID: Int32
    let usedDenominator: Int64
    let composition: [FileTypeTotals]
    let compositionLoading: Bool
    var onOpenCleanup: () -> Void

    private var name: String {
        nodeID == 0
            ? (VolumeStats.forPath(rootURL.path)?.volumeName ?? "Macintosh HD")
            : tree.name(of: nodeID)
    }
    private var abs: String { tree.path(of: nodeID, root: rootURL).path }
    private var bytes: Int64 {
        Int(nodeID) < model.selectedTotals.count ? model.selectedTotals[Int(nodeID)] : 0
    }
    private var safety: SafetyAssessment {
        SafetyClassifier.assess(path: abs, name: name, isDirectory: true)
    }
    private var why: String {
        if composition.isEmpty { return compositionLoading ? "Calculating…" : "Mixed contents." }
        let top = composition.prefix(3).map { "\($0.label.lowercased()) (\(ByteFormat.string($0.bytes)))" }
        return "Mostly " + top.joined(separator: ", ") + "."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color(red: 0.32, green: 0.56, blue: 0.98))
                        .frame(width: 48, height: 48)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.32, green: 0.56, blue: 0.98).opacity(0.12)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.system(size: 14, weight: .semibold))
                        Text(ByteFormat.string(bytes))
                            .font(.system(size: 22, weight: .semibold).monospacedDigit())
                        Text(String(format: "%.1f%% of used storage", min(100, Double(bytes) / Double(usedDenominator) * 100)))
                            .font(.system(size: 11))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                }

                meta("Location", CanonicalPath.displayPath(absolutePath: abs))
                meta(
                    "Items",
                    "\(fmt(model.descendantFileCounts.indices.contains(Int(nodeID)) ? model.descendantFileCounts[Int(nodeID)] : 0)) files · \(fmt(model.descendantFolderCounts.indices.contains(Int(nodeID)) ? model.descendantFolderCounts[Int(nodeID)] : 0)) folders"
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("What's inside?").font(.system(size: 12, weight: .semibold))
                    if compositionLoading && composition.isEmpty {
                        ProgressView().controlSize(.small)
                    } else {
                        ForEach(Array(composition.prefix(5)), id: \.categoryID) { row in
                            HStack {
                                Circle().fill(DiskMapTheme.hex(row.colorHex)).frame(width: 7, height: 7)
                                Text(row.label).font(.system(size: 12))
                                Spacer()
                                Text(ByteFormat.string(row.bytes))
                                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                                    .foregroundStyle(DiskMapTheme.mutedLabel)
                            }
                            ProportionBar(
                                fraction: Double(row.bytes) / Double(max(1, bytes)),
                                tint: DiskMapTheme.hex(row.colorHex)
                            )
                            .frame(height: 3)
                        }
                    }
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(Color(red: 0.85, green: 0.55, blue: 0.15))
                    Text(why)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 1, green: 0.96, blue: 0.90)))

                if safety.level == .protected {
                    Text("Protected / system location. DiskMap won’t offer deletion here.")
                        .font(.system(size: 11))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }

                VStack(spacing: 8) {
                    if safety.level != .protected {
                        Button(model.isStaged(URL(fileURLWithPath: abs, isDirectory: true))
                               ? "Open Cleanup Queue" : "Add to Cleanup") {
                            Task { await stage() }
                        }
                        .buttonStyle(PrimaryCTAStyle(fullWidth: true))
                    }
                    Button("Open in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: abs)])
                    }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                    Button("View in File Browser") {
                        model.currentNode = nodeID
                        model.selectedNode = nodeID
                        model.destination = .fileBrowser
                    }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(CanonicalPath.displayPath(absolutePath: abs), forType: .string)
                        model.showToast("Path copied")
                    }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                }
            }
            .padding(16)
        }
    }

    private func meta(_ l: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(l).font(.system(size: 10, weight: .semibold)).foregroundStyle(DiskMapTheme.mutedLabel)
            Text(v).font(.system(size: 12)).textSelection(.enabled)
        }
    }

    private func fmt(_ n: Int) -> String {
        n.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    private func stage() async {
        let url = URL(fileURLWithPath: abs, isDirectory: true).standardizedFileURL
        let result = await model.stageForCleanup([
            CleanupStageRequest(url: url, size: bytes, reason: "Visualize: " + name)
        ])
        model.showToast(result.added > 0 ? "Added to Cleanup" : (result.rejected > 0 ? "Blocked by safety rules" : "Already in Cleanup"))
        if result.added > 0 || result.alreadyPresent > 0 { onOpenCleanup() }
    }
}

private struct VisualizeFileInspector: View {
    @ObservedObject var model: ScanModel
    let tree: FileTree
    let rootURL: URL
    let nodeID: Int32
    let usedDenominator: Int64
    var onOpenCleanup: () -> Void

    private var name: String { tree.name(of: nodeID) }
    private var abs: String { tree.path(of: nodeID, root: rootURL).path }
    private var size: Int64 {
        Int(nodeID) < model.selectedTotals.count ? model.selectedTotals[Int(nodeID)] : 0
    }
    private var kind: FileKind { FileKind.classify(fileName: name, path: abs) }
    private var safety: SafetyAssessment {
        SafetyClassifier.assess(path: abs, name: name, isDirectory: false)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: kind.symbolName)
                        .font(.system(size: 20))
                        .frame(width: 48, height: 48)
                        .background(RoundedRectangle(cornerRadius: 12).fill(DiskMapTheme.ink.opacity(0.08)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
                        Text(ByteFormat.string(size))
                            .font(.system(size: 22, weight: .semibold).monospacedDigit())
                        Text("\(kind.title) · \(String(format: "%.1f%%", min(100, Double(size) / Double(usedDenominator) * 100))) of used")
                            .font(.system(size: 11))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                }
                meta("Location", CanonicalPath.parentDisplay(of: abs))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Why is it large?").font(.system(size: 12, weight: .semibold))
                    Text(FileKind.whyLarge(kind: kind, name: name))
                        .font(.system(size: 12))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.93, green: 0.95, blue: 0.99)))

                VStack(spacing: 8) {
                    if safety.level != .protected {
                        Button(model.isStaged(URL(fileURLWithPath: abs)) ? "Open Cleanup Queue" : "Add to Cleanup") {
                            Task { await stage() }
                        }
                        .buttonStyle(PrimaryCTAStyle(fullWidth: true))
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: abs)])
                    }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                    Button("Open Containing Folder") {
                        let parent = (abs as NSString).deletingLastPathComponent
                        // Jump File Browser to parent when possible
                        model.destination = .fileBrowser
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: abs)])
                        _ = parent
                    }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(CanonicalPath.displayPath(absolutePath: abs), forType: .string)
                        model.showToast("Path copied")
                    }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                }
            }
            .padding(16)
        }
    }

    private func meta(_ l: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(l).font(.system(size: 10, weight: .semibold)).foregroundStyle(DiskMapTheme.mutedLabel)
            Text(v).font(.system(size: 12))
        }
    }

    private func stage() async {
        let url = URL(fileURLWithPath: abs).standardizedFileURL
        let result = await model.stageForCleanup([
            CleanupStageRequest(url: url, size: size, reason: "Visualize: " + name)
        ])
        model.showToast(result.added > 0 ? "Added to Cleanup" : (result.rejected > 0 ? "Blocked by safety rules" : "Already in Cleanup"))
        if result.added > 0 || result.alreadyPresent > 0 { onOpenCleanup() }
    }
}
