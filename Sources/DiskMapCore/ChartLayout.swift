import Foundation

/// One drawable slice of a chart. `nodeID` is nil for the collapsed
/// remainder. That remainder is never drillable.
public struct ChartSlice: Sendable, Equatable, Identifiable {
    public let id: String
    public let nodeID: Int32?
    public let size: Int64
    public let label: String
    public let drillable: Bool
    public let children: [ChartSlice]
    /// How many items this slice stands for: 1, or the number of small items
    /// folded into an "Other" slice.
    public let collapsedCount: Int

    public init(id: String, nodeID: Int32?, size: Int64, label: String, drillable: Bool, children: [ChartSlice],
                collapsedCount: Int = 1) {
        self.id = id
        self.nodeID = nodeID
        self.size = size
        self.label = label
        self.drillable = drillable
        self.children = children
        self.collapsedCount = collapsedCount
    }
}

/// `levels` levels of `currentNode`'s descendants (2 by default: the
/// children plus one more level; the flame chart asks for 4), each only
/// for items large enough to draw. Anything smaller
/// than 0.5% of its parent collapses into a single Other slice so a
/// home scan cannot draw every descendant.
public enum ChartLayout {
    public static let otherFraction = 0.005

    public static func slices(
        of node: Int32,
        in tree: FileTree,
        totals: [Int64],
        otherFraction fraction: Double = otherFraction,
        levels: Int = 2
    ) -> [ChartSlice] {
        guard node >= 0, node < tree.count, totals.count == tree.count, levels >= 1 else { return [] }
        return collapse(
            tree.children(of: node, totals: totals),
            parentSize: totals[Int(node)],
            tree: tree,
            totals: totals,
            depth: levels - 1,
            idPrefix: "\(node)",
            otherFraction: fraction
        )
    }

    private static func collapse(
        _ items: [(id: Int32, size: Int64)],
        parentSize: Int64,
        tree: FileTree,
        totals: [Int64],
        /// How many more levels below these items to include.
        depth: Int,
        idPrefix: String,
        otherFraction: Double
    ) -> [ChartSlice] {
        let threshold = Double(parentSize) * otherFraction
        var visible: [(id: Int32, size: Int64)] = []
        var otherSize: Int64 = 0
        var otherCount = 0
        for item in items where item.size > 0 {
            if Double(item.size) < threshold {
                otherSize += item.size
                otherCount += 1
            } else {
                visible.append(item)
            }
        }
        visible.sort { $0.size > $1.size }
        var slices: [ChartSlice] = visible.map { item in
            let nested: [ChartSlice]
            if depth > 0, tree.isDirectory[Int(item.id)] {
                nested = collapse(
                    tree.children(of: item.id, totals: totals),
                    parentSize: item.size,
                    tree: tree,
                    totals: totals,
                    depth: depth - 1,
                    idPrefix: "\(idPrefix).\(item.id)",
                    otherFraction: otherFraction
                )
            } else {
                nested = []
            }
            return ChartSlice(
                id: "\(idPrefix).\(item.id)",
                nodeID: item.id,
                size: item.size,
                label: tree.name(of: item.id),
                drillable: tree.isDirectory[Int(item.id)],
                children: nested
            )
        }
        if otherCount > 0 {
            slices.append(ChartSlice(
                id: "\(idPrefix).other",
                nodeID: nil,
                size: otherSize,
                label: "Other (\(otherCount))",
                drillable: false,
                children: [],
                collapsedCount: otherCount
            ))
        }
        return slices
    }
}
