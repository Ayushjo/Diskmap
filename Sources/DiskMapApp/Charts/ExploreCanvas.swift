import AppKit
import DiskMapCore
import SwiftUI

/// The chart canvas Visualize shows: one view per mode, sharing selection.
struct ExploreCanvas: View {
    @ObservedObject var model: ScanModel
    let tree: FileTree
    let totals: [Int64]
    let rootURL: URL
    /// When true, Treemap omits its internal breadcrumb (VisualizeView owns chrome).
    var hideTreemapChrome: Bool = false

    private var otherFraction: Double {
        // Map depth slider 1…12 onto a collapse fraction (shallower → more Other).
        let t = (12 - model.depthLevel) / 11
        return max(0.001, 0.002 + t * 0.04)
    }

    /// Space in a chart (TASK-085).
    private func quickLook(_ id: Int32) {
        guard id >= 0, Int(id) < tree.count else { return }
        DiskMapQuickLook.shared.show(tree.path(of: id, root: rootURL))
    }

    /// Clicks in any chart go through `select`, which reads ⌘ and ⇧.
    private var chartSelection: Binding<Int32> {
        Binding(get: { model.selectedNode }, set: { model.select($0) })
    }

    var body: some View {
        Group {
            switch model.exploreMode {
            case .treemap:
                ExploreTreemapView(
                    tree: tree,
                    totals: totals,
                    currentNode: $model.currentNode,
                    selectedNode: chartSelection,
                    colorMode: model.colorMode,
                    categories: model.fileTypeCategories,
                    showInlineChrome: !hideTreemapChrome,
                    onQuickLook: quickLook,
                    onAddToSelection: { model.select($0, modifiers: .command) }
                )
                .onChange(of: model.currentNode) { _, v in model.selectedNode = v }
            case .sunburst:
                LayoutChartView(kind: .sunburst, tree: tree, totals: totals, currentNode: $model.currentNode, selectedNode: chartSelection, otherFraction: otherFraction, colorMode: model.colorMode, categories: model.fileTypeCategories, onQuickLook: quickLook, onAddToSelection: { model.select($0, modifiers: .command) })
                    .onChange(of: model.currentNode) { _, v in model.selectedNode = v }
            case .flame:
                LayoutChartView(kind: .flame, tree: tree, totals: totals, currentNode: $model.currentNode, selectedNode: chartSelection, otherFraction: otherFraction, colorMode: model.colorMode, categories: model.fileTypeCategories, onQuickLook: quickLook, onAddToSelection: { model.select($0, modifiers: .command) })
                    .onChange(of: model.currentNode) { _, v in model.selectedNode = v }
            case .bubbles:
                LayoutChartView(kind: .bubbles, tree: tree, totals: totals, currentNode: $model.currentNode, selectedNode: chartSelection, otherFraction: otherFraction, colorMode: model.colorMode, categories: model.fileTypeCategories, onQuickLook: quickLook, onAddToSelection: { model.select($0, modifiers: .command) })
                    .onChange(of: model.currentNode) { _, v in model.selectedNode = v }
            case .mindMap:
                LayoutChartView(kind: .mindMap, tree: tree, totals: totals, currentNode: $model.currentNode, selectedNode: chartSelection, otherFraction: otherFraction, colorMode: model.colorMode, categories: model.fileTypeCategories, onQuickLook: quickLook, onAddToSelection: { model.select($0, modifiers: .command) })
                    .onChange(of: model.currentNode) { _, v in model.selectedNode = v }
            case .ageMap:
                AgeMapView(model: model, tree: tree, totals: totals, rootURL: rootURL)
            }
        }
        .environment(\.multiSelection, model.multiSelection)
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
    /// When false, breadcrumbs/size chrome are provided by VisualizeView.
    var showInlineChrome: Bool = true
    var onQuickLook: (Int32) -> Void = { _ in }
    var onAddToSelection: (Int32) -> Void = { _ in }

    @Environment(\.multiSelection) private var multi
    @State private var layoutRects: [TreemapRect] = []
    @State private var canvasSize: CGSize = .zero
    @State private var layoutTask: Task<Void, Never>?
    @State private var isPreparingLayout = false
    @State private var hoveredID: Int32?


    var body: some View {
        VStack(spacing: 0) {
            if showInlineChrome {
                HStack {
                    BreadcrumbBar(tree: tree, currentNode: currentNode) { id in
                        currentNode = id
                        selectedNode = id
                        cacheLayout()
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: currentSize, countStyle: .file))
                        .foregroundStyle(DiskMapTheme.ink2)
                }
                .padding(8)
            }

            Canvas { context, size in
                for r in layoutRects {
                    // 3 pt gutters, soft rounded tiles, a light top-to-bottom wash.
                    let inset = r.rect.insetBy(dx: 1.5, dy: 1.5)
                    guard inset.width > 0.5, inset.height > 0.5 else { continue }
                    let path = Path(roundedRect: inset, cornerRadius: min(6, min(inset.width, inset.height) / 3), style: .continuous)
                    let selected = r.id == selectedNode || multi.contains(r.id)
                    let hovered = r.id == hoveredID
                    context.fill(path, with: .color(colorFor(id: r.id)))
                    context.fill(path, with: .linearGradient(
                        Gradient(colors: [.white.opacity(hovered ? 0.28 : 0.14), .white.opacity(hovered ? 0.12 : 0)]),
                        startPoint: CGPoint(x: inset.midX, y: inset.minY),
                        endPoint: CGPoint(x: inset.midX, y: inset.maxY)))
                    if selected {
                        context.stroke(path, with: .color(DiskMapTheme.accent), lineWidth: 2)
                    }
                    if inset.width > 52 && inset.height > 22 {
                        context.draw(
                            Text(String(tree.name(of: r.id).prefix(max(4, Int(inset.width / 7) - 3))))
                                .font(.system(size: DiskMapType.scaled(12), weight: .medium))
                                .foregroundStyle(DiskMapTheme.tileLabel.opacity(0.85)),
                            at: CGPoint(x: inset.minX + 8, y: inset.minY + 7),
                            anchor: .topLeading
                        )
                    }
                    if inset.width > 80 && inset.height > 46 {
                        context.draw(Text(ByteFormat.string(totals[Int(r.id)]))
                            .font(DiskMapType.figureSmall).foregroundStyle(DiskMapTheme.tileLabel.opacity(0.6)),
                            at: CGPoint(x: inset.minX + 8, y: inset.minY + 25), anchor: .topLeading)
                    }
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoveredID = SquarifiedTreemap.hitTest(layoutRects, at: point)
                case .ended: hoveredID = nil
                }
            }
            .help(hoveredID.map { "\(tree.name(of: $0)) — \(ByteFormat.string(totals[Int($0)]))" } ?? "")
            .overlay {
                if isPreparingLayout && layoutRects.isEmpty {
                    ProgressView("Preparing map…")
                        .controlSize(.small)
                        .foregroundStyle(DiskMapTheme.ink2)
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
                    if tree.isDirectory[Int(hit)] {
                        currentNode = hit   // the shell selects the opened folder
                        cacheLayout()
                    } else {
                        selectedNode = hit
                    }
                }
            )
            .simultaneousGesture(
                SpatialTapGesture().onEnded { event in
                    guard let hit = SquarifiedTreemap.hitTest(layoutRects, at: event.location) else { return }
                    selectedNode = hit
                }
            )
            .chartAccessibility(
                "Treemap of \(currentNode >= 0 && Int(currentNode) < tree.count ? tree.name(of: currentNode) : "this folder")",
                entries: ChartAccessibility.entries(
                    layoutRects.map { .init(id: $0.id, name: tree.name(of: $0.id), size: totals[Int($0.id)],
                                            drillable: tree.isDirectory[Int($0.id)]) },
                    total: currentSize, format: ByteFormat.string),
                frame: { id in layoutRects.first { $0.id == id }?.rect },
                select: { selectedNode = $0 },
                open: { id in
                    currentNode = id
                    cacheLayout()
                }
            )
            .chartKeyboard(
                move: { direction in
                    let tiles = layoutRects.map { (id: $0.id, rect: $0.rect) }
                    let from: Int32? = tiles.contains { $0.id == selectedNode } ? selectedNode : nil
                    let next = ChartNavigation.neighbor(of: from, toward: direction, in: tiles)
                    if let next { selectedNode = next }
                },
                open: {
                    guard layoutRects.contains(where: { $0.id == selectedNode }), tree.isDirectory[Int(selectedNode)] else { return }
                    currentNode = selectedNode
                    cacheLayout()
                },
                enclosing: {
                    guard currentNode > 0 else { return }
                    currentNode = tree.parent[Int(currentNode)]
                    cacheLayout()
                },
                quickLook: { onQuickLook(selectedNode) },
                addToSelection: { onAddToSelection(selectedNode) }
            )
        }
        .onChange(of: currentNode) { _, _ in cacheLayout() }
        .onChange(of: totals.count) { _, _ in cacheLayout() }
        .onDisappear { layoutTask?.cancel() }
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
        let node = currentNode
        let targetSize = canvasSize
        let sourceTree = tree
        let sourceTotals = totals
        layoutTask?.cancel()
        isPreparingLayout = true
        layoutTask = Task.detached(priority: .userInitiated) {
            let items = sourceTree.children(of: node, totals: sourceTotals).filter { $0.size > 0 }
            guard !Task.isCancelled else { return }
            let rects = SquarifiedTreemap.layout(
                items: items,
                in: CGRect(origin: .zero, size: targetSize)
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard currentNode == node, canvasSize == targetSize else { return }
                layoutRects = rects
                isPreparingLayout = false
            }
        }
    }

    private func colorFor(id: Int32) -> Color {
        ExploreColoring.color(for: id, in: tree, mode: colorMode, categories: categories)
    }
}
