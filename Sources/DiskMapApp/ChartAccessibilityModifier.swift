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

/// Arrow keys, Return, Space and ⌘Space for a chart (TASK-085). The chart
/// takes keyboard focus when clicked.
struct ChartKeyboard: ViewModifier {
    let move: (ChartNavigation.Direction) -> Void
    let open: () -> Void
    let enclosing: () -> Void
    let quickLook: () -> Void
    let addToSelection: () -> Void
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .simultaneousGesture(TapGesture().onEnded { focused = true })
            // Visualize has nothing else to type into: the chart takes the
            // keys as soon as it is shown, not only after a click.
            .onAppear { focused = true }
            .onKeyPress(phases: .down) { press in
                let command = press.modifiers.contains(.command)
                switch press.key {
                case .leftArrow: move(.left)
                case .rightArrow: move(.right)
                case .upArrow: if command { enclosing() } else { move(.up) }
                case .downArrow: if command { open() } else { move(.down) }
                case .return: open()
                case .space: if command { addToSelection() } else { quickLook() }
                default: return .ignored
                }
                return .handled
            }
    }
}

extension View {
    func chartKeyboard(move: @escaping (ChartNavigation.Direction) -> Void, open: @escaping () -> Void,
                       enclosing: @escaping () -> Void, quickLook: @escaping () -> Void,
                       addToSelection: @escaping () -> Void) -> some View {
        modifier(ChartKeyboard(move: move, open: open, enclosing: enclosing, quickLook: quickLook, addToSelection: addToSelection))
    }
}

extension View {
    /// VoiceOver actions every list row shares (TASK-085): Add to Cleanup
    /// (the queue — never the Trash), Reveal in Finder, Quick Look.
    func rowActions(path: String, stage: (() -> Void)?) -> some View {
        accessibilityActions {
            if let stage { Button("Add to Cleanup", action: stage) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            Button("Quick Look") { DiskMapQuickLook.shared.show(URL(fileURLWithPath: path)) }
        }
    }
}
