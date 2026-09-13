import CoreGraphics

public struct TreemapRect: Identifiable, Sendable {
    public let id: Int32 // FileTree node id
    public let rect: CGRect
}

/// Squarified treemap layout (Bruls, Huizing, van Wijk, "Squarified
/// Treemaps", 2000) — the algorithm behind WinDirStat, GrandPerspective,
/// and most disk-usage treemaps. Greedily builds rows/columns that keep
/// rectangles as close to square as possible, which is what keeps small
/// files legible instead of degenerating into 1px slivers.
///
/// Verified against the paper's section 3.1 example: sizes
/// [6, 6, 4, 3, 2, 2, 1] in a 6×4 rectangle (Figure 3 in the PDF — the
/// ticket's "Figure 6" is this example; Figure 6 itself is cushion
/// shading). Row membership matches the paper. Rectangles are placed
/// from `rect.minX`/`rect.minY` advancing in +x/+y, so the first item
/// is the top-left in SwiftUI Canvas rather than the paper's bottom-left.
/// Equal aspect ratios still accept the candidate (`<=`), matching the
/// paper's `worst(row) ≥ worst(row++[c])`.
public enum SquarifiedTreemap {

    public static func layout(items: [(id: Int32, size: Int64)], in rect: CGRect) -> [TreemapRect] {
        guard !items.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
        let sorted = items
            .filter { $0.size > 0 }
            .sorted { $0.size > $1.size }
            .map { (id: $0.id, size: Double($0.size)) }
        guard !sorted.isEmpty else { return [] }

        var result: [TreemapRect] = []
        squarify(sorted, in: rect, into: &result)
        return result
    }

    /// Topmost rectangle containing `point`, if any. Layouts from
    /// `layout` do not overlap; last-match still prefers a later rect
    /// when a point sits on a shared edge (`CGRect.contains` excludes
    /// maxX/maxY, so interior points match once).
    public static func hitTest(_ rects: [TreemapRect], at point: CGPoint) -> Int32? {
        rects.last(where: { $0.rect.contains(point) })?.id
    }

    private static func squarify(_ items: [(id: Int32, size: Double)], in rect: CGRect, into result: inout [TreemapRect]) {
        guard !items.isEmpty, rect.width > 0, rect.height > 0 else { return }
        if items.count == 1 {
            result.append(TreemapRect(id: items[0].id, rect: rect))
            return
        }

        let total = items.reduce(0.0) { $0 + $1.size }
        guard total > 0 else { return }

        // The paper's width() is the shorter side of the *remaining*
        // rectangle. A row is a strip spanning that side.
        let shortSide = Double(min(rect.width, rect.height))
        let rectArea = Double(rect.width) * Double(rect.height)

        var row: [(id: Int32, size: Double)] = []
        var rowSum = 0.0
        var bestWorst = Double.infinity
        var index = 0

        while index < items.count {
            let candidate = items[index]
            let proposedSum = rowSum + candidate.size
            let worst = worstAspectRatio(
                row.map(\.size) + [candidate.size],
                sum: proposedSum,
                shortSide: shortSide,
                rectArea: rectArea,
                total: total
            )

            if row.isEmpty || worst <= bestWorst {
                row.append(candidate)
                rowSum = proposedSum
                bestWorst = worst
                index += 1
            } else {
                break
            }
        }

        let remainder = place(row, sum: rowSum, total: total, in: rect, into: &result)
        if index < items.count {
            squarify(Array(items[index...]), in: remainder, into: &result)
        }
    }

    /// Lays `row` along the shorter side. The last item in the row absorbs
    /// rounding leftover so the strip is covered exactly. Returns the
    /// unused remainder of `rect`.
    private static func place(
        _ row: [(id: Int32, size: Double)],
        sum: Double,
        total: Double,
        in rect: CGRect,
        into result: inout [TreemapRect]
    ) -> CGRect {
        let spansHeight = rect.width >= rect.height
        if spansHeight {
            let colWidth = rect.width * CGFloat(sum / total)
            var y = rect.minY
            for (offset, item) in row.enumerated() {
                let height = offset == row.count - 1
                    ? rect.maxY - y
                    : rect.height * CGFloat(item.size / sum)
                result.append(TreemapRect(
                    id: item.id,
                    rect: CGRect(x: rect.minX, y: y, width: colWidth, height: height)
                ))
                y += height
            }
            let usedMaxX = rect.minX + colWidth
            return CGRect(x: usedMaxX, y: rect.minY, width: rect.maxX - usedMaxX, height: rect.height)
        } else {
            let rowHeight = rect.height * CGFloat(sum / total)
            var x = rect.minX
            for (offset, item) in row.enumerated() {
                let width = offset == row.count - 1
                    ? rect.maxX - x
                    : rect.width * CGFloat(item.size / sum)
                result.append(TreemapRect(
                    id: item.id,
                    rect: CGRect(x: x, y: rect.minY, width: width, height: rowHeight)
                ))
                x += width
            }
            let usedMaxY = rect.minY + rowHeight
            return CGRect(x: rect.minX, y: usedMaxY, width: rect.width, height: rect.maxY - usedMaxY)
        }
    }

    /// Highest aspect ratio in a candidate row. This is the paper's
    /// `worst(R, w) = max(w²·r₊/s², s²/(w²·r₋))` after scaling sizes so
    /// they sum to the remaining rectangle's area — not to `shortSide²`,
    /// which is only correct when the rectangle is already square.
    private static func worstAspectRatio(
        _ sizes: [Double],
        sum: Double,
        shortSide: Double,
        rectArea: Double,
        total: Double
    ) -> Double {
        guard sum > 0, shortSide > 0, rectArea > 0, total > 0 else { return .infinity }
        let thickness = (sum / total) * rectArea / shortSide
        guard thickness > 0 else { return .infinity }

        var worst = 0.0
        for size in sizes {
            guard size > 0 else { return .infinity }
            let length = (size / sum) * shortSide
            let aspect = length >= thickness ? length / thickness : thickness / length
            if aspect > worst { worst = aspect }
        }
        return worst
    }
}
