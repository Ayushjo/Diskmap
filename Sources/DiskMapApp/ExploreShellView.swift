import AppKit
import DiskMapCore
import SwiftUI

/// Persistent 3-panel Explore shell. View-modes swap only the center canvas.
struct ExploreShellView: View {
    @ObservedObject var model: ScanModel
    var pickFolder: () -> Void
    @State private var showCleanup = false

    var body: some View {
        HStack(spacing: 0) {
            ExploreSidebar(model: model, pickFolder: pickFolder)
                .frame(width: 280)
            Divider()
            center
            Divider()
            ExploreInspector(model: model, showCleanup: $showCleanup)
                .frame(width: 300)
                .background(DiskMapTheme.inspectorFill)
        }
        .background(DiskMapTheme.cream)
        .sheet(isPresented: $showCleanup) {
            CleanupQueueView(model: model)
                .frame(minWidth: 640, minHeight: 480)
        }
    }

    @ViewBuilder
    private var center: some View {
        if model.isScanning {
            VStack(spacing: 12) {
                ProgressView()
                Text("Scanning… \(model.scannedCount) items")
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let tree = model.tree, let root = model.rootURL,
                  model.selectedTotals.count == tree.count {
            VStack(spacing: 0) {
                viewPickerRow
                ExploreCanvas(
                    model: model,
                    tree: tree,
                    totals: model.selectedTotals,
                    rootURL: root
                )
            }
        } else {
            VStack(spacing: 16) {
                Text("Pick a folder to explore")
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                Button("Scan Full Mac") {
                    Task { await model.scan(URL(fileURLWithPath: "/", isDirectory: true)) }
                }
                .buttonStyle(InkButtonStyle())
                Button("Choose Folder…", action: pickFolder)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var viewPickerRow: some View {
        HStack(spacing: 8) {
            ForEach(ExploreViewMode.allCases) { mode in
                Button {
                    model.exploreMode = mode
                } label: {
                    Image(systemName: mode.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(model.exploreMode == mode ? Color.white : DiskMapTheme.mutedLabel)
                        .frame(width: 30, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(model.exploreMode == mode ? DiskMapTheme.ink : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help(mode.rawValue)
                .accessibilityIdentifier("explore-mode-\(mode.rawValue)")
            }
            Text(model.exploreMode.blurb)
                .font(.system(size: 12))
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .lineLimit(1)
            Spacer(minLength: 8)
            if model.exploreMode.showsLayoutControls {
                Picker("", selection: $model.colorMode) {
                    ForEach(ExploreColorMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                HStack(spacing: 6) {
                    Slider(value: $model.depthLevel, in: 1...12, step: 1)
                        .frame(width: 100)
                    Text("\(Int(model.depthLevel))")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(DiskMapTheme.ink)
                        .frame(width: 20, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct InkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DiskMapTheme.ink))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct ExploreSidebar: View {
    @ObservedObject var model: ScanModel
    var pickFolder: () -> Void

    private var volume: VolumeStats? {
        VolumeStats.forPath(model.rootURL?.path ?? NSHomeDirectory())
    }

    private var quickWins: [QuickWins.Hit] {
        guard let tree = model.tree, let root = model.rootURL,
              model.allocatedTotals.count == tree.count else { return [] }
        let patterns = QuickWins.bundledPatterns()
        return QuickWins.find(in: tree, root: root, patterns: patterns)
    }

    private var fileTypes: [FileTypeTotals] {
        guard let tree = model.tree, model.allocatedTotals.count == tree.count else { return [] }
        return FileTypeCatalog.totals(in: tree, sizes: model.allocatedTotals, categories: model.fileTypeCategories)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button("Scan Full Mac") {
                    Task { await model.scan(URL(fileURLWithPath: "/", isDirectory: true)) }
                }
                .buttonStyle(InkButtonStyle())
                .frame(maxWidth: .infinity)

                HStack(spacing: 8) {
                    Button("Home") {
                        Task { await model.scan(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) }
                    }
                    .buttonStyle(.bordered)
                    Button("Folder…", action: pickFolder)
                        .buttonStyle(.bordered)
                }

                sectionRecent
                sectionDisk
                sectionCurrent
                sectionQuickWins
                sectionFileTypes
            }
            .padding(14)
        }
        .background(DiskMapTheme.cream)
    }

    private var sectionRecent: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: "Recent")
            if model.recentRoots.isEmpty {
                Text("No recent scans")
                    .font(.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            } else {
                ForEach(model.recentRoots.prefix(6), id: \.path) { url in
                    Button {
                        Task { await model.scan(url) }
                    } label: {
                        Label(url.lastPathComponent, systemImage: "clock")
                            .font(.system(size: 12))
                            .foregroundStyle(DiskMapTheme.ink)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var sectionDisk: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Disk Storage")
            if let volume {
                PanelCard {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .stroke(DiskMapTheme.cardStroke, lineWidth: 8)
                            Circle()
                                .trim(from: 0, to: volume.usedFraction)
                                .stroke(DiskMapTheme.ink, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text(String(format: "%.0f%%", volume.usedFraction * 100))
                                .font(.system(size: 11, weight: .bold))
                        }
                        .frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(volume.volumeName).font(.system(size: 13, weight: .semibold))
                            Text("Total \(byte(volume.totalBytes))")
                            Text("Used \(byte(volume.usedBytes))")
                            Text("Free \(byte(volume.freeBytes))")
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(DiskMapTheme.ink)
                    }
                }
            }
        }
    }

    private var sectionCurrent: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: "Current View")
            PanelCard {
                VStack(alignment: .leading, spacing: 4) {
                    if let tree = model.tree, model.currentNode < tree.count {
                        Text(tree.name(of: model.currentNode))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DiskMapTheme.ink)
                        if let root = model.rootURL {
                            Text(tree.path(of: model.currentNode, root: root).path)
                                .font(.system(size: 10))
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                                .lineLimit(2)
                        }
                    } else {
                        Text("No scan yet").foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                    if let secs = model.lastScanSeconds {
                        Text(String(format: "Last scan %.1fs", secs))
                            .font(.caption)
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                }
            }
        }
    }

    private var sectionQuickWins: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: "Quick Wins")
            let hits = quickWins
            if hits.isEmpty {
                Text("Scan to see regenerable folders")
                    .font(.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            } else {
                ForEach(hits.prefix(8), id: \.id) { hit in
                    Button {
                        model.selectedNode = hit.id
                        model.currentNode = model.tree?.parent[Int(hit.id)] ?? 0
                    } label: {
                        HStack {
                            Image(systemName: "bolt.fill").foregroundStyle(DiskMapTheme.ink.opacity(0.7))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(hit.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(DiskMapTheme.ink)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if model.tree != nil, Int(hit.id) < model.allocatedTotals.count {
                                Text(byte(UInt64(max(0, model.allocatedTotals[Int(hit.id)]))))
                                    .font(.system(size: 11).monospacedDigit())
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var sectionFileTypes: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: "File Types")
            let rows = fileTypes
            if rows.isEmpty {
                Text("Scan to classify files")
                    .font(.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            } else {
                let total = max(1, rows.reduce(Int64(0)) { $0 + $1.bytes })
                PanelCard {
                    VStack(alignment: .leading, spacing: 8) {
                        GeometryReader { geo in
                            HStack(spacing: 1) {
                                ForEach(rows, id: \.categoryID) { row in
                                    DiskMapTheme.hex(row.colorHex)
                                        .frame(width: geo.size.width * CGFloat(row.bytes) / CGFloat(total))
                                }
                            }
                        }
                        .frame(height: 10)
                        .clipShape(Capsule())
                        ForEach(rows, id: \.categoryID) { row in
                            HStack(spacing: 8) {
                                Circle().fill(DiskMapTheme.hex(row.colorHex)).frame(width: 8, height: 8)
                                Text(row.label)
                                    .font(.system(size: 11))
                                    .foregroundStyle(DiskMapTheme.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(byte(UInt64(row.bytes)))
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(DiskMapTheme.mutedLabel)
                            }
                        }
                    }
                }
            }
        }
    }

    private func byte(_ v: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .file)
    }
}

struct ExploreInspector: View {
    @ObservedObject var model: ScanModel
    @Binding var showCleanup: Bool

    var body: some View {
        Group {
            if let tree = model.tree, let root = model.rootURL,
               model.selectedTotals.count == tree.count,
               model.selectedNode >= 0, Int(model.selectedNode) < tree.count {
                inspector(tree: tree, root: root, id: model.selectedNode)
            } else {
                Text("Select an item")
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func inspector(tree: FileTree, root: URL, id: Int32) -> some View {
        let idx = Int(id)
        let logical = model.logicalTotals.indices.contains(idx) ? model.logicalTotals[idx] : 0
        let onDisk = model.allocatedTotals.indices.contains(idx) ? model.allocatedTotals[idx] : 0
        let active = model.sizeBasis == .logical ? logical : onDisk
        let compressed = max(0, logical - onDisk)
        let scanTotal = model.selectedTotals.first ?? 0
        let parentID = tree.parent[idx]
        let parentSize = parentID >= 0 && Int(parentID) < model.selectedTotals.count ? model.selectedTotals[Int(parentID)] : scanTotal
        let ofParent = parentSize > 0 ? Double(active) / Double(parentSize) : 0
        let ofScan = scanTotal > 0 ? Double(active) / Double(scanTotal) : 0
        let children = tree.children(of: id, totals: model.selectedTotals).sorted { $0.size > $1.size }
        let fileCount = countFiles(tree: tree, id: id)
        let folderCount = countFolders(tree: tree, id: id)
        let day = tree.modifiedDay[idx]
        let created = tree.createdDay[idx]

        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: tree.isDirectory[idx] ? "folder.fill" : "doc")
                        .font(.title2)
                        .foregroundStyle(DiskMapTheme.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tree.name(of: id))
                            .font(.headline)
                            .foregroundStyle(DiskMapTheme.ink)
                        Text(tree.isDirectory[idx] ? "Folder" : "File")
                            .font(.caption)
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                        Text(tree.path(of: id, root: root).path)
                            .font(.system(size: 10))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                            .textSelection(.enabled)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(byte(active))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(DiskMapTheme.ink)
                    Text(id == 0 ? String(format: "%.1f%% of scan", ofScan * 100) : String(format: "%.1f%% of parent", ofParent * 100))
                        .font(.caption)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }

                PanelCard {
                    VStack(spacing: 6) {
                        StatRow(label: "Size on disk", value: byte(onDisk))
                        StatRow(label: "Logical size", value: byte(logical))
                        StatRow(label: "Compressed by", value: byte(compressed), emphasize: compressed > 0)
                        StatRow(label: "Files", value: "\(fileCount)")
                        StatRow(label: "Folders", value: "\(folderCount)")
                        if id != 0 {
                            StatRow(label: "Of parent", value: String(format: "%.1f%%", ofParent * 100))
                        }
                        StatRow(label: "Modified", value: relativeDay(day))
                        StatRow(label: "Created", value: relativeDay(created))
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Largest Inside")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                    PanelCard {
                        VStack(spacing: 8) {
                            ForEach(Array(children.prefix(8).enumerated()), id: \.element.id) { _, child in
                                let frac = active > 0 ? Double(child.size) / Double(active) : 0
                                Button {
                                    model.selectedNode = child.id
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(tree.name(of: child.id))
                                                .font(.system(size: 12))
                                                .foregroundStyle(DiskMapTheme.ink)
                                                .lineLimit(1)
                                            Spacer()
                                            Text(byte(child.size))
                                                .font(.system(size: 11).monospacedDigit())
                                                .foregroundStyle(DiskMapTheme.mutedLabel)
                                        }
                                        ProportionBar(fraction: frac)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            if children.isEmpty {
                                Text("No children").font(.caption).foregroundStyle(DiskMapTheme.mutedLabel)
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    actionButton("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([tree.path(of: id, root: root)])
                    }
                    actionButton("Quick Look") {
                        QuickLookPresenter.shared.present(tree.path(of: id, root: root))
                    }
                    actionButton("Focus") {
                        if tree.isDirectory[idx] {
                            model.currentNode = id
                            model.selectedNode = id
                        }
                    }
                    actionButton("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(tree.path(of: id, root: root).path, forType: .string)
                    }
                }

                Button {
                    let url = tree.path(of: id, root: root)
                    let size = model.allocatedTotals[idx]
                    Task {
                        _ = await model.cleanupQueue.stage(url, size: size, reason: "manual")
                        await model.refreshQueue()
                    }
                } label: {
                    Text("Add to Cleanup")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(.white)
                        .background(RoundedRectangle(cornerRadius: 10).fill(DiskMapTheme.ink))
                }
                .buttonStyle(.plain)

                Button("Open Cleanup Queue") { showCleanup = true }
                    .font(.caption)
            }
            .padding(14)
        }
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DiskMapTheme.ink)
            .buttonStyle(.bordered)
            .tint(DiskMapTheme.ink)
    }

    private func byte(_ v: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: v, countStyle: .file)
    }

    private func relativeDay(_ day: Int32) -> String {
        guard day > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: TimeInterval(day) * 86400)
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    private func countFiles(tree: FileTree, id: Int32) -> Int {
        var n = 0
        func walk(_ i: Int32) {
            let index = Int(i)
            if !tree.isDirectory[index] { n += 1 }
            var c = tree.firstChild[index]
            while c != -1 {
                walk(c)
                c = tree.nextSibling[Int(c)]
            }
        }
        walk(id)
        return tree.isDirectory[Int(id)] ? n : (n > 0 ? n : 1)
    }

    private func countFolders(tree: FileTree, id: Int32) -> Int {
        var n = 0
        func walk(_ i: Int32) {
            let index = Int(i)
            if tree.isDirectory[index] && i != id { n += 1 }
            var c = tree.firstChild[index]
            while c != -1 {
                walk(c)
                c = tree.nextSibling[Int(c)]
            }
        }
        if tree.isDirectory[Int(id)] { walk(id) }
        return n
    }
}

struct ExploreCanvas: View {
    @ObservedObject var model: ScanModel
    let tree: FileTree
    let totals: [Int64]
    let rootURL: URL

    private var otherFraction: Double {
        // Map depth slider 1…12 onto a collapse fraction (shallower → more Other).
        let t = (12 - model.depthLevel) / 11
        return max(0.001, 0.002 + t * 0.04)
    }

    var body: some View {
        Group {
            switch model.exploreMode {
            case .treemap:
                ExploreTreemapView(
                    tree: tree,
                    totals: totals,
                    currentNode: $model.currentNode,
                    selectedNode: $model.selectedNode,
                    colorMode: model.colorMode,
                    categories: model.fileTypeCategories
                )
            case .sunburst:
                LayoutChartView(kind: .sunburst, tree: tree, totals: totals, currentNode: $model.currentNode, selectedNode: $model.selectedNode, otherFraction: otherFraction, colorMode: model.colorMode, categories: model.fileTypeCategories)
                    .onChange(of: model.currentNode) { _, v in model.selectedNode = v }
            case .flame:
                LayoutChartView(kind: .flame, tree: tree, totals: totals, currentNode: $model.currentNode, selectedNode: $model.selectedNode, otherFraction: otherFraction, colorMode: model.colorMode, categories: model.fileTypeCategories)
                    .onChange(of: model.currentNode) { _, v in model.selectedNode = v }
            case .bubbles:
                LayoutChartView(kind: .bubbles, tree: tree, totals: totals, currentNode: $model.currentNode, selectedNode: $model.selectedNode, otherFraction: otherFraction, colorMode: model.colorMode, categories: model.fileTypeCategories)
                    .onChange(of: model.currentNode) { _, v in model.selectedNode = v }
            case .mindMap:
                LayoutChartView(kind: .mindMap, tree: tree, totals: totals, currentNode: $model.currentNode, selectedNode: $model.selectedNode, otherFraction: otherFraction, colorMode: model.colorMode, categories: model.fileTypeCategories)
                    .onChange(of: model.currentNode) { _, v in model.selectedNode = v }
            case .topSizes:
                TopSizesView(tree: tree, totals: totals, rootURL: rootURL, selectedNode: $model.selectedNode)
            case .ageMap:
                AgeMapView(model: model, tree: tree, totals: totals, rootURL: rootURL)
            case .folders:
                FoldersView(tree: tree, totals: totals, rootURL: rootURL, currentNode: $model.currentNode, selectedNode: $model.selectedNode)
                    .onChange(of: model.currentNode) { _, v in model.selectedNode = v }
            }
        }
    }
}


/// Treemap canvas with selection + By folder/type/age coloring.
struct ExploreTreemapView: View {
    let tree: FileTree
    let totals: [Int64]
    @Binding var currentNode: Int32
    @Binding var selectedNode: Int32
    var colorMode: ExploreColorMode
    var categories: [FileTypeCategory]

    @State private var layoutRects: [TreemapRect] = []
    @State private var canvasSize: CGSize = .zero


    var body: some View {
        VStack(spacing: 0) {
            HStack {
                BreadcrumbBar(tree: tree, currentNode: currentNode) { id in
                    currentNode = id
                    selectedNode = id
                    cacheLayout()
                }
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: currentSize, countStyle: .file))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
            .padding(8)

            Canvas { context, size in
                let items = tree.children(of: currentNode, totals: totals)
                let rects = SquarifiedTreemap.layout(items: items, in: CGRect(origin: .zero, size: size))
                for r in rects {
                    let inset = r.rect.insetBy(dx: 1, dy: 1)
                    let path = Path(inset)
                    let selected = r.id == selectedNode
                    context.fill(path, with: .color(colorFor(id: r.id)))
                    context.stroke(path, with: .color(selected ? DiskMapTheme.ink : .black.opacity(0.25)), lineWidth: selected ? 2 : 1)
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
                        .onChange(of: proxy.size) { _, s in cacheLayout(in: s) }
                }
            }
            .gesture(
                SpatialTapGesture(count: 2).onEnded { event in
                    guard let hit = SquarifiedTreemap.hitTest(layoutRects, at: event.location) else { return }
                    selectedNode = hit
                    if tree.isDirectory[Int(hit)] {
                        currentNode = hit
                        cacheLayout()
                    }
                }
            )
            .simultaneousGesture(
                SpatialTapGesture().onEnded { event in
                    guard let hit = SquarifiedTreemap.hitTest(layoutRects, at: event.location) else { return }
                    selectedNode = hit
                }
            )
        }
        .onChange(of: currentNode) { _, _ in cacheLayout() }
        .onChange(of: totals) { _, _ in cacheLayout() }
        .onChange(of: colorMode) { _, _ in cacheLayout() }
    }

    private var currentSize: Int64 {
        guard currentNode >= 0, Int(currentNode) < totals.count else { return 0 }
        return totals[Int(currentNode)]
    }

    private func cacheLayout(in size: CGSize? = nil) {
        if let size, size.width > 0, size.height > 0 { canvasSize = size }
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            layoutRects = []
            return
        }
        layoutRects = SquarifiedTreemap.layout(
            items: tree.children(of: currentNode, totals: totals),
            in: CGRect(origin: .zero, size: canvasSize)
        )
    }

    private func colorFor(id: Int32) -> Color {
        ExploreColoring.color(for: id, in: tree, mode: colorMode, categories: categories)
    }
}

