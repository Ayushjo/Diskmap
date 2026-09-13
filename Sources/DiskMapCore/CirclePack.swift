import Foundation

public struct PackedCircle: Sendable, Equatable {
    public var id: String
    public var x: Double
    public var y: Double
    public var radius: Double

    public init(id: String, x: Double, y: Double, radius: Double) {
        self.id = id
        self.x = x
        self.y = y
        self.radius = radius
    }
}

/// Circle packing for the bubbles view. Radii come from `sqrt(size)` so
/// area tracks size. Each sibling is seated tangent to an already placed
/// circle, at the angle closest to the origin that clears the others. A
/// separation pass then pushes any remaining intersection apart, so a
/// missed sample cannot leave two circles overlapping. The enclosing
/// circle may contain empty space.
public enum CirclePack {
    public static func pack(_ slices: [ChartSlice]) -> [PackedCircle] {
        packNodes(slices).circles
    }

    private struct Node {
        var id: String
        var radius: Double
        var x: Double
        var y: Double
        var children: [Node]
    }

    private static func packNodes(_ slices: [ChartSlice]) -> (circles: [PackedCircle], enclosing: Double) {
        let nodes = slices.filter { $0.size > 0 }.sorted { $0.size > $1.size }.map { slice -> Node in
            if slice.children.isEmpty {
                return Node(id: slice.id, radius: sqrt(Double(slice.size)), x: 0, y: 0, children: [])
            }
            let nested = packNodes(slice.children)
            let radius = max(sqrt(Double(slice.size)), nested.enclosing)
            return Node(id: slice.id, radius: radius, x: 0, y: 0, children: scaled(nested.circles, into: radius))
        }
        var placed = nodes
        placeSiblings(&placed)
        var circles: [PackedCircle] = []
        for node in placed {
            circles.append(PackedCircle(id: node.id, x: node.x, y: node.y, radius: node.radius))
            for child in node.children {
                circles.append(PackedCircle(
                    id: child.id,
                    x: node.x + child.x,
                    y: node.y + child.y,
                    radius: child.radius
                ))
            }
        }
        return (circles, enclosingRadius(placed))
    }

    private static func scaled(_ circles: [PackedCircle], into enclosing: Double) -> [Node] {
        let current = circles.reduce(0) { radius, circle in
            max(radius, hypot(circle.x, circle.y) + circle.radius)
        }
        let scale = current > 0 ? min(1, enclosing / current) : 1
        return circles.map { circle in
            Node(id: circle.id, radius: circle.radius * scale, x: circle.x * scale, y: circle.y * scale, children: [])
        }
    }

    private static func enclosingRadius(_ nodes: [Node]) -> Double {
        nodes.reduce(0) { radius, node in
            max(radius, hypot(node.x, node.y) + node.radius)
        }
    }

    private static func placeSiblings(_ nodes: inout [Node]) {
        guard !nodes.isEmpty else { return }
        nodes[0].x = 0
        nodes[0].y = 0
        guard nodes.count > 1 else { return }
        nodes[1].x = nodes[0].radius + nodes[1].radius
        nodes[1].y = 0
        let samples = 72
        for index in 2..<nodes.count {
            var bestX = nodes[index - 1].x + nodes[index - 1].radius + nodes[index].radius
            var bestY = 0.0
            var bestScore = Double.greatestFiniteMagnitude
            for host in 0..<index {
                let distance = nodes[host].radius + nodes[index].radius
                for step in 0..<samples {
                    let angle = Double(step) / Double(samples) * 2 * .pi
                    let x = nodes[host].x + cos(angle) * distance
                    let y = nodes[host].y + sin(angle) * distance
                    guard clears(x: x, y: y, radius: nodes[index].radius, nodes: nodes, count: index) else { continue }
                    let score = x * x + y * y
                    if score < bestScore {
                        bestScore = score
                        bestX = x
                        bestY = y
                    }
                }
            }
            nodes[index].x = bestX
            nodes[index].y = bestY
        }
        separate(&nodes)
    }

    private static func clears(x: Double, y: Double, radius: Double, nodes: [Node], count: Int) -> Bool {
        for index in 0..<count {
            let dx = x - nodes[index].x
            let dy = y - nodes[index].y
            let minDist = radius + nodes[index].radius
            if dx * dx + dy * dy < minDist * minDist - 1e-6 { return false }
        }
        return true
    }

    private static func separate(_ nodes: inout [Node]) {
        guard nodes.count > 1 else { return }
        for _ in 0..<100 {
            var moved = false
        for i in 0..<nodes.count {
            for j in (i + 1)..<nodes.count {
                    let dx = nodes[j].x - nodes[i].x
                    let dy = nodes[j].y - nodes[i].y
                    let dist = hypot(dx, dy)
                    let minDist = nodes[i].radius + nodes[j].radius
                    guard dist < minDist - 1e-6 else { continue }
                    let push = (minDist - dist) / 2 + 1e-4
                    let ux = dist > 0 ? dx / dist : 1
                    let uy = dist > 0 ? dy / dist : 0
                    nodes[i].x -= ux * push
                    nodes[i].y -= uy * push
                    nodes[j].x += ux * push
                    nodes[j].y += uy * push
                    moved = true
                }
            }
            if !moved { return }
        }
    }
}
