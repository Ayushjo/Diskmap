import DiskMapCore
import SwiftUI

enum LayoutChartKind: String, CaseIterable, Identifiable {
    case sunburst = "Sunburst"
    case flame = "Flame"
    case bubbles = "Bubbles"
    case mindMap = "Mind Map"

    var id: String { rawValue }
}

/// One extra level of `currentNode`'s children. Smaller than 0.5% of the
/// parent is already collapsed into a non-drillable Other by ChartLayout.
struct LayoutChartView: View {
    let kind: LayoutChartKind
    let tree: FileTree
    let totals: [Int64]
    @Binding var currentNode: Int32
    @Binding var selectedNode: Int32
    var otherFraction: Double = ChartLayout.otherFraction
    var colorMode: ExploreColorMode = .folder
    var categories: [FileTypeCategory] = []
    @State private var preparedSlices: [ChartSlice] = []
    @State private var isPreparing = true

    var body: some View {
        VStack(spacing: 0) {

            GeometryReader { proxy in
                if isPreparing {
                    ProgressView("Preparing visualization…")
                        .controlSize(.small)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if preparedSlices.isEmpty {
                    Text("Nothing with a size in this folder")
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    chart(preparedSlices, in: proxy.size)
                }
            }
            .background(DiskMapTheme.cream)
        }
        .background(DiskMapTheme.cream)
        .task(id: preparationID) {
            await prepareSlices()
        }
    }

    private var preparationID: String {
        let size = currentNode >= 0 && Int(currentNode) < totals.count ? totals[Int(currentNode)] : 0
        return "\(currentNode):\(totals.count):\(size):\(otherFraction):\(kind.rawValue)"
    }

    @MainActor
    private func prepareSlices() async {
        guard currentNode >= 0, Int(currentNode) < tree.count, totals.count == tree.count else {
            preparedSlices = []
            isPreparing = false
            return
        }
        isPreparing = true
        let node = currentNode
        let sourceTree = tree
        let sourceTotals = totals
        // The mind map is two fixed levels in a scroll view, so the depth
        // slider's heavier collapsing (up to 4% → a handful of cards) only
        // hides branches; it shows everything ≥ 0.5% of the folder.
        let fraction = kind == .mindMap ? min(otherFraction, ChartLayout.otherFraction) : otherFraction
        let result = await Task.detached(priority: .userInitiated) {
            ChartLayout.slices(of: node, in: sourceTree, totals: sourceTotals, otherFraction: fraction)
        }.value
        guard !Task.isCancelled, currentNode == node else { return }
        preparedSlices = result
        isPreparing = false
    }

    @ViewBuilder
    private func chart(_ slices: [ChartSlice], in size: CGSize) -> some View {
        switch kind {
        case .sunburst:
            SunburstChart(slices: slices, size: size, color: color, selected: selectedNode, select: select, drill: drill)
        case .flame:
            FlameChart(slices: slices, size: size, color: color, selected: selectedNode, select: select, drill: drill)
        case .bubbles:
            BubbleChart(slices: slices, size: size, color: color, selected: selectedNode, select: select, drill: drill)
        case .mindMap:
            MindMapChart(slices: slices, size: size, tree: tree, totals: totals, center: currentNode,
                         color: color, selected: selectedNode, select: select, drill: drill)
        }
    }

    private func color(_ id: Int32?) -> Color {
        guard let id, id >= 0, Int(id) < tree.count else { return DiskMapTheme.mutedLabel.opacity(0.4) }
        return ExploreColoring.color(for: id, in: tree, mode: colorMode, categories: categories)
    }

    private func select(_ id: Int32?) {
        guard let id, id >= 0, Int(id) < tree.count else { return }
        selectedNode = id
    }

    private func drill(_ id: Int32?) {
        guard let id, id >= 0, Int(id) < tree.count else { return }
        selectedNode = id
        guard tree.isDirectory[Int(id)] else { return }
        currentNode = id
    }
}

private struct SunburstChart: View {
    let slices: [ChartSlice]
    let size: CGSize
    let color: (Int32?) -> Color
    let selected: Int32
    let select: (Int32?) -> Void
    let drill: (Int32?) -> Void

    var body: some View {
        let layout = sunburstLayout(slices, in: size)
        Canvas { context, _ in
            for wedge in layout {
                let path = wedgePath(wedge)
                let isSel = wedge.nodeID == selected
                context.fill(path, with: .color(color(wedge.nodeID)))
                context.stroke(path, with: .color(isSel ? DiskMapTheme.tileLabel : .black.opacity(0.25)), lineWidth: isSel ? 2 : 1)
                let sweep = wedge.end - wedge.start
                if sweep > 0.14, wedge.outer - wedge.inner > 22 {
                    let mid = (wedge.start + wedge.end) / 2
                    let radius = (wedge.inner + wedge.outer) / 2
                    let capacity = min(18, max(3, Int(min(sweep * radius, wedge.outer - wedge.inner) / 6)))
                    let short = wedge.label.count > capacity ? String(wedge.label.prefix(capacity - 1)) + "…" : wedge.label
                    context.draw(
                        Text(short).font(.caption2.weight(.semibold)).foregroundStyle(DiskMapTheme.tileLabel),
                        at: polarPoint(center: wedge.center, angle: mid, radius: radius)
                    )
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture(count: 2).onEnded { value in
            drill(hit(layout, at: value.location))
        })
        .simultaneousGesture(SpatialTapGesture().onEnded { value in
            select(hit(layout, at: value.location))
        })
    }
}

private struct FlameChart: View {
    let slices: [ChartSlice]
    let size: CGSize
    let color: (Int32?) -> Color
    let selected: Int32
    let select: (Int32?) -> Void
    let drill: (Int32?) -> Void

    var body: some View {
        let bars = flameBars(slices, in: size)
        Canvas { context, _ in
            for bar in bars {
                let path = Path(bar.rect.insetBy(dx: 0.5, dy: 0.5))
                let isSel = bar.nodeID == selected
                context.fill(path, with: .color(color(bar.nodeID)))
                context.stroke(path, with: .color(isSel ? DiskMapTheme.tileLabel : .black.opacity(0.25)), lineWidth: isSel ? 2 : 1)
                if bar.rect.width > 56 && bar.rect.height > 18 {
                    let capacity = max(3, Int((bar.rect.width - 14) / 6))
                    let short = bar.label.count > capacity ? String(bar.label.prefix(capacity - 1)) + "…" : bar.label
                    context.draw(
                        Text(short).font(.caption2.weight(.semibold)).foregroundStyle(DiskMapTheme.tileLabel),
                        at: CGPoint(x: bar.rect.minX + 6, y: bar.rect.midY),
                        anchor: .leading
                    )
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture(count: 2).onEnded { value in
            drill(bars.first { $0.rect.contains(value.location) }?.nodeID)
        })
        .simultaneousGesture(SpatialTapGesture().onEnded { value in
            select(bars.first { $0.rect.contains(value.location) }?.nodeID)
        })
    }
}

private struct BubbleChart: View {
    let slices: [ChartSlice]
    let size: CGSize
    let color: (Int32?) -> Color
    let selected: Int32
    let select: (Int32?) -> Void
    let drill: (Int32?) -> Void

    @State private var packed: [PackedCircle] = []

    private var circles: [DrawnCircle] { placedCircles(slices, packed: packed, in: size) }

    var body: some View {
        let circles = circles
        Canvas { context, _ in
            for circle in circles {
                let rect = CGRect(
                    x: circle.center.x - circle.radius,
                    y: circle.center.y - circle.radius,
                    width: circle.radius * 2,
                    height: circle.radius * 2
                )
                let path = Path(ellipseIn: rect)
                let isSel = circle.nodeID == selected
                let base = color(circle.nodeID)
                // Containers slightly washed so children read on top.
                let fill = DiskMapTheme.wash(base, strength: circle.isContainer ? 0.55 : 0.92)
                context.fill(path, with: .color(fill))
                context.stroke(
                    path,
                    with: .color(isSel ? DiskMapTheme.tileLabel : DiskMapTheme.tileLabel.opacity(0.18)),
                    lineWidth: isSel ? 2.5 : 1
                )
                if circle.radius > (circle.isContainer ? 60 : 28) {
                    let maxChars = max(4, Int(circle.radius / 4.5))
                    let short = circle.label.count > maxChars
                        ? String(circle.label.prefix(maxChars - 1)) + "…"
                        : circle.label
                    let fontSize: CGFloat = circle.radius > 48 ? 11 : 9
                    context.draw(
                        Text(short)
                            .font(.system(size: fontSize, weight: .semibold))
                            .foregroundStyle(DiskMapTheme.tileLabel.opacity(0.9)),
                        at: CGPoint(x: circle.center.x, y: circle.center.y - (circle.isContainer ? circle.radius * 0.72 : 0))
                    )
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture(count: 2).onEnded { value in
            // Smallest containing circle wins (deepest child).
            let hit = circles
                .filter { hypot($0.center.x - value.location.x, $0.center.y - value.location.y) <= $0.radius }
                .min(by: { $0.radius < $1.radius })
            drill(hit?.nodeID)
        })
        .simultaneousGesture(SpatialTapGesture().onEnded { value in
            // Smallest containing circle wins (deepest child).
            let hit = circles
                .filter { hypot($0.center.x - value.location.x, $0.center.y - value.location.y) <= $0.radius }
                .min(by: { $0.radius < $1.radius })
            select(hit?.nodeID)
        })
        .task(id: slices) {
            let input = slices
            let worker = Task.detached(priority: .userInitiated) {
                CirclePack.pack(input)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            packed = result
        }

    }
}

/// The folder in the middle, its biggest branches as cards, and inside each
/// card that branch's own biggest items. Every number is the folder's real
/// rolled-up total; "+N more" says how many items and how many bytes it
/// stands for; lines are drawn from where the cards actually are.
private struct MindMapChart: View {
    let slices: [ChartSlice]
    let size: CGSize
    let tree: FileTree
    let totals: [Int64]
    let center: Int32
    let color: (Int32?) -> Color
    let selected: Int32
    let select: (Int32?) -> Void
    let drill: (Int32?) -> Void

    @State private var showSmaller = false

    private var centerTotal: Int64 {
        Int(center) < totals.count ? totals[Int(center)] : slices.reduce(0) { $0 + $1.size }
    }

    private var columns: Int { size.width >= 760 ? 3 : size.width >= 500 ? 2 : 1 }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                centerCard
                    .anchorPreference(key: MindMapAnchors.self, value: .bounds) { ["center": $0] }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20, alignment: .top), count: columns),
                          alignment: .center, spacing: 22) {
                    ForEach(slices) { slice in
                        Group {
                            if slice.nodeID == nil {
                                smallerCard(slice)
                            } else {
                                branchCard(slice)
                            }
                        }
                        .anchorPreference(key: MindMapAnchors.self, value: .bounds) { [slice.id: $0] }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .backgroundPreferenceValue(MindMapAnchors.self) { anchors in
                GeometryReader { proxy in connectors(anchors: anchors, proxy: proxy) }
            }
        }
    }

    private var centerCard: some View {
        VStack(spacing: 5) {
            Label(tree.name(of: center), systemImage: "folder.fill")
                .font(DiskMapType.section)
                .lineLimit(1).help(tree.name(of: center))
            Text("\(ByteFormat.string(centerTotal)) · \(slices.reduce(0) { $0 + $1.collapsedCount }.formatted()) items")
                .font(DiskMapType.small).monospacedDigit()
                .foregroundStyle(DiskMapTheme.mutedLabel)
        }
        .padding(14)
        .frame(maxWidth: 300)
        .background(DiskMapTheme.cardFill, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DiskMapTheme.cardStroke))
    }

    private func branchCard(_ slice: ChartSlice) -> some View {
        let shown = slice.children.prefix(4)
        let hidden = slice.children.dropFirst(4)
        return VStack(alignment: .leading, spacing: 10) {
            nodeRow(slice, primary: true, parentSize: centerTotal)
            if !slice.children.isEmpty {
                Divider()
                ForEach(shown) { child in
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(DiskMapType.micro).foregroundStyle(DiskMapTheme.mutedLabel)
                            .accessibilityHidden(true)
                        nodeRow(child, primary: false, parentSize: slice.size)
                    }
                }
                if !hidden.isEmpty {
                    let count = hidden.reduce(0) { $0 + $1.collapsedCount }
                    let bytes = hidden.reduce(Int64(0)) { $0 + $1.size }
                    Button { drill(slice.nodeID) } label: {
                        Text("+ \(count.formatted()) more · \(ByteFormat.string(bytes)) — open \(slice.label)")
                            .font(DiskMapType.caption)
                            .foregroundStyle(DiskMapTheme.info)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .help("Explore everything inside \(slice.label)")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiskMapTheme.cardFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color(slice.nodeID).opacity(slice.nodeID == selected ? 0.9 : 0.45),
                                                          lineWidth: slice.nodeID == selected ? 2 : 1))
    }

    /// Everything under 0.5% of the folder, folded into one card — which can
    /// list them, so nothing is hidden without a way to see it.
    private func smallerCard(_ slice: ChartSlice) -> some View {
        let visibleIDs = Set(slices.compactMap(\.nodeID))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.down.right")
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.smallerItems(slice.collapsedCount))
                        .font(.system(size: 13, weight: .medium))
                    Text("\(ByteFormat.string(slice.size)) · \(percent(slice.size, of: centerTotal)) · each under 0.5%")
                        .font(DiskMapType.caption).monospacedDigit()
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
                Spacer(minLength: 0)
                Button(showSmaller ? "Hide" : "Show") { showSmaller.toggle() }
                    .buttonStyle(.link)
                    .font(DiskMapType.captionStrong)
            }
            if showSmaller {
                Divider()
                let items = tree.children(of: center, totals: totals)
                    .filter { !visibleIDs.contains($0.id) && $0.size > 0 }
                    .sorted { $0.size > $1.size }
                ForEach(items.prefix(12), id: \.id) { item in
                    let row = ChartSlice(id: "small.\(item.id)", nodeID: item.id, size: item.size, label: tree.name(of: item.id),
                                         drillable: tree.isDirectory[Int(item.id)], children: [])
                    nodeRow(row, primary: false, parentSize: centerTotal)
                }
                if items.count > 12 {
                    Text("and \((items.count - 12).formatted()) more · \(ByteFormat.string(items.dropFirst(12).reduce(0) { $0 + $1.size }))")
                        .font(DiskMapType.caption)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiskMapTheme.cardFill.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DiskMapTheme.cardStroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    static func smallerItems(_ count: Int) -> String {
        count == 1 ? "1 smaller item" : "\(count.formatted()) smaller items"
    }

    private func percent(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0 else { return "—" }
        let value = Double(part) / Double(whole) * 100
        if part > 0, value < 0.01 { return "<0.01%" }
        return value >= 10 ? "\(Int(value.rounded()))%" : String(format: value >= 1 ? "%.1f%%" : "%.2f%%", value)
    }

    private func nodeRow(_ slice: ChartSlice, primary: Bool, parentSize: Int64) -> some View {
        let isGroup = slice.nodeID == nil
        let title = isGroup ? Self.smallerItems(slice.collapsedCount) : slice.label
        return HStack(spacing: 6) {
            Button { select(slice.nodeID) } label: {
                HStack(spacing: 8) {
                    Image(systemName: isGroup ? "square.stack.3d.down.right" : slice.drillable ? "folder.fill" : "doc.fill")
                        .foregroundStyle(isGroup ? DiskMapTheme.mutedLabel : color(slice.nodeID))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: primary ? 13 : 12, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                        Text("\(ByteFormat.string(slice.size)) · \(percent(slice.size, of: parentSize))")
                            .font(DiskMapType.caption).monospacedDigit()
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                    Spacer(minLength: 0)
                }
                .padding(4).contentShape(Rectangle())
                .background(slice.nodeID == selected && !isGroup ? DiskMapTheme.ink.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain).disabled(isGroup).help(title)
            .accessibilityLabel("\(title), \(ByteFormat.string(slice.size)), \(percent(slice.size, of: parentSize)) of its folder")
            if slice.drillable {
                Button { drill(slice.nodeID) } label: {
                    Image(systemName: "chevron.right").font(DiskMapType.captionStrong)
                        .frame(width: 24, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Explore \(slice.label)")
                .accessibilityLabel("Explore \(slice.label)")
            }
        }
    }

    /// Centre → a horizontal bus above each row of cards, a trunk down the
    /// left gutter joining the rows, and a coloured stub into every card.
    private func connectors(anchors: [String: Anchor<CGRect>], proxy: GeometryProxy) -> some View {
        let cards = slices.compactMap { slice in anchors[slice.id].map { (slice: slice, rect: proxy[$0]) } }
        var rows: [[(slice: ChartSlice, rect: CGRect)]] = []
        for card in cards.sorted(by: { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }) {
            if let last = rows.last?.first, abs(last.rect.minY - card.rect.minY) < 4 {
                rows[rows.count - 1].append(card)
            } else {
                rows.append([card])
            }
        }
        let centerRect = anchors["center"].map { proxy[$0] }
        let trunkX = (cards.map(\.rect.minX).min() ?? 0) - 12
        return Canvas { context, _ in
            guard let centerRect, let firstRow = rows.first else { return }
            let stroke = DiskMapTheme.cardStroke
            let busY = { (row: [(slice: ChartSlice, rect: CGRect)]) in (row.first?.rect.minY ?? 0) - 11 }
            var spine = Path()
            spine.move(to: CGPoint(x: centerRect.midX, y: centerRect.maxY))
            spine.addLine(to: CGPoint(x: centerRect.midX, y: busY(firstRow)))
            for (index, row) in rows.enumerated() {
                let y = busY(row)
                let left = rows.count > 1 ? trunkX : min(row.first?.rect.midX ?? centerRect.midX, centerRect.midX)
                let right = max(row.last?.rect.midX ?? centerRect.midX, index == 0 ? centerRect.midX : 0)
                spine.move(to: CGPoint(x: left, y: y))
                spine.addLine(to: CGPoint(x: right, y: y))
            }
            if rows.count > 1, let lastRow = rows.last {
                spine.move(to: CGPoint(x: trunkX, y: busY(firstRow)))
                spine.addLine(to: CGPoint(x: trunkX, y: busY(lastRow)))
            }
            context.stroke(spine, with: .color(stroke), lineWidth: 1)
            for row in rows {
                for card in row {
                    var stub = Path()
                    stub.move(to: CGPoint(x: card.rect.midX, y: busY(row)))
                    stub.addLine(to: CGPoint(x: card.rect.midX, y: card.rect.minY))
                    let tint = card.slice.nodeID == nil ? stroke : color(card.slice.nodeID).opacity(0.6)
                    context.stroke(stub, with: .color(tint), lineWidth: 2)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct MindMapAnchors: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct Wedge {
    var nodeID: Int32?
    var label: String
    var center: CGPoint
    var start: Double
    var end: Double
    var inner: CGFloat
    var outer: CGFloat
}

private struct DrawnCircle: Sendable {
    var nodeID: Int32?
    var label: String
    var center: CGPoint
    var radius: CGFloat
    var isContainer: Bool
}

private struct FlameBar {
    var nodeID: Int32?
    var label: String
    var rect: CGRect
}

private func polarPoint(center: CGPoint, angle: Double, radius: CGFloat) -> CGPoint {
    CGPoint(
        x: center.x + CGFloat(Darwin.cos(angle)) * radius,
        y: center.y + CGFloat(Darwin.sin(angle)) * radius
    )
}

private func sunburstLayout(_ slices: [ChartSlice], in size: CGSize) -> [Wedge] {
    let total = slices.reduce(Int64(0)) { $0 + $1.size }
    guard total > 0, size.width > 8, size.height > 8 else { return [] }
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    let radius = min(size.width, size.height) / 2 - 8
    let hole = radius * 0.22
    let mid = hole + (radius - hole) * 0.42
    var angle = -Double.pi / 2
    var wedges: [Wedge] = []
    for slice in slices {
        let sweep = Double(slice.size) / Double(total) * 2 * .pi
        wedges.append(Wedge(nodeID: slice.nodeID, label: slice.label, center: center, start: angle, end: angle + sweep, inner: hole, outer: mid))
        let nestedTotal = slice.children.reduce(Int64(0)) { $0 + $1.size }
        if nestedTotal > 0 {
            var childAngle = angle
            for child in slice.children {
                let childSweep = sweep * Double(child.size) / Double(nestedTotal)
                wedges.append(Wedge(
                    nodeID: child.nodeID,
                    label: child.label,
                    center: center,
                    start: childAngle,
                    end: childAngle + childSweep,
                    inner: mid,
                    outer: radius
                ))
                childAngle += childSweep
            }
        }
        angle += sweep
    }
    return wedges
}

private func wedgePath(_ wedge: Wedge) -> Path {
    let steps = max(8, Int((wedge.end - wedge.start) / 0.08))
    var path = Path()
    for step in 0...steps {
        let t = wedge.start + (wedge.end - wedge.start) * Double(step) / Double(steps)
        let point = polarPoint(center: wedge.center, angle: t, radius: wedge.outer)
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    for step in (0...steps).reversed() {
        let t = wedge.start + (wedge.end - wedge.start) * Double(step) / Double(steps)
        path.addLine(to: polarPoint(center: wedge.center, angle: t, radius: wedge.inner))
    }
    path.closeSubpath()
    return path
}

private func hit(_ wedges: [Wedge], at point: CGPoint) -> Int32? {
    for wedge in wedges.reversed() {
        let dx = point.x - wedge.center.x
        let dy = point.y - wedge.center.y
        let radius = hypot(dx, dy)
        guard radius >= wedge.inner, radius <= wedge.outer else { continue }
        var angle = atan2(dy, dx)
        let start = wedge.start
        while angle < start { angle += 2 * .pi }
        var end = wedge.end
        while end < start { end += 2 * .pi }
        if angle <= end { return wedge.nodeID }
    }
    return nil
}

private func flameBars(_ slices: [ChartSlice], in size: CGSize) -> [FlameBar] {
    let ordered = slices.sorted { $0.size > $1.size }
    let total = ordered.reduce(Int64(0)) { $0 + $1.size }
    guard total > 0, size.width > 0, size.height > 0 else { return [] }
    let row = size.height / 2
    var x: CGFloat = 0
    var bars: [FlameBar] = []
    for slice in ordered {
        let width = size.width * CGFloat(slice.size) / CGFloat(total)
        bars.append(FlameBar(nodeID: slice.nodeID, label: slice.label, rect: CGRect(x: x, y: 0, width: max(width - 1, 0), height: row - 2)))
        let nested = slice.children.sorted { $0.size > $1.size }
        let nestedTotal = nested.reduce(Int64(0)) { $0 + $1.size }
        if nestedTotal > 0, width > 1 {
            var childX = x
            for child in nested {
                let childWidth = width * CGFloat(child.size) / CGFloat(nestedTotal)
                bars.append(FlameBar(
                    nodeID: child.nodeID,
                    label: child.label,
                    rect: CGRect(x: childX, y: row, width: max(childWidth - 1, 0), height: row - 2)
                ))
                childX += childWidth
            }
        }
        x += width
    }
    return bars
}

private func placedCircles(_ slices: [ChartSlice], packed: [PackedCircle], in size: CGSize) -> [DrawnCircle] {
    let fitted = BubblePresentation.fit(packed, slices: slices, width: size.width, height: size.height)
    let byID = Dictionary(uniqueKeysWithValues: labeled(slices).map { ($0.id, $0) })
    let topIDs = Set(slices.map(\.id))
    return fitted.map { circle in
        let slice = byID[circle.id]
        return DrawnCircle(
            nodeID: slice?.nodeID,
            label: slice?.label ?? "",
            center: CGPoint(x: circle.x, y: circle.y),
            radius: circle.radius,
            isContainer: topIDs.contains(circle.id) && !(slice?.children.isEmpty ?? true)
        )
    }
    .sorted { $0.radius > $1.radius } // large (parents) behind small (children)
}

private func labeled(_ slices: [ChartSlice]) -> [ChartSlice] {
    slices.flatMap { [$0] + labeled($0.children) }
}

