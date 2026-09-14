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
                if sweep > 0.14, wedge.outer - wedge.inner > 22 {
                    let mid = (wedge.start + wedge.end) / 2
                    let radius = (wedge.inner + wedge.outer) / 2
                    let short = wedge.label.count > 16 ? String(wedge.label.prefix(14)) + "…" : wedge.label
                    context.draw(
                        Text(short).font(.caption2.weight(.semibold)).foregroundStyle(DiskMapTheme.ink),
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
                if bar.rect.width > 56 && bar.rect.height > 18 {
                    let short = bar.label.count > 22 ? String(bar.label.prefix(20)) + "…" : bar.label
                    context.draw(
                        Text(short).font(.caption2.weight(.semibold)).foregroundStyle(DiskMapTheme.ink),
                        at: CGPoint(x: bar.rect.minX + 6, y: bar.rect.midY),
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
            if let bounds = bubbleBounds(circles) {
                let pad: CGFloat = 6
                let enclosure = Path(ellipseIn: bounds.insetBy(dx: -pad, dy: -pad))
                context.fill(enclosure, with: .color(DiskMapTheme.cardFill.opacity(0.95)))
                context.stroke(enclosure, with: .color(DiskMapTheme.cardStroke), lineWidth: 1.5)
            }
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
                if circle.radius > 24 {
                    let maxChars = max(4, Int(circle.radius / 4.5))
                    let short = circle.label.count > maxChars
                        ? String(circle.label.prefix(maxChars - 1)) + "…"
                        : circle.label
                    let fontSize: CGFloat = circle.radius > 48 ? 11 : 9
                    context.draw(
                        Text(short)
                            .font(.system(size: fontSize, weight: .semibold))
                            .foregroundStyle(DiskMapTheme.ink.opacity(0.9)),
                        at: circle.center
                    )
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { value in
            // Smallest containing circle wins (deepest child).
            let hit = circles
                .filter { hypot($0.center.x - value.location.x, $0.center.y - value.location.y) <= $0.radius }
                .min(by: { $0.radius < $1.radius })
            drill(hit?.nodeID)
        })
    }
}

private func bubbleBounds(_ circles: [DrawnCircle]) -> CGRect? {
    guard let first = circles.first else { return nil }
    var minX = first.center.x - first.radius
    var minY = first.center.y - first.radius
    var maxX = first.center.x + first.radius
    var maxY = first.center.y + first.radius
    for c in circles.dropFirst() {
        minX = min(minX, c.center.x - c.radius)
        minY = min(minY, c.center.y - c.radius)
        maxX = max(maxX, c.center.x + c.radius)
        maxY = max(maxY, c.center.y + c.radius)
    }
    // Force enclosure to a circle (DiskBuddy look).
    let cx = (minX + maxX) / 2
    let cy = (minY + maxY) / 2
    let r = max(maxX - minX, maxY - minY) / 2
    return CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
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
                    context.stroke(line, with: .color(DiskMapTheme.cardStroke), lineWidth: 1)
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
                if node.labelWidth > 0.14 || node.hub {
                    let short = node.label.count > 14 ? String(node.label.prefix(12)) + "…" : node.label
                    context.draw(
                        Text(short).font(.caption2.weight(.semibold))
                            .foregroundStyle(node.hub ? Color.white : DiskMapTheme.ink),
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
    var isContainer: Bool
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

private func placedCircles(_ slices: [ChartSlice], in size: CGSize) -> [DrawnCircle] {
    let packed = CirclePack.pack(slices)
    guard !packed.isEmpty, size.width > 8, size.height > 8 else { return [] }
    let minX = packed.map { $0.x - $0.radius }.min() ?? 0
    let minY = packed.map { $0.y - $0.radius }.min() ?? 0
    let maxX = packed.map { $0.x + $0.radius }.max() ?? 1
    let maxY = packed.map { $0.y + $0.radius }.max() ?? 1
    let spanX = max(maxX - minX, 1e-6)
    let spanY = max(maxY - minY, 1e-6)
    // Fill the canvas the way DiskBuddy does — use nearly the full panel,
    // not a tiny cluster floating in cream.
    let pad: CGFloat = 10
    let scale = min((size.width - pad * 2) / spanX, (size.height - pad * 2) / spanY)
    let offsetX = size.width / 2 - (minX + maxX) / 2 * scale
    let offsetY = size.height / 2 - (minY + maxY) / 2 * scale
    let byID = Dictionary(uniqueKeysWithValues: labeled(slices).map { ($0.id, $0) })
    let topIDs = Set(slices.map(\.id))
    return packed.map { circle in
        let slice = byID[circle.id]
        return DrawnCircle(
            nodeID: slice?.nodeID,
            label: slice?.label ?? "",
            center: CGPoint(x: circle.x * scale + offsetX, y: circle.y * scale + offsetY),
            radius: circle.radius * scale,
            isContainer: topIDs.contains(circle.id) && !(slice?.children.isEmpty ?? true)
        )
    }
    .sorted { $0.radius > $1.radius } // large (parents) behind small (children)
}

private func labeled(_ slices: [ChartSlice]) -> [ChartSlice] {
    slices.flatMap { [$0] + labeled($0.children) }
}

private func mindNodes(_ slices: [ChartSlice], centerName: String, in size: CGSize) -> [MindNode] {
    let total = slices.reduce(Int64(0)) { $0 + $1.size }
    guard total > 0, size.width > 0, size.height > 0 else { return [] }
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    let ring = min(size.width, size.height) * 0.38
    let maxSize = slices.map(\.size).max() ?? 1
    var nodes = [MindNode(nodeID: nil, label: centerName, center: center, radius: 36, labelWidth: 1, hub: true)]
    var angle = -Double.pi / 2
    for slice in slices {
        let sweep = Double(slice.size) / Double(total) * 2 * .pi
        let mid = angle + sweep / 2
        let radius = 14 + 34 * sqrt(Double(slice.size) / Double(max(maxSize, 1)))
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
