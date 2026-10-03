import Foundation

/// Fits a previously packed hierarchy without repeating expensive circle packing on resize.
public enum BubblePresentation {
    public static func fit(_ packed: [PackedCircle], slices: [ChartSlice], width: Double, height: Double) -> [PackedCircle] {
        guard !packed.isEmpty, width > 20, height > 20 else { return [] }
        let minX = packed.map { $0.x - $0.radius }.min() ?? 0
        let minY = packed.map { $0.y - $0.radius }.min() ?? 0
        let maxX = packed.map { $0.x + $0.radius }.max() ?? 1
        let maxY = packed.map { $0.y + $0.radius }.max() ?? 1
        let spanX = max(maxX - minX, 1e-6)
        let spanY = max(maxY - minY, 1e-6)
        // Leave room for selection outlines at every viewport size.
        let pad: Double = 10
        let scale = min((width - pad * 2) / spanX, (height - pad * 2) / spanY)
        let offsetX = width / 2 - (minX + maxX) / 2 * scale
        let offsetY = height / 2 - (minY + maxY) / 2 * scale
        let parents = Dictionary(uniqueKeysWithValues: slices.flatMap { parent in
            parent.children.map { ($0.id, parent.id) }
        })
        let packedByID = Dictionary(uniqueKeysWithValues: packed.map { ($0.id, $0) })
        return packed.map { original in
            var circle = original
            if let parentID = parents[circle.id], let parent = packedByID[parentID] {
                circle.x = parent.x + (circle.x - parent.x) * 0.72
                circle.y = parent.y + (circle.y - parent.y) * 0.72 + parent.radius * 0.16
                circle.radius *= 0.72
            }
            return PackedCircle(id: circle.id, x: circle.x * scale + offsetX,
                                y: circle.y * scale + offsetY, radius: circle.radius * scale)
        }
    }
}
