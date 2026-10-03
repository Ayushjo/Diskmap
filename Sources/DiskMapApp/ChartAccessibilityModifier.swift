import DiskMapCore
import SwiftUI

extension View {
    /// Gives a chart drawn on a Canvas one VoiceOver element per big item
    /// (TASK-078): its label, a frame on screen, a default action that
    /// selects it and, for folders, an "Open" action that drills in. Items
    /// the chart did not draw (no frame) are left out.
    func chartAccessibility(
        _ title: String,
        entries: [ChartAccessibility.Entry],
        frame: @escaping (Int32) -> CGRect?,
        select: @escaping (Int32) -> Void,
        open: @escaping (Int32) -> Void
    ) -> some View {
        let placed = entries.compactMap { entry in frame(entry.id).map { (entry, $0) } }
        return self
            .accessibilityLabel(title)
            .accessibilityChildren {
                ZStack(alignment: .topLeading) {
                    ForEach(placed, id: \.0.id) { entry, rect in
                        Rectangle()
                            .frame(width: max(1, rect.width), height: max(1, rect.height))
                            .offset(x: rect.minX, y: rect.minY)
                            .accessibilityLabel(entry.label)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { select(entry.id) }
                            .accessibilityActions {
                                if entry.drillable { Button("Open") { open(entry.id) } }
                            }
                    }
                }
            }
    }
}
