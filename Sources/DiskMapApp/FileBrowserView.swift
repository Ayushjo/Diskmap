import AppKit
import DiskMapCore
import SwiftUI

/// Explore → File Browser: a storage-aware Finder. The current folder is the
/// page; the inspector shows only the selected row.
/// Performance: never walk the full subtree on the main thread.
struct FileBrowserView: View {
    @ObservedObject var model: ScanModel
    @Environment(\.diskMapContentWidth) private var contentWidth
    let tree: FileTree
    let rootURL: URL

    enum SortMode: String, CaseIterable, Identifiable {
        case size, name, modified, kind
        var id: String { rawValue }
        var title: String {
            switch self {
            case .size: return "Largest"
            case .name: return "Name"
            case .modified: return "Recently modified"
            case .kind: return "Kind"
            }
        }
    }

    @State private var query = ""
    @State private var sortMode: SortMode = .size
    @State private var selectedID: Int32?
    @State private var history: [Int32] = [0]
    @State private var historyIndex: Int = 0
    @State private var showInspector = true

    /// Composition of the current folder, filled off the main thread.
    @State private var folderComposition: [FileTypeTotals] = []
    @State private var compositionCache: [Int32: [FileTypeTotals]] = [:]
    @State private var compositionTask: Task<Void, Never>?

    private var totals: [Int64] { model.selectedTotals }

    private var currentID: Int32 {
        guard historyIndex >= 0, historyIndex < history.count else { return model.currentNode }
        return history[historyIndex]
    }

    private var folderBytes: Int64 {
        let i = Int(currentID)
        guard i >= 0, i < totals.count else { return 0 }
        return totals[i]
    }

    private var itemCount: Int {
        let i = Int(currentID)
        let files = model.descendantFileCounts.indices.contains(i) ? model.descendantFileCounts[i] : 0
        let folders = model.descendantFolderCounts.indices.contains(i) ? model.descendantFolderCounts[i] : 0
        return max(0, files + folders)
    }

    private var rawChildren: [(id: Int32, size: Int64)] {
        guard currentID >= 0, Int(currentID) < tree.count, totals.count == tree.count else { return [] }
        return tree.children(of: currentID, totals: totals)
    }

    private var rows: [(id: Int32, size: Int64)] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var list = rawChildren
        if !q.isEmpty {
            list = list.filter { tree.name(of: $0.id).lowercased().contains(q) }
        }
        switch sortMode {
        case .size:
            list.sort { $0.size > $1.size }
        case .name:
            list.sort { tree.name(of: $0.id).localizedCaseInsensitiveCompare(tree.name(of: $1.id)) == .orderedAscending }
        case .modified:
            list.sort { tree.modifiedDay[Int($0.id)] > tree.modifiedDay[Int($1.id)] }
        case .kind:
            list.sort {
                let a = kindTitle(of: $0.id), b = kindTitle(of: $1.id)
                return a != b ? a < b : $0.size > $1.size
            }
        }
        return list
    }

    /// The inspected row — only ever a child of the current folder.
    private var inspectedID: Int32? {
        guard let selectedID, selectedID >= 0, Int(selectedID) < tree.count,
              tree.parent[Int(selectedID)] == currentID else { return nil }
        return selectedID
    }

    private var canGoBack: Bool { historyIndex > 0 }
    private var canGoForward: Bool { historyIndex + 1 < history.count }

    var body: some View {
        Group {
            if showInspector {
                AdaptiveInspectorSplit(windowWidth: contentWidth, inspectionToken: selectedID.map(String.init),
                                       main: mainColumn, inspector: inspector)
            } else {
                mainColumn
            }
        }
        .background(DiskMapTheme.canvas)
        .onAppear {
            syncFromModel()
            scheduleFolderComposition(for: currentID)
        }
        .onChange(of: model.currentNode) { _, newValue in
            if newValue != currentID { jumpTo(newValue, recordHistory: true) }
        }
        .onChange(of: model.selectedNode) { _, newValue in
            if newValue != selectedID, newValue >= 0, Int(newValue) < tree.count, tree.parent[Int(newValue)] == currentID {
                selectedID = newValue
            }
        }
        .onDisappear { compositionTask?.cancel() }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                toolbar
                PageHeader(eyebrow: "Explore · File Browser", title: tree.name(of: currentID)) {
                    HeaderSummary(parts: [ByteFormat.string(folderBytes), countLabel(itemCount, "item")])
                }
                composition
                HStack(spacing: 10) {
                    DiskMapSearchField(placeholder: "Search in this folder", text: $query)
                        .frame(maxWidth: 300)
                    Spacer(minLength: 8)
                    DiskMapMenu(label: "Sort", options: SortMode.allCases, selection: $sortMode, title: { $0.title })
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 4)
            columnHeader
            if rows.isEmpty {
                DiskMapEmptyState(symbol: "folder",
                                  title: rawChildren.isEmpty ? "This folder is empty" : "Nothing matches",
                                  message: rawChildren.isEmpty ? "Nothing to show here in this scan." : "Clear the search.")
            } else {
                list
            }
            NodeSelectionToolbar(model: model)
        }
    }

    // MARK: Chrome

    private var toolbar: some View {
        HStack(spacing: 4) {
            Button(action: goBack) { Label("Back", systemImage: "chevron.left") }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!canGoBack)
                .help("Back")
            Button(action: goForward) { Label("Forward", systemImage: "chevron.right") }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!canGoForward)
                .help("Forward")
            // The current folder is the page title just below, so the path stops at its parent.
            BreadcrumbBar(tree: tree, currentNode: currentID, jump: { jumpTo($0, recordHistory: true) }, includeCurrent: false)
                .padding(.leading, 6)
            Spacer(minLength: 6)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showInspector.toggle() }
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .help(showInspector ? "Hide inspector" : "Show inspector")
        }
        .buttonStyle(IconButtonStyle())
    }

    /// The current folder's make-up: one bar and an inline legend.
    @ViewBuilder
    private var composition: some View {
        let parts = Array(folderComposition.prefix(6))
        let total = max(1, folderComposition.reduce(Int64(0)) { $0 + $1.bytes })
        if !parts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SegmentedStorageBar(segments: parts.map { (DiskMapTheme.hex($0.colorHex), Double($0.bytes) / Double(total)) })
                    .accessibilityHidden(true)
                FlowLayout(spacing: 14) {
                    ForEach(parts.prefix(5), id: \.categoryID) { part in
                        HStack(spacing: 5) {
                            Circle().fill(DiskMapTheme.hex(part.colorHex)).frame(width: 6, height: 6)
                            Text(part.label)
                                .font(DiskMapType.secondary)
                                .foregroundStyle(DiskMapTheme.ink2)
                            Text(ByteFormat.string(part.bytes))
                                .font(DiskMapType.figureSmall)
                                .foregroundStyle(DiskMapTheme.ink3)
                        }
                        .fixedSize()
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        } else {
            SegmentedStorageBar(segments: [(DiskMapTheme.line, 1)])
                .accessibilityHidden(true)
        }
    }

    private var columnHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 14 + 12 + 24, height: 1)
                ColumnHeaderLabel(title: "Name")
                ColumnHeaderLabel(title: "Kind", width: 92)
                ColumnHeaderLabel(title: "Modified", alignment: .trailing, width: 74)
                ColumnHeaderLabel(title: "Size", alignment: .trailing, width: 74 + 12 + 64)
            }
            .padding(.horizontal, 10 + 18)
            .frame(height: DiskMapMetric.tableHeaderHeight)
            Hairline()
        }
    }

    // MARK: List

    private var list: some View {
        // Sorted and measured once per draw, not once per row.
        let items = rows
        let maxSize = max(1, items.map(\.size).max() ?? 1)
        let ids = items.map(\.id)
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items, id: \.id) { row in
                    browserRow(row, ordered: ids, maxSize: maxSize)
                    RowSeparator(indent: 10 + 14 + 12 + 24 + 12)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 4)
        }
        .listKeyboard(
            ids: ids, selection: $selectedID,
            path: { tree.path(of: $0, root: rootURL).path },
            stage: { id in stage(id) },
            open: { id in openItem(id) },
            selectAll: { model.multiSelection = Set(ids) },
            clearSelection: { model.clearMultiSelection() }
        )
        .onChange(of: selectedID) { _, id in if let id { model.selectedNode = id } }
    }

    private func browserRow(_ row: (id: Int32, size: Int64), ordered: [Int32], maxSize: Int64) -> some View {
        let i = Int(row.id)
        let isDir = tree.isDirectory[i]
        let name = tree.name(of: row.id)
        let abs = tree.path(of: row.id, root: rootURL).path
        let kind = kindTitle(of: row.id)
        let inMulti = model.multiSelection.contains(row.id)
        let protected = SafetyClassifier.assess(path: abs, name: name, isDirectory: isDir).level == .protected
        let stageRow: (() -> Void)? = protected ? nil : { stage(row.id) }
        return Button {
            selectedID = row.id
            model.select(row.id, ordered: ordered)
        } label: {
            KitRow(title: name, subtitle: nil, selected: row.id == inspectedID || inMulti,
                   path: abs, onStage: stageRow, height: DiskMapSpace.row) {
                MultiSelectMark(on: inMulti)
                if isDir {
                    Image(systemName: "folder")
                        .font(.system(size: DiskMapType.scaled(14)))
                        .foregroundStyle(DiskMapTheme.ink2)
                        .frame(width: 24, height: 24)
                } else {
                    FileIdentityIcon(url: URL(fileURLWithPath: abs), size: 24)
                }
            } trailing: {
                TextColumn(text: kind, width: 92)
                MonoColumn(text: RelativeAge.short(day: tree.modifiedDay[i]), width: 74)
                ProportionBar(fraction: Double(row.size) / Double(maxSize))
                    .frame(width: 64)
                MonoColumn(text: ByteFormat.string(row.size), width: 74, emphasis: true)
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { openItem(row.id) })
        .accessibilityLabel("\(name), \(kind), \(ByteFormat.string(row.size)), modified \(RelativeAge.long(day: tree.modifiedDay[i]))")
        .accessibilityActions { if isDir { Button("Open") { openItem(row.id) } } }
        .rowActions(path: abs, stage: stageRow)
        .contextMenu { contextMenu(for: row.id) }
    }

    @ViewBuilder
    private func contextMenu(for id: Int32) -> some View {
        let abs = tree.path(of: id, root: rootURL).path
        if tree.isDirectory[Int(id)] {
            Button("Open") { openItem(id) }
            Button("Show in Visualize") {
                model.currentNode = id
                model.selectedNode = id
                model.destination = .visualize
            }
            Button("Show in Biggest Folders") {
                model.currentNode = id
                model.selectedNode = id
                model.destination = .biggestFolders
            }
        } else {
            Button("Show in Biggest Files") {
                model.folderFilterPath = (abs as NSString).deletingLastPathComponent
                model.destination = .biggestFiles
            }
        }
    }

    private var inspector: some View {
        Group {
            if let id = inspectedID {
                if tree.isDirectory[Int(id)] {
                    FolderInspector(model: model, tree: tree, rootURL: rootURL, id: id,
                                    reason: "File Browser: " + tree.name(of: id))
                } else {
                    FileInspector(model: model, tree: tree, rootURL: rootURL, id: id, size: totals[Int(id)],
                                  reason: "File Browser: " + tree.name(of: id))
                }
            } else {
                DiskMapEmptyState(symbol: "sidebar.right", title: "Select an item",
                                  message: "Click a row to see what it is and what you can do. Double-click a folder to open it.")
            }
        }
        .background(DiskMapTheme.canvas)
    }

    // MARK: Composition (async)

    private func scheduleFolderComposition(for id: Int32) {
        if let cached = compositionCache[id] {
            folderComposition = cached
            return
        }
        folderComposition = []
        compositionTask?.cancel()
        let tree = self.tree
        let totals = self.totals
        let categories = model.fileTypeCategories
        compositionTask = Task.detached(priority: .userInitiated) {
            let result = FileTypeCatalog.totals(under: id, in: tree, sizes: totals, categories: categories)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                compositionCache[id] = result
                if currentID == id { folderComposition = result }
            }
        }
    }

    // MARK: Navigation

    private func syncFromModel() {
        let start = model.currentNode
        history = [start]
        historyIndex = 0
        selectedID = nil
        model.currentNode = start
    }

    private func jumpTo(_ id: Int32, recordHistory: Bool) {
        guard id >= 0, Int(id) < tree.count else { return }
        if !tree.isDirectory[Int(id)] {
            // A file: open its folder and inspect it.
            let parent = tree.parent[Int(id)]
            if parent >= 0, parent != currentID { jumpTo(parent, recordHistory: recordHistory) }
            selectedID = id
            model.selectedNode = id
            return
        }
        if recordHistory {
            if historyIndex < history.count - 1 { history = Array(history.prefix(historyIndex + 1)) }
            if history.last != id { history.append(id) }
            historyIndex = history.count - 1
        }
        model.currentNode = id
        selectedID = nil
        model.clearMultiSelection()
        scheduleFolderComposition(for: id)
    }

    private func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        land(on: history[historyIndex])
    }

    private func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        land(on: history[historyIndex])
    }

    private func land(on id: Int32) {
        model.currentNode = id
        selectedID = nil
        scheduleFolderComposition(for: id)
    }

    private func openItem(_ id: Int32) {
        if tree.isDirectory[Int(id)] {
            jumpTo(id, recordHistory: true)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([tree.path(of: id, root: rootURL)])
        }
    }

    private func kindTitle(of id: Int32) -> String {
        if tree.isDirectory[Int(id)] { return "Folder" }
        return FileKind.classify(fileName: tree.name(of: id), path: tree.path(of: id, root: rootURL).path).title
    }

    private func stage(_ id: Int32) {
        let size = Int(id) < totals.count ? totals[Int(id)] : 0
        model.stageRow(path: tree.path(of: id, root: rootURL).path, size: size, reason: "File Browser: " + tree.name(of: id))
    }
}
