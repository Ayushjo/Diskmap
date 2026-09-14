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

    public init(id: String, nodeID: Int32?, size: Int64, label: String, drillable: Bool, children: [ChartSlice]) {
        self.id = id
        self.nodeID = nodeID
        self.size = size
        self.label = label
        self.drillable = drillable
        self.children = children
    }
}

/// One level of `currentNode`'s children, plus at most one more level
/// for the children that are large enough to draw. Anything smaller
/// than 0.5% of its parent collapses into a single Other slice so a
/// home scan cannot draw every descendant.
public enum ChartLayout {
    public static let otherFraction = 0.005

    public static func slices(
        of node: Int32,
        in tree: FileTree,
        totals: [Int64],
        otherFraction fraction: Double = otherFraction
    ) -> [ChartSlice] {
        guard node >= 0, node < tree.count, totals.count == tree.count else { return [] }
        return collapse(
            tree.children(of: node, totals: totals),
            parentSize: totals[Int(node)],
            tree: tree,
            totals: totals,
            includeChildren: true,
            idPrefix: "\(node)",
            otherFraction: fraction
        )
    }

    private static func collapse(
        _ items: [(id: Int32, size: Int64)],
        parentSize: Int64,
        tree: FileTree,
        totals: [Int64],
        includeChildren: Bool,
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
            if includeChildren, tree.isDirectory[Int(item.id)] {
                nested = collapse(
                    tree.children(of: item.id, totals: totals),
                    parentSize: item.size,
                    tree: tree,
                    totals: totals,
                    includeChildren: false,
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
                children: []
            ))
        }
        return slices
    }
}
