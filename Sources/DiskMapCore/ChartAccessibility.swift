import Foundation

/// What VoiceOver gets for a chart drawn on a Canvas (TASK-078): the biggest
/// items as elements labelled "name, size, share". Only real nodes — an
/// "Other" slice stands for many items and cannot be selected.
public enum ChartAccessibility {
    public struct Item: Sendable, Equatable {
        public var id: Int32
        public var name: String
        public var size: Int64
        public var drillable: Bool

        public init(id: Int32, name: String, size: Int64, drillable: Bool) {
            self.id = id
            self.name = name
            self.size = size
            self.drillable = drillable
        }
    }

    public struct Entry: Sendable, Equatable, Identifiable {
        public var id: Int32
        public var label: String
        public var drillable: Bool
    }

    /// The `limit` biggest items, largest first (ties by id, so the order is
    /// stable), each labelled with its share of `total`.
    public static func entries(_ items: [Item], total: Int64, limit: Int = 60,
                               format: (Int64) -> String) -> [Entry] {
        let ranked = items
            .filter { $0.size > 0 }
            .sorted { $0.size != $1.size ? $0.size > $1.size : $0.id < $1.id }
            .prefix(max(0, limit))
        return ranked.map { item in
            Entry(id: item.id, label: "\(item.name), \(format(item.size)), \(share(item.size, of: total))",
                  drillable: item.drillable)
        }
    }

    /// Every real node in a slice tree, at any depth.
    public static func items(in slices: [ChartSlice]) -> [Item] {
        var out: [Item] = []
        var stack = slices
        while let slice = stack.popLast() {
            if let id = slice.nodeID {
                out.append(Item(id: id, name: slice.label, size: slice.size, drillable: slice.drillable))
            }
            stack.append(contentsOf: slice.children)
        }
        return out
    }

    /// "42 percent"; under one percent reads "less than 1 percent".
    public static func share(_ size: Int64, of total: Int64) -> String {
        guard total > 0 else { return "0 percent" }
        let fraction = Double(size) / Double(total)
        if fraction > 0, fraction < 0.01 { return "less than 1 percent" }
        return "\(Int((fraction * 100).rounded())) percent"
    }
}

/// Moving the selection inside a chart with the arrow keys (TASK-085).
public enum ChartNavigation {
    public enum Direction: Sendable { case left, right, up, down }

    /// Treemap: the tile whose centre lies `direction` of the current one,
    /// preferring the closest along that axis and penalising sideways drift.
    /// No current tile → the largest (first) one.
    public static func neighbor(of id: Int32?, toward direction: Direction,
                                in tiles: [(id: Int32, rect: CGRect)]) -> Int32? {
        guard let id, let current = tiles.first(where: { $0.id == id }) else { return tiles.first?.id }
        let origin = CGPoint(x: current.rect.midX, y: current.rect.midY)
        var best: (id: Int32, score: CGFloat)?
        for tile in tiles where tile.id != id {
            let dx = tile.rect.midX - origin.x
            let dy = tile.rect.midY - origin.y
            let along: CGFloat, across: CGFloat
            switch direction {
            case .right: along = dx; across = abs(dy)
            case .left: along = -dx; across = abs(dy)
            case .down: along = dy; across = abs(dx)
            case .up: along = -dy; across = abs(dx)
            }
            guard along > 0.5 else { continue }
            let score = along + 2 * across
            if let current = best, current.score <= score { continue }
            best = (tile.id, score)
        }
        return best?.id ?? id
    }

    /// Sunburst, flame, bubbles: left/right step between siblings (largest
    /// first), up goes to the parent, down to the largest child. Only real
    /// nodes — an "Other" slice cannot be selected.
    public static func step(from id: Int32?, toward direction: Direction, in slices: [ChartSlice]) -> Int32? {
        func real(_ list: [ChartSlice]) -> [ChartSlice] {
            list.filter { $0.nodeID != nil }.sorted { $0.size != $1.size ? $0.size > $1.size : ($0.nodeID ?? 0) < ($1.nodeID ?? 0) }
        }
        // Find the current slice, its siblings and its parent.
        func locate(_ list: [ChartSlice], parent: ChartSlice?) -> (siblings: [ChartSlice], slice: ChartSlice, parent: ChartSlice?)? {
            for slice in list {
                if slice.nodeID == id { return (list, slice, parent) }
                if let found = locate(slice.children, parent: slice) { return found }
            }
            return nil
        }
        guard id != nil, let found = locate(slices, parent: nil) else { return real(slices).first?.nodeID }
        switch direction {
        case .left, .right:
            let siblings = real(found.siblings)
            guard let index = siblings.firstIndex(where: { $0.nodeID == id }) else { return id }
            let next = direction == .right ? min(index + 1, siblings.count - 1) : max(index - 1, 0)
            return siblings[next].nodeID
        case .up:
            return found.parent?.nodeID ?? id
        case .down:
            return real(found.slice.children).first?.nodeID ?? id
        }
    }
}
