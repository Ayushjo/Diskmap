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
        return "\(currentNode):\(totals.count):\(size):\(otherFraction)"
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
        let fraction = otherFraction
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
            MindMapChart(slices: slices, size: size, centerName: tree.name(of: currentNode), color: color, selected: selectedNode, select: select, drill: drill)
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
                context.stroke(path, with: .color(isSel ? DiskMapTheme.ink : .black.opacity(0.25)), lineWidth: isSel ? 2 : 1)
                let sweep = wedge.end - wedge.start
                if sweep > 0.14, wedge.outer - wedge.inner > 22 {
                    let mid = (wedge.start + wedge.end) / 2
                    let radius = (wedge.inner + wedge.outer) / 2
                    let capacity = min(18, max(3, Int(min(sweep * radius, wedge.outer - wedge.inner) / 6)))
                    let short = wedge.label.count > capacity ? String(wedge.label.prefix(capacity - 1)) + "…" : wedge.label
                    context.draw(
                        Text(short).font(.caption2.weight(.semibold)).foregroundStyle(DiskMapTheme.ink),
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
                context.stroke(path, with: .color(isSel ? DiskMapTheme.ink : .black.opacity(0.25)), lineWidth: isSel ? 2 : 1)
                if bar.rect.width > 56 && bar.rect.height > 18 {
                    let capacity = max(3, Int((bar.rect.width - 14) / 6))
                    let short = bar.label.count > capacity ? String(bar.label.prefix(capacity - 1)) + "…" : bar.label
                    context.draw(
                        Text(short).font(.caption2.weight(.semibold)).foregroundStyle(DiskMapTheme.ink),
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
                let fill = circle.isContainer ? base.opacity(0.55) : base.opacity(0.92)
                context.fill(path, with: .color(fill))
                context.stroke(
                    path,
                    with: .color(isSel ? DiskMapTheme.ink : DiskMapTheme.ink.opacity(0.18)),
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
                            .foregroundStyle(DiskMapTheme.ink.opacity(0.9)),
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

private struct MindMapChart: View {
    let slices: [ChartSlice]
    let size: CGSize
    let centerName: String
    let color: (Int32?) -> Color
    let selected: Int32
    let select: (Int32?) -> Void
    let drill: (Int32?) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 5) {
                    Label(centerName, systemImage: "folder.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1).help(centerName)
                    Text(ByteFormat.string(slices.reduce(0) { $0 + $1.size }))
                        .font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
                .padding(14)
                .frame(maxWidth: 280)
                .background(DiskMapTheme.cardFill, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(DiskMapTheme.cardStroke))
                Rectangle().fill(DiskMapTheme.cardStroke).frame(width: 1, height: 24)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20, alignment: .top), count: size.width >= 720 ? 3 : size.width >= 480 ? 2 : 1), alignment: .center, spacing: 22) {
                    ForEach(slices) { slice in
                        VStack(spacing: 0) {
                            Rectangle().fill(color(slice.nodeID).opacity(0.5)).frame(width: 2, height: 16)
                            VStack(alignment: .leading, spacing: 10) {
                                nodeRow(slice, primary: true)
                                if !slice.children.isEmpty {
                                    Divider()
                                    ForEach(slice.children.prefix(4)) { child in
                                        HStack(spacing: 8) {
                                            Image(systemName: "arrow.turn.down.right")
                                                .font(.system(size: 10)).foregroundStyle(DiskMapTheme.mutedLabel)
                                            nodeRow(child, primary: false)
                                        }
                                    }
                                    if slice.children.count > 4 {
                                        Text("\(slice.children.count - 4) more branches · Explore folder to see all")
                                            .font(.system(size: 11)).foregroundStyle(DiskMapTheme.mutedLabel)
                                    }
                                }
                            }
                            .padding(12)
                            .background(DiskMapTheme.cardFill, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color(slice.nodeID).opacity(0.45)))
                        }
                    }
                }
                .overlay(alignment: .top) { Rectangle().fill(DiskMapTheme.cardStroke).frame(height: 1) }
            }
            .padding(20)
        }
    }

    private func nodeRow(_ slice: ChartSlice, primary: Bool) -> some View {
        HStack(spacing: 6) {
            Button { select(slice.nodeID) } label: {
                HStack(spacing: 8) {
                    Image(systemName: slice.drillable ? "folder.fill" : "doc.fill")
                        .foregroundStyle(color(slice.nodeID))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(slice.label).font(.system(size: primary ? 13 : 12, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                        Text(ByteFormat.string(slice.size)).font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                    Spacer(minLength: 0)
                }
                .padding(4).contentShape(Rectangle())
                .background(slice.nodeID == selected ? DiskMapTheme.ink.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain).disabled(slice.nodeID == nil).help(slice.label)
            .accessibilityLabel("\(slice.label), \(ByteFormat.string(slice.size))")
            if slice.drillable {
                Button { drill(slice.nodeID) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Explore \(slice.label)")
                .accessibilityLabel("Explore \(slice.label)")
            }
        }
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

