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
