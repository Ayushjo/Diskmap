import AppKit
import DiskMapCore
import SwiftUI

// TASK-062: the keyboard, in one place.
//
// Menu (work anywhere):  ⌘1–⌘9 sidebar destinations in order · ⌘R rescan ·
// ⇧⌘R full rescan · ⇧⌘⌫ cleanup queue · ⌘↑ enclosing folder · ⌘↓ open folder
// (Visualize and File Browser both follow `currentNode`).
//
// Lists (once a row is selected):  ↑↓ or j/k move · Space Quick Look ·
// Return reveal in Finder · ⌘⌫ add to Cleanup (the queue — never the Trash).

struct KeyboardCommands: Commands {
    @ObservedObject var model: ScanModel

    /// Sidebar order, so ⌘N is "the Nth item" without memorising a map.
    static var numberedDestinations: [AppDestination] {
        Array(AppNavSection.allCases.flatMap(\.items).prefix(9))
    }

    var body: some Commands {
        CommandMenu("Go") {
            ForEach(Array(Self.numberedDestinations.enumerated()), id: \.offset) { index, destination in
                Button(destination.label) { model.destination = destination }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .disabled(destination.requiresScan && model.tree == nil)
            }
            Divider()
            Button("Enclosing Folder") { model.goToEnclosingFolder() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(model.tree == nil || model.currentNode == 0)
            Button("Open Folder") { model.openSelectedFolder() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(model.tree == nil)
        }
        CommandGroup(after: .newItem) {
            Button("Rescan") { if let root = model.rootURL { Task { await model.scan(root) } } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.rootURL == nil || model.isScanning)
            Button("Full Rescan") { if let root = model.rootURL { Task { await model.scan(root, mode: .full) } } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.rootURL == nil || model.isScanning)
            Button("Show Cleanup Queue") { model.isCleanupQueuePresented = true }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(model.tree == nil)
        }
    }
}

extension ScanModel {
    /// ⌘⌫ in a list: stage one row (the queue — never the Trash) and say so.
    func stageRow(path: String, size: Int64, reason: String) {
        Task {
            let result = await stageForCleanup([CleanupStageRequest(url: URL(fileURLWithPath: path), size: size, reason: reason)])
            showToast(result.added > 0 ? "Added to Cleanup — ⇧⌘⌫ to review"
                      : result.alreadyPresent > 0 ? "Already in Cleanup" : "Blocked by safety rules")
        }
    }

    /// ⌘↑: Visualize and File Browser both show `currentNode`.
    func goToEnclosingFolder() {
        guard let tree, currentNode > 0, Int(currentNode) < tree.count else { return }
        let parent = tree.parent[Int(currentNode)]
        selectedNode = currentNode
        currentNode = max(0, parent)
    }

    /// ⌘↓: into the selected folder (or the selected file's folder).
    func openSelectedFolder() {
        guard let tree, Int(selectedNode) < tree.count else { return }
        currentNode = tree.isDirectory[Int(selectedNode)] ? selectedNode : max(0, tree.parent[Int(selectedNode)])
    }
}

/// Row navigation for any list of ids. Apply to the list's ScrollView; rows
/// must be identified by the same ids (ForEach identity) so they can be
/// scrolled into view.
struct ListKeyboard<ID: Hashable>: ViewModifier {
    let ids: [ID]
    @Binding var selection: ID?
    /// Absolute path for Quick Look and Reveal; nil when a row has none.
    var path: (ID) -> String?
    /// ⌘⌫. Receives the selected row; lists with checkboxes pass the checked
    /// rows instead when any are checked.
    var stage: ((ID) -> Void)?
    /// Return. Defaults to revealing `path` in Finder.
    var open: ((ID) -> Void)?
    /// ⌘A: select every row (for multi-select lists).
    var selectAll: (() -> Void)?
    /// Esc: drop a multi-selection.
    var clearSelection: (() -> Void)?

    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onChange(of: selection) { _, newValue in
                    // A click on a row selects it; from then on the keys work.
                    if newValue != nil { focused = true }
                }
                .onKeyPress(phases: [.down, .repeat]) { press in
                    handle(press, proxy: proxy)
                }
        }
    }

    private func handle(_ press: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
        let command = press.modifiers.contains(.command)
        switch press.key {
        case .downArrow where !command:
            return move(+1, proxy: proxy)
        case .upArrow where !command:
            return move(-1, proxy: proxy)
        case .space:
            guard let current = selection, let path = path(current) else { return .ignored }
            DiskMapQuickLook.shared.show(URL(fileURLWithPath: path))
            return .handled
        case .return:
            guard let current = selection else { return .ignored }
            if let open {
                open(current)
            } else if let path = path(current) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            return .handled
        case "a" where command:
            guard let selectAll else { return .ignored }
            selectAll()
            return .handled
        case .escape:
            guard let clearSelection else { return .ignored }
            clearSelection()
            return .handled
        case .delete where command:
            guard let current = selection, let stage else { return .ignored }
            stage(current)
            return .handled
        default:
            guard !command, press.modifiers.isEmpty || press.modifiers == .shift else { return .ignored }
            switch press.characters {
            case "j": return move(+1, proxy: proxy)
            case "k": return move(-1, proxy: proxy)
            default: return .ignored
            }
        }
    }

    private func move(_ step: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !ids.isEmpty else { return .ignored }
        let index: Int
        if let current = selection, let at = ids.firstIndex(of: current) {
            index = min(max(at + step, 0), ids.count - 1)
        } else {
            index = step > 0 ? 0 : ids.count - 1
        }
        selection = ids[index]
        proxy.scrollTo(ids[index])
        return .handled
    }
}

extension View {
    func listKeyboard<ID: Hashable>(
        ids: [ID], selection: Binding<ID?>, path: @escaping (ID) -> String?,
        stage: ((ID) -> Void)? = nil, open: ((ID) -> Void)? = nil,
        selectAll: (() -> Void)? = nil, clearSelection: (() -> Void)? = nil
    ) -> some View {
        modifier(ListKeyboard(ids: ids, selection: selection, path: path, stage: stage, open: open,
                              selectAll: selectAll, clearSelection: clearSelection))
    }
}
