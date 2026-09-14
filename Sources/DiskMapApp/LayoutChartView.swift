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

    var body: some View {
        VStack(spacing: 0) {
            DrillHeader(tree: tree, currentNode: currentNode, totals: totals) { id in
                currentNode = id
                selectedNode = id
            }
            GeometryReader { proxy in
                let slices = currentSlices
                if slices.isEmpty {
                    Text("Nothing with a size in this folder")
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    chart(slices, in: proxy.size)
                }
            }
            .background(DiskMapTheme.cream)
        }
        .background(DiskMapTheme.cream)
    }

    private var currentSlices: [ChartSlice] {
        guard currentNode >= 0, Int(currentNode) < tree.count, totals.count == tree.count else { return [] }
        return ChartLayout.slices(of: currentNode, in: tree, totals: totals, otherFraction: otherFraction)
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
                if sweep > 0.12, wedge.outer - wedge.inner > 16 {
                    let mid = (wedge.start + wedge.end) / 2
                    let radius = (wedge.inner + wedge.outer) / 2
                    context.draw(
                        Text(wedge.label).font(.caption2).foregroundStyle(.white),
                        at: polarPoint(center: wedge.center, angle: mid, radius: radius)
                    )
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { value in
            drill(hit(layout, at: value.location))
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
                if bar.rect.width > 48 && bar.rect.height > 16 {
                    context.draw(
                        Text(bar.label).font(.caption2).foregroundStyle(.white),
                        at: CGPoint(x: bar.rect.minX + 4, y: bar.rect.midY),
                        anchor: .leading
                    )
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { value in
            drill(bars.first { $0.rect.contains(value.location) }?.nodeID)
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

    var body: some View {
        let circles = placedCircles(slices, in: size)
        Canvas { context, _ in
            for circle in circles {
                let path = Path(ellipseIn: CGRect(
                    x: circle.center.x - circle.radius,
                    y: circle.center.y - circle.radius,
                    width: circle.radius * 2,
                    height: circle.radius * 2
                ))
                let isSel = circle.nodeID == selected
                context.fill(path, with: .color(color(circle.nodeID)))
                context.stroke(path, with: .color(isSel ? DiskMapTheme.ink : .black.opacity(0.3)), lineWidth: isSel ? 2 : 1)
                // Only label large bubbles — small ones overlap into illegible stacks.
                if circle.radius > 28 {
                    let short = circle.label.count > 18
                        ? String(circle.label.prefix(16)) + "…"
                        : circle.label
                    context.draw(
                        Text(short).font(.caption2.weight(.semibold)).foregroundStyle(DiskMapTheme.ink),
                        at: circle.center
                    )
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { value in
            drill(circles.last { hypot($0.center.x - value.location.x, $0.center.y - value.location.y) <= $0.radius }?.nodeID)
        })
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
        let nodes = mindNodes(slices, centerName: centerName, in: size)
        Canvas { context, _ in
            if let hub = nodes.first {
                for node in nodes.dropFirst() {
                    var line = Path()
                    line.move(to: hub.center)
                    line.addLine(to: node.center)
                    context.stroke(line, with: .color(.secondary.opacity(0.4)), lineWidth: 1)
                }
            }
            for node in nodes {
                let path = Path(ellipseIn: CGRect(
                    x: node.center.x - node.radius,
                    y: node.center.y - node.radius,
                    width: node.radius * 2,
                    height: node.radius * 2
                ))
                let isSel = !node.hub && node.nodeID == selected
                let fill = node.hub ? DiskMapTheme.ink.opacity(0.55) : color(node.nodeID)
                context.fill(path, with: .color(fill))
                if isSel {
                    context.stroke(path, with: .color(DiskMapTheme.ink), lineWidth: 2)
                }
                if node.labelWidth > 0.18 || node.hub {
                    context.draw(
                        Text(node.label).font(.caption2).foregroundStyle(.white),
                        at: node.center
                    )
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { value in
            let hit = nodes.first {
                !$0.hub && hypot($0.center.x - value.location.x, $0.center.y - value.location.y) <= $0.radius
            }
            drill(hit?.nodeID)
        })
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

private struct DrawnCircle {
    var nodeID: Int32?
    var label: String
    var center: CGPoint
    var radius: CGFloat
}

private struct MindNode {
    var nodeID: Int32?
    var label: String
    var center: CGPoint
    var radius: CGFloat
    var labelWidth: Double
    var hub: Bool
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
    let hole = radius * 0.28
    let mid = (hole + radius) / 2
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

private func placedCircles(_ slices: [ChartSlice], in size: CGSize) -> [DrawnCircle] {
    let packed = CirclePack.pack(slices)
    guard !packed.isEmpty, size.width > 0, size.height > 0 else { return [] }
    let minX = packed.map { $0.x - $0.radius }.min() ?? 0
    let minY = packed.map { $0.y - $0.radius }.min() ?? 0
    let maxX = packed.map { $0.x + $0.radius }.max() ?? 1
    let maxY = packed.map { $0.y + $0.radius }.max() ?? 1
    let span = max(maxX - minX, maxY - minY, 1)
    let scale = min(size.width, size.height) / span * 0.92
    let offsetX = size.width / 2 - (minX + maxX) / 2 * scale
    let offsetY = size.height / 2 - (minY + maxY) / 2 * scale
    let labels = Dictionary(uniqueKeysWithValues: labeled(slices).map { ($0.id, $0) })
    return packed.map { circle in
        let slice = labels[circle.id]
        return DrawnCircle(
            nodeID: slice?.nodeID,
            label: slice?.label ?? "",
            center: CGPoint(x: circle.x * scale + offsetX, y: circle.y * scale + offsetY),
            radius: circle.radius * scale
        )
    }
}

private func labeled(_ slices: [ChartSlice]) -> [ChartSlice] {
    slices.flatMap { [$0] + labeled($0.children) }
}

private func mindNodes(_ slices: [ChartSlice], centerName: String, in size: CGSize) -> [MindNode] {
    let total = slices.reduce(Int64(0)) { $0 + $1.size }
    guard total > 0, size.width > 0, size.height > 0 else { return [] }
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    let ring = min(size.width, size.height) * 0.34
    let maxSize = slices.map(\.size).max() ?? 1
    var nodes = [MindNode(nodeID: nil, label: centerName, center: center, radius: 28, labelWidth: 1, hub: true)]
    var angle = -Double.pi / 2
    for slice in slices {
        let sweep = Double(slice.size) / Double(total) * 2 * .pi
        let mid = angle + sweep / 2
        let radius = 10 + 26 * sqrt(Double(slice.size) / Double(max(maxSize, 1)))
        nodes.append(MindNode(
            nodeID: slice.nodeID,
            label: slice.label,
            center: polarPoint(center: center, angle: mid, radius: ring),
            radius: radius,
            labelWidth: sweep,
            hub: false
        ))
        angle += sweep
    }
    return nodes
}
