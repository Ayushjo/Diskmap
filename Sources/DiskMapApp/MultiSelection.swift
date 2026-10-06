import AppKit
import DiskMapCore
import SwiftUI

// Selecting several items the Mac way: ⌘-click adds or removes one, ⇧-click
// takes the range from the last click, a plain click goes back to one item.
// Shared by Visualize (every chart), Biggest Files and Biggest Folders, so
// a selection can be collected across views and folders, then staged,
// revealed or copied in one go.

extension ScanModel {
    /// Handles a click on node `id`. `ordered` is the list's row order, for
    /// ⇧-click ranges; charts pass nil (no meaningful order).
    /// SwiftUI runs a button's action after the click has been handled, so
    /// `NSApp.currentEvent` is often some other event; the keys held right
    /// now are the reliable signal (measured: the action saw unrelated flags).
    static var clickModifiers: NSEvent.ModifierFlags {
        if let harness = SnapshotHarness.clickModifiers { return harness }
        return NSEvent.modifierFlags
            .union(NSApp.currentEvent?.modifierFlags ?? [])
            .intersection([.command, .shift, .option, .control])
    }

    func select(_ id: Int32, ordered: [Int32]? = nil, modifiers explicit: NSEvent.ModifierFlags? = nil) {
        let modifiers = explicit ?? Self.clickModifiers
        if modifiers.contains(.command) {
            if multiSelection.isEmpty, selectedNode != id, selectedNode != 0, selectedNode != currentNode {
                multiSelection.insert(selectedNode)   // ⌘ adds to what was already selected
            }
            if multiSelection.contains(id) { multiSelection.remove(id) } else { multiSelection.insert(id) }
            selectionAnchor = id
        } else if modifiers.contains(.shift), let ordered, let anchor = selectionAnchor ?? (selectedNode != 0 ? selectedNode : nil),
                  let from = ordered.firstIndex(of: anchor), let to = ordered.firstIndex(of: id) {
            multiSelection.formUnion(ordered[min(from, to)...max(from, to)])
        } else {
            multiSelection.removeAll()
            selectionAnchor = id
        }
        selectedNode = id
    }

    func clearMultiSelection() {
        multiSelection.removeAll()
        selectionAnchor = nil
    }

    /// Selected nodes with no selected ancestor: a folder and something
    /// inside it are one item, never counted or staged twice.
    var multiSelectionRoots: [Int32] {
        guard let tree else { return [] }
        return multiSelection.filter { id in
            var parent = Int(id) < tree.count ? tree.parent[Int(id)] : -1
            while parent >= 0 {
                if multiSelection.contains(parent) { return false }
                parent = tree.parent[Int(parent)]
            }
            return true
        }
        .sorted { selectedTotals.indices.contains(Int($0)) && selectedTotals.indices.contains(Int($1))
            ? selectedTotals[Int($0)] > selectedTotals[Int($1)] : $0 < $1 }
    }

    var multiSelectionBytes: Int64 {
        multiSelectionRoots.reduce(0) { $0 + (selectedTotals.indices.contains(Int($1)) ? selectedTotals[Int($1)] : 0) }
    }

    func multiSelectionPaths() -> [String] {
        guard let tree, let rootURL else { return [] }
        return multiSelectionRoots.map { tree.path(of: $0, root: rootURL).path }
    }

    func stageMultiSelection() async {
        guard let tree, let rootURL else { return }
        let requests = multiSelectionRoots.map { id in
            CleanupStageRequest(url: tree.path(of: id, root: rootURL), size: selectedTotals[Int(id)],
                                reason: "Selected in \(destination.label)")
        }
        guard let result = await confirmStageMany(requests, title: "Selected in \(destination.label)") else { return }
        if result.added > 0 { clearMultiSelection() }
    }
}

private struct MultiSelectionKey: EnvironmentKey {
    static let defaultValue: Set<Int32> = []
}

extension EnvironmentValues {
    /// Nodes ⌘-selected alongside the primary selection, for highlighting.
    var multiSelection: Set<Int32> {
        get { self[MultiSelectionKey.self] }
        set { self[MultiSelectionKey.self] = newValue }
    }
}

/// The bar that appears once several nodes are selected.
struct NodeSelectionToolbar: View {
    @ObservedObject var model: ScanModel

    var body: some View {
        if model.multiSelection.count > 1 {
            SelectionToolbar(
                selectedCount: model.multiSelectionRoots.count,
                selectedBytes: model.multiSelectionBytes,
                onPrimary: { Task { await model.stageMultiSelection() } },
                onClear: { model.clearMultiSelection() },
                onReveal: {
                    NSWorkspace.shared.activateFileViewerSelecting(model.multiSelectionPaths().map { URL(fileURLWithPath: $0) })
                },
                paths: model.multiSelectionPaths()
            )
        }
    }
}

