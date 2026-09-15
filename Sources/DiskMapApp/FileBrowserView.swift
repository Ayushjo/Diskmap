import AppKit
import DiskMapCore
import SwiftUI

/// Explore → File Browser: storage-aware Finder (ref DiskMapFileBrowser.png).
/// Performance: never walk the full subtree on the main thread for selection.
struct FileBrowserView: View {
    @ObservedObject var model: ScanModel
    @Environment(\.diskMapContentWidth) private var contentWidth
    let tree: FileTree
    let rootURL: URL
    var onOpenCleanup: () -> Void = {}

    enum SortMode: String, CaseIterable, Identifiable {
        case size, name, modified, kind
        var id: String { rawValue }
        var title: String {
            switch self {
            case .size: return "Size (Largest)"
            case .name: return "Name"
            case .modified: return "Modified"
            case .kind: return "Kind"
            }
        }
    }

    @State private var query = ""
    @State private var sortMode: SortMode = .size
    @State private var checked: Set<Int32> = []
    @State private var selectedID: Int32?
    @State private var history: [Int32] = [0]
    @State private var historyIndex: Int = 0
    @State private var showInspector = true

    /// Composition for the *current* folder only — filled asynchronously.
    @State private var folderComposition: [FileTypeTotals] = []
    @State private var compositionLoading = false
    @State private var compositionCache: [Int32: [FileTypeTotals]] = [:]
    @State private var compositionTask: Task<Void, Never>?

    /// Selected-folder composition (inspector) — also async/cached.
    @State private var selectedComposition: [FileTypeTotals] = []
    @State private var selectedCompositionLoading = false
    @State private var selectedCompositionTask: Task<Void, Never>?

    private var totals: [Int64] { model.selectedTotals }

    private var usedDenominator: Int64 {
        if let vol = model.analysis.volume { return max(1, Int64(vol.usedBytes)) }
        return max(1, model.analysis.scannedBytes)
    }

    private var currentID: Int32 {
        guard historyIndex >= 0, historyIndex < history.count else { return model.currentNode }
        return history[historyIndex]
    }

    private var folderBytes: Int64 {
        let i = Int(currentID)
        guard i >= 0, i < totals.count else { return 0 }
        return totals[i]
    }

    private var folderName: String {
        if currentID == 0 {
            return VolumeStats.forPath(rootURL.path)?.volumeName ?? tree.name(of: 0)
        }
        return tree.name(of: currentID)
    }

    private var fileCount: Int {
        let i = Int(currentID)
        return model.descendantFileCounts.indices.contains(i) ? model.descendantFileCounts[i] : 0
    }

    private var folderCount: Int {
        let i = Int(currentID)
        return model.descendantFolderCounts.indices.contains(i) ? model.descendantFolderCounts[i] : 0
    }

    private var itemCount: Int { max(0, fileCount + folderCount) }

    private var rawChildren: [(id: Int32, size: Int64)] {
        guard currentID >= 0,
              Int(currentID) < tree.count,
              totals.count == tree.count else { return [] }
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
            list.sort {
                tree.name(of: $0.id).localizedCaseInsensitiveCompare(tree.name(of: $1.id)) == .orderedAscending
            }
        case .modified:
            list.sort { tree.modifiedDay[Int($0.id)] > tree.modifiedDay[Int($1.id)] }
        case .kind:
            list.sort {
                let a = kindTitle(of: $0.id)
                let b = kindTitle(of: $1.id)
                if a != b { return a < b }
                return $0.size > $1.size
            }
        }
        return list
    }

    private var activeID: Int32 {
        if let selectedID, selectedID >= 0, Int(selectedID) < tree.count { return selectedID }
        return currentID
    }

    private var maxRowSize: Int64 {
        max(1, rows.map(\.size).max() ?? 1)
    }

    private var canGoBack: Bool { historyIndex > 0 }
    private var canGoForward: Bool { historyIndex + 1 < history.count }

    var body: some View {
        HStack(spacing: 0) {
            mainColumn
            if showInspector {
                Divider().overlay(DiskMapTheme.cardStroke)
                inspector
                    .frame(width: DiskMapLayout.inspectorWidth(for: contentWidth))
            }
        }
        .background(DiskMapTheme.cream)
        .onAppear {
            syncFromModel()
            scheduleFolderComposition(for: currentID)
            scheduleSelectedComposition(for: activeID)
        }
        .onChange(of: model.currentNode) { _, newValue in
            if newValue != currentID {
                jumpTo(newValue, recordHistory: true)
            }
        }
        .onChange(of: model.selectedNode) { _, newValue in
            if newValue != selectedID {
                selectedID = newValue
                scheduleSelectedComposition(for: newValue)
            }
        }
        .onDisappear {
            compositionTask?.cancel()
            selectedCompositionTask?.cancel()
        }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageTitle
            toolbar
            folderCard
            controls
            listHeader
            Group {
                if model.isScanning {
                    ProgressView("Indexing… File Browser uses the finished scan.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rows.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if !checked.isEmpty {
                selectionBar
            }
        }
    }

    // MARK: - Chrome

    private var pageTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("File Browser")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(DiskMapTheme.ink)
            Text("Explore your filesystem with storage context. Select an item to understand it.")
                .font(.system(size: 12))
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                navButton("chevron.left", enabled: canGoBack, help: "Back") { goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                navButton("chevron.right", enabled: canGoForward, help: "Forward") { goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                navButton("house", enabled: true, help: "Scan root") { jumpTo(0, recordHistory: true) }
            }
            breadcrumb
            Spacer(minLength: 6)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showInspector.toggle() }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(showInspector ? DiskMapTheme.ink : DiskMapTheme.mutedLabel)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(showInspector ? DiskMapTheme.navSelected : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .help("Toggle inspector")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func navButton(_ system: String, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(enabled ? DiskMapTheme.ink : DiskMapTheme.mutedLabel.opacity(0.45))
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(DiskMapTheme.cardFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                let crumbs = tree.ancestorIDs(of: currentID)
                ForEach(Array(crumbs.enumerated()), id: \.element) { i, id in
                    if i > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                    Button { jumpTo(id, recordHistory: true) } label: {
                        Text(crumbLabel(id))
                            .font(.system(size: 12, weight: id == currentID ? .semibold : .medium))
                            .foregroundStyle(id == currentID ? DiskMapTheme.ink : DiskMapTheme.info)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func crumbLabel(_ id: Int32) -> String {
        if id == 0 {
            return VolumeStats.forPath(rootURL.path)?.volumeName ?? tree.name(of: id)
        }
        return tree.name(of: id)
    }

    // MARK: - Folder card (reference)

    private var folderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color(red: 0.32, green: 0.56, blue: 0.98))
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color(red: 0.32, green: 0.56, blue: 0.98).opacity(0.12))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(folderName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                        .lineLimit(1)
                    Text("\(ByteFormat.string(folderBytes)) · \(formatCount(itemCount)) items")
                        .font(.system(size: 12))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
                Spacer(minLength: 8)
                if compositionLoading && folderComposition.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if !folderComposition.isEmpty {
                compositionBar(folderComposition)
                compositionLegend(folderComposition)
            } else if !compositionLoading {
                Text("Composition unavailable for this folder yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DiskMapTheme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func compositionBar(_ rows: [FileTypeTotals]) -> some View {
        let total = max(1, rows.reduce(Int64(0)) { $0 + $1.bytes })
        return Color.clear
            .frame(height: 10)
            .overlay {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(Array(rows.prefix(6)), id: \.categoryID) { row in
                            let w = geo.size.width * CGFloat(Double(row.bytes) / Double(total))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(DiskMapTheme.hex(row.colorHex))
                                .frame(width: max(row.bytes > 0 ? 4 : 0, w))
                        }
                    }
                }
            }
    }

    private func compositionLegend(_ rows: [FileTypeTotals]) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(rows.prefix(5)), id: \.categoryID) { row in
                HStack(spacing: 5) {
                    Circle().fill(DiskMapTheme.hex(row.colorHex)).frame(width: 7, height: 7)
                    Text("\(row.label) \(ByteFormat.string(row.bytes))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DiskMapTheme.ink)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Controls + list

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                TextField("Search in this folder…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(DiskMapTheme.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                    )
            )

            Menu {
                ForEach(SortMode.allCases) { mode in
                    Button(mode.title) { sortMode = mode }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Sort: \(sortMode.title)")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(DiskMapTheme.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(DiskMapTheme.cardFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                        )
                )
            }
            .menuStyle(.borderlessButton)

            Image(systemName: "list.bullet")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(DiskMapTheme.ink))
                .help("List view")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // Shared column metrics — header and rows MUST use the same widths.
    private enum Col {
        static let check: CGFloat = 20
        static let icon: CGFloat = 22
        static let kind: CGFloat = 90
        static let sizeBar: CGFloat = 80
        static let sizeText: CGFloat = 78
        static let modified: CGFloat = 104
        static let spacing: CGFloat = 10
        static let hPad: CGFloat = 16
    }

    private var listHeader: some View {
        HStack(spacing: Col.spacing) {
            Color.clear.frame(width: Col.check)
            Color.clear.frame(width: Col.icon)
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Kind")
                .frame(width: Col.kind, alignment: .leading)
            Text("Size")
                .frame(width: Col.sizeBar + Col.spacing + Col.sizeText, alignment: .leading)
            Text("Modified")
                .frame(width: Col.modified, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(DiskMapTheme.mutedLabel)
        .padding(.horizontal, Col.hPad)
        .padding(.vertical, 8)
        .background(DiskMapTheme.cardFill)
        .overlay(alignment: .bottom) { Divider().overlay(DiskMapTheme.cardStroke) }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows, id: \.id) { row in
                    browserRow(row)
                    Divider()
                        .overlay(DiskMapTheme.cardStroke.opacity(0.65))
                        .padding(.leading, Col.hPad + Col.check + Col.spacing + Col.icon + Col.spacing)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func browserRow(_ row: (id: Int32, size: Int64)) -> some View {
        let isDir = tree.isDirectory[Int(row.id)]
        let name = tree.name(of: row.id)
        let selected = row.id == activeID
        let on = checked.contains(row.id)
        let frac = Double(row.size) / Double(maxRowSize)
        let kind = kindTitle(of: row.id)
        let modified = relativeModified(tree.modifiedDay[Int(row.id)])
        let tint = kindTint(of: row.id)
        let absPath = tree.path(of: row.id, root: rootURL).path
        let symbol = isDir ? "folder.fill" : FileKind.classify(fileName: name, path: absPath).symbolName

        return HStack(spacing: Col.spacing) {
            Button {
                if on { checked.remove(row.id) } else { checked.insert(row.id) }
            } label: {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(on ? DiskMapTheme.ink : DiskMapTheme.mutedLabel)
            }
            .buttonStyle(.plain)
            .frame(width: Col.check, height: 28)

            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isDir ? Color(red: 0.32, green: 0.56, blue: 0.98) : tint)
                .frame(width: Col.icon, height: 22)

            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DiskMapTheme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(name)

            Text(kind)
                .font(.system(size: 12))
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .lineLimit(1)
                .frame(width: Col.kind, alignment: .leading)

            // Bar and size are SIDE BY SIDE — never stacked/overlapping.
            ProportionBar(fraction: frac, tint: Color(red: 0.32, green: 0.56, blue: 0.98).opacity(0.55))
                .frame(width: Col.sizeBar, height: 6)
                .clipShape(Capsule())

            Text(ByteFormat.string(row.size))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(DiskMapTheme.ink)
                .frame(width: Col.sizeText, alignment: .trailing)
                .lineLimit(1)

            Text(modified)
                .font(.system(size: 12))
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .frame(width: Col.modified, alignment: .trailing)
                .lineLimit(1)
        }
        .padding(.horizontal, Col.hPad)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? DiskMapTheme.ink.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openItem(row.id) }
        .onTapGesture(count: 1) { selectRow(row.id) }
        .contextMenu { contextMenu(for: row.id) }
    }

    private func selectRow(_ id: Int32) {
        selectedID = id
        model.selectedNode = id
        scheduleSelectedComposition(for: id)
    }

    @ViewBuilder
    private func contextMenu(for id: Int32) -> some View {
        let isDir = tree.isDirectory[Int(id)]
        let abs = tree.path(of: id, root: rootURL).path
        let safety = SafetyClassifier.assess(path: abs, name: tree.name(of: id), isDirectory: isDir)

        if isDir {
            Button("Open") { openItem(id) }
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: abs)])
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(CanonicalPath.displayPath(absolutePath: abs), forType: .string)
            model.showToast("Path copied")
        }
        Divider()
        if isDir {
            Button("Visualize") {
                model.currentNode = id
                model.selectedNode = id
                model.destination = .visualize
            }
            Button("View in Biggest Folders") {
                model.currentNode = id
                model.selectedNode = id
                model.destination = .biggestFolders
            }
        } else {
            Button("View in Biggest Files") {
                model.folderFilterPath = (abs as NSString).deletingLastPathComponent
                model.destination = .biggestFiles
            }
        }
        if safety.level != .protected {
            Divider()
            Button("Add to Cleanup") {
                Task { await stageOne(id) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Text(rawChildren.isEmpty ? "This folder is empty" : "No items match this filter")
                .font(DiskMapType.section)
            Text(rawChildren.isEmpty
                 ? "Nothing to show here in the current scan."
                 : "Clear the filter or change sort.")
                .font(DiskMapType.body)
                .foregroundStyle(DiskMapTheme.mutedLabel)
        }
        .foregroundStyle(DiskMapTheme.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var selectionBar: some View {
        HStack {
            Text("\(formatCount(checked.count)) selected")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button("Clear") { checked.removeAll() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Button("Add to Cleanup") {
                Task { await stageChecked() }
            }
            .buttonStyle(InkButtonStyle(filled: true))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(DiskMapTheme.cardFill)
        .overlay(alignment: .top) { Divider().overlay(DiskMapTheme.cardStroke) }
    }

    // MARK: - Inspector (lightweight — no FolderInsight.build)

    private var inspector: some View {
        Group {
            if activeID >= 0, Int(activeID) < tree.count, tree.isDirectory[Int(activeID)] {
                FolderBrowserInspector(
                    model: model,
                    tree: tree,
                    rootURL: rootURL,
                    nodeID: activeID,
                    usedDenominator: usedDenominator,
                    composition: selectedComposition,
                    compositionLoading: selectedCompositionLoading,
                    onOpen: { jumpTo(activeID, recordHistory: true) },
                    onOpenCleanup: onOpenCleanup
                )
            } else if activeID >= 0, Int(activeID) < tree.count {
                FileBrowserInspector(
                    model: model,
                    tree: tree,
                    rootURL: rootURL,
                    nodeID: activeID,
                    usedDenominator: usedDenominator,
                    onOpenCleanup: onOpenCleanup
                )
            } else {
                Color.clear
            }
        }
        .background(DiskMapTheme.cardFill)
    }

    // MARK: - Composition cache (async)

    private func scheduleFolderComposition(for id: Int32) {
        if let cached = compositionCache[id] {
            folderComposition = cached
            compositionLoading = false
            return
        }
        folderComposition = []
        compositionLoading = true
        compositionTask?.cancel()
        let tree = self.tree
        let totals = self.totals
        let categories = model.fileTypeCategories
        compositionTask = Task.detached(priority: .userInitiated) {
            let result = FileTypeCatalog.totals(under: id, in: tree, sizes: totals, categories: categories)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                compositionCache[id] = result
                if currentID == id {
                    folderComposition = result
                    compositionLoading = false
                }
            }
        }
    }

    private func scheduleSelectedComposition(for id: Int32) {
        guard id >= 0, Int(id) < tree.count, tree.isDirectory[Int(id)] else {
            selectedComposition = []
            selectedCompositionLoading = false
            selectedCompositionTask?.cancel()
            return
        }
        if let cached = compositionCache[id] {
            selectedComposition = cached
            selectedCompositionLoading = false
            return
        }
        // Reuse in-flight folder composition when selecting current folder.
        if id == currentID, !folderComposition.isEmpty {
            selectedComposition = folderComposition
            selectedCompositionLoading = false
            return
        }
        selectedComposition = []
        selectedCompositionLoading = true
        selectedCompositionTask?.cancel()
        let tree = self.tree
        let totals = self.totals
        let categories = model.fileTypeCategories
        selectedCompositionTask = Task.detached(priority: .utility) {
            let result = FileTypeCatalog.totals(under: id, in: tree, sizes: totals, categories: categories)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                compositionCache[id] = result
                if activeID == id {
                    selectedComposition = result
                    selectedCompositionLoading = false
                }
            }
        }
    }

    // MARK: - Navigation

    private func syncFromModel() {
        let start = model.currentNode
        history = [start]
        historyIndex = 0
        selectedID = model.selectedNode >= 0 ? model.selectedNode : start
        model.currentNode = start
    }

    private func jumpTo(_ id: Int32, recordHistory: Bool) {
        guard id >= 0, Int(id) < tree.count else { return }
        if !tree.isDirectory[Int(id)] {
            selectedID = id
            model.selectedNode = id
            return
        }
        if recordHistory {
            if historyIndex < history.count - 1 {
                history = Array(history.prefix(historyIndex + 1))
            }
            if history.last != id {
                history.append(id)
                historyIndex = history.count - 1
            } else {
                historyIndex = history.count - 1
            }
        }
        model.currentNode = id
        selectedID = id
        model.selectedNode = id
        checked.removeAll()
        scheduleFolderComposition(for: id)
        scheduleSelectedComposition(for: id)
    }

    private func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        let id = history[historyIndex]
        model.currentNode = id
        selectedID = id
        model.selectedNode = id
        scheduleFolderComposition(for: id)
        scheduleSelectedComposition(for: id)
    }

    private func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        let id = history[historyIndex]
        model.currentNode = id
        selectedID = id
        model.selectedNode = id
        scheduleFolderComposition(for: id)
        scheduleSelectedComposition(for: id)
    }

    private func openItem(_ id: Int32) {
        if tree.isDirectory[Int(id)] {
            jumpTo(id, recordHistory: true)
        } else {
            let abs = tree.path(of: id, root: rootURL).path
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: abs)])
        }
    }

    private func kindTitle(of id: Int32) -> String {
        if tree.isDirectory[Int(id)] { return "Folder" }
        let name = tree.name(of: id)
        let abs = tree.path(of: id, root: rootURL).path
        return FileKind.classify(fileName: name, path: abs).title
    }

    private func kindTint(of id: Int32) -> Color {
        if tree.isDirectory[Int(id)] {
            return Color(red: 0.32, green: 0.56, blue: 0.98)
        }
        let name = tree.name(of: id)
        let abs = tree.path(of: id, root: rootURL).path
        switch FileKind.classify(fileName: name, path: abs) {
        case .video: return Color(red: 0.62, green: 0.40, blue: 0.90)
        case .archive: return Color(red: 0.95, green: 0.55, blue: 0.25)
        case .diskImage: return Color(red: 0.30, green: 0.55, blue: 0.95)
        case .document: return Color(red: 0.25, green: 0.70, blue: 0.55)
        case .application: return Color(red: 0.35, green: 0.55, blue: 0.95)
        default: return DiskMapTheme.mutedLabel
        }
    }

    private func relativeModified(_ day: Int32) -> String {
        guard day > 0 else { return "—" }
        let today = AgeMap.today()
        let age = today - day
        if age <= 0 { return "Today" }
        if age == 1 { return "Yesterday" }
        if age < 30 { return "\(age) days ago" }
        if age < 365 {
            let months = max(1, age / 30)
            return months == 1 ? "1 month ago" : "\(months) months ago"
        }
        let years = max(1, age / 365)
        return years == 1 ? "1 year ago" : "\(years) years ago"
    }

    private func formatCount(_ n: Int) -> String {
        n.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    private func stageChecked() async {
        var ok = 0
        for id in checked {
            if await stageOne(id, openSheet: false) { ok += 1 }
        }
        await model.refreshQueue()
        model.showToast(ok > 0 ? "Added \(ok) to cleanup review" : "Nothing staged")
        if ok > 0 { onOpenCleanup() }
    }

    @discardableResult
    private func stageOne(_ id: Int32, openSheet: Bool = true) async -> Bool {
        let isDir = tree.isDirectory[Int(id)]
        let abs = tree.path(of: id, root: rootURL).path
        let name = tree.name(of: id)
        let safety = SafetyClassifier.assess(path: abs, name: name, isDirectory: isDir)
        guard safety.level != .protected else {
            model.showToast("Protected — not staged")
            return false
        }
        let url = URL(fileURLWithPath: abs, isDirectory: isDir).standardizedFileURL
        if model.isStaged(url) {
            if openSheet { onOpenCleanup() }
            return true
        }
        let size = Int(id) < totals.count ? totals[Int(id)] : 0
        let ok = await model.cleanupQueue.stage(url, size: size, reason: "File Browser: " + name)
        await model.refreshQueue()
        if openSheet {
            model.showToast(ok ? "Added to cleanup review" : "Blocked by safety rules")
            if ok { onOpenCleanup() }
        }
        return ok
    }
}

// MARK: - Folder inspector (O(1) + O(children) — no full-tree FolderInsight)

private struct FolderBrowserInspector: View {
    @ObservedObject var model: ScanModel
    let tree: FileTree
    let rootURL: URL
    let nodeID: Int32
    let usedDenominator: Int64
    let composition: [FileTypeTotals]
    let compositionLoading: Bool
    var onOpen: () -> Void
    var onOpenCleanup: () -> Void
    @State private var showTechnical = false

    private var name: String {
        if nodeID == 0 {
            return VolumeStats.forPath(rootURL.path)?.volumeName ?? tree.name(of: 0)
        }
        return tree.name(of: nodeID)
    }

    private var abs: String { tree.path(of: nodeID, root: rootURL).path }
    private var displayPath: String { CanonicalPath.displayPath(absolutePath: abs) }

    private var bytes: Int64 {
        let i = Int(nodeID)
        return i < model.selectedTotals.count ? model.selectedTotals[i] : 0
    }

    private var fileCount: Int {
        let i = Int(nodeID)
        return model.descendantFileCounts.indices.contains(i) ? model.descendantFileCounts[i] : 0
    }

    private var folderCount: Int {
        let i = Int(nodeID)
        return model.descendantFolderCounts.indices.contains(i) ? model.descendantFolderCounts[i] : 0
    }

    private var safety: SafetyAssessment {
        SafetyClassifier.assess(path: abs, name: name, isDirectory: true)
    }

    private var topChildren: [(id: Int32, size: Int64)] {
        Array(
            tree.children(of: nodeID, totals: model.selectedTotals)
                .sorted { $0.size > $1.size }
                .prefix(5)
        )
    }

    private var whyLarge: String {
        if composition.isEmpty {
            return "Calculating what’s inside…"
        }
        let top = composition.prefix(3).map { "\($0.label.lowercased()) (\(ByteFormat.string($0.bytes)))" }
        if top.isEmpty { return "This folder holds mixed content." }
        return "Mostly " + top.joined(separator: ", ") + "."
    }

    private var modified: String {
        let day = tree.modifiedDay[Int(nodeID)]
        guard day > 0 else { return "—" }
        let today = AgeMap.today()
        let age = today - day
        if age <= 0 { return "Today" }
        if age == 1 { return "Yesterday" }
        if age < 30 { return "\(age) days ago" }
        if age < 365 {
            let months = max(1, age / 30)
            return months == 1 ? "1 month ago" : "\(months) months ago"
        }
        let years = max(1, age / 365)
        return years == 1 ? "1 year ago" : "\(years) years ago"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color(red: 0.32, green: 0.56, blue: 0.98))
                        .frame(width: 52, height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(red: 0.32, green: 0.56, blue: 0.98).opacity(0.12))
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DiskMapTheme.ink)
                        Text(ByteFormat.string(bytes))
                            .font(.system(size: 24, weight: .semibold).monospacedDigit())
                        Text(String(format: "%.1f%% of used storage", min(100, Double(bytes) / Double(usedDenominator) * 100)))
                            .font(.system(size: 11))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                }

                meta("Location", displayPath)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Size")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                    Text(ByteFormat.string(bytes))
                        .font(.system(size: 12, weight: .semibold))
                    ProportionBar(
                        fraction: Double(bytes) / Double(usedDenominator),
                        tint: Color(red: 0.32, green: 0.56, blue: 0.98).opacity(0.45)
                    )
                    .frame(height: 4)
                }
                meta(
                    "Items",
                    "\(formatCount(fileCount)) files · \(formatCount(folderCount)) folders"
                )
                meta("Modified", modified)

                VStack(alignment: .leading, spacing: 8) {
                    Text("What's inside?")
                        .font(.system(size: 12, weight: .semibold))
                    if compositionLoading && composition.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                    } else if composition.isEmpty {
                        Text("No categorized files found under this folder.")
                            .font(.system(size: 11))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    } else {
                        ForEach(Array(composition.prefix(5)), id: \.categoryID) { row in
                            HStack(spacing: 8) {
                                Circle().fill(DiskMapTheme.hex(row.colorHex)).frame(width: 8, height: 8)
                                Text(row.label)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(ByteFormat.string(row.bytes))
                                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                                    .foregroundStyle(DiskMapTheme.mutedLabel)
                            }
                            ProportionBar(
                                fraction: Double(row.bytes) / Double(max(1, bytes)),
                                tint: DiskMapTheme.hex(row.colorHex)
                            )
                            .frame(height: 3)
                        }
                    }
                }

                if !topChildren.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Largest items")
                            .font(.system(size: 12, weight: .semibold))
                        ForEach(topChildren, id: \.id) { child in
                            Button {
                                model.selectedNode = child.id
                            } label: {
                                HStack {
                                    Text(tree.name(of: child.id))
                                        .font(.system(size: 12))
                                        .foregroundStyle(DiskMapTheme.ink)
                                        .lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(ByteFormat.string(child.size))
                                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                                        .foregroundStyle(DiskMapTheme.mutedLabel)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(Color(red: 0.85, green: 0.55, blue: 0.15))
                    Text(whyLarge)
                        .font(.system(size: 12))
                        .foregroundStyle(DiskMapTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(red: 1.0, green: 0.96, blue: 0.90))
                )

                if safety.level == .protected {
                    Text("Protected / system location. Diskmap does not recommend deleting items here.")
                        .font(.system(size: 11))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DisclosureGroup("Technical details", isExpanded: $showTechnical) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(abs)
                            .font(.system(size: 11).monospaced())
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                            .textSelection(.enabled)
                        Text("Node \(nodeID)")
                            .font(.system(size: 11))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                    .padding(.top, 6)
                }
                .font(.system(size: 12, weight: .semibold))

                VStack(spacing: 8) {
                    if nodeID != model.currentNode {
                        Button("Open Folder") { onOpen() }
                            .buttonStyle(PrimaryCTAStyle(fullWidth: true))
                    }
                    Button("Open in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: abs)])
                    }
                    .buttonStyle(
                        nodeID == model.currentNode
                            ? AnyButtonStyle(PrimaryCTAStyle(fullWidth: true))
                            : AnyButtonStyle(InkButtonStyle(filled: false, fullWidth: true))
                    )

                    Button("Visualize this folder") {
                        model.currentNode = nodeID
                        model.selectedNode = nodeID
                        model.destination = .visualize
                    }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))

                    Button("View in Biggest Folders") {
                        model.currentNode = nodeID
                        model.selectedNode = nodeID
                        model.destination = .biggestFolders
                    }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))

                    if safety.level != .protected {
                        Button(model.isStaged(URL(fileURLWithPath: abs, isDirectory: true))
                               ? "Open Cleanup Queue"
                               : "Add to Cleanup") {
                            Task { await stage() }
                        }
                        .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                    }

                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(displayPath, forType: .string)
                        model.showToast("Path copied")
                    }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                }
            }
            .padding(16)
        }
    }

    private func meta(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(DiskMapTheme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func formatCount(_ n: Int) -> String {
        n.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    private func stage() async {
        let url = URL(fileURLWithPath: abs, isDirectory: true).standardizedFileURL
        if model.isStaged(url) {
            onOpenCleanup()
            return
        }
        let ok = await model.cleanupQueue.stage(url, size: bytes, reason: "File Browser: " + name)
        await model.refreshQueue()
        model.showToast(ok ? "Added to cleanup review" : "Blocked by safety rules")
        if ok { onOpenCleanup() }
    }
}

/// Type-erase button styles so we can branch without ternary type mismatch.
private struct AnyButtonStyle: ButtonStyle {
    private let _make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) {
        _make = { AnyView(style.makeBody(configuration: $0)) }
    }
    func makeBody(configuration: Configuration) -> some View {
        _make(configuration)
    }
}

// MARK: - File inspector

private struct FileBrowserInspector: View {
    @ObservedObject var model: ScanModel
    let tree: FileTree
    let rootURL: URL
    let nodeID: Int32
    let usedDenominator: Int64
    var onOpenCleanup: () -> Void

    private var name: String { tree.name(of: nodeID) }
    private var abs: String { tree.path(of: nodeID, root: rootURL).path }
    private var size: Int64 {
        let i = Int(nodeID)
        return i < model.selectedTotals.count ? model.selectedTotals[i] : 0
    }
    private var kind: FileKind { FileKind.classify(fileName: name, path: abs) }
    private var safety: SafetyAssessment {
        SafetyClassifier.assess(path: abs, name: name, isDirectory: false)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: kind.symbolName)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(DiskMapTheme.ink)
                        .frame(width: 52, height: 52)
                        .background(RoundedRectangle(cornerRadius: 12).fill(DiskMapTheme.ink.opacity(0.08)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DiskMapTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Text(ByteFormat.string(size))
                            .font(.system(size: 24, weight: .semibold).monospacedDigit())
                        Text(kind.title)
                            .font(.system(size: 11))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                }

                meta("Location", CanonicalPath.parentDisplay(of: abs))
                meta(
                    "Storage impact",
                    String(format: "%.1f%% of used storage", min(100, Double(size) / Double(usedDenominator) * 100))
                )
                meta("Modified", relativeModified(tree.modifiedDay[Int(nodeID)]))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Why is it large?")
                        .font(.system(size: 12, weight: .semibold))
                    Text(FileKind.whyLarge(kind: kind, name: name))
                        .font(.system(size: 12))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(red: 0.93, green: 0.95, blue: 0.99))
                )

                if safety.level == .protected {
                    Text("Not recommended for cleanup.")
                        .font(.system(size: 11))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }

                VStack(spacing: 8) {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: abs)])
                    }
                    .buttonStyle(PrimaryCTAStyle(fullWidth: true))

                    Button("Open Containing Folder") {
                        let parent = (abs as NSString).deletingLastPathComponent
                        NSWorkspace.shared.open(URL(fileURLWithPath: parent, isDirectory: true))
                    }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))

                    Button("View in Biggest Files") {
                        model.folderFilterPath = (abs as NSString).deletingLastPathComponent
                        model.destination = .biggestFiles
                    }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))

                    if safety.level != .protected {
                        Button(model.isStaged(URL(fileURLWithPath: abs)) ? "Open Cleanup Queue" : "Add to Cleanup") {
                            Task { await stage() }
                        }
                        .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                    }

                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(CanonicalPath.displayPath(absolutePath: abs), forType: .string)
                        model.showToast("Path copied")
                    }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                }
            }
            .padding(16)
        }
    }

    private func meta(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(DiskMapTheme.ink)
                .textSelection(.enabled)
        }
    }

    private func relativeModified(_ day: Int32) -> String {
        guard day > 0 else { return "—" }
        let today = AgeMap.today()
        let age = today - day
        if age <= 0 { return "Today" }
        if age == 1 { return "Yesterday" }
        if age < 30 { return "\(age) days ago" }
        if age < 365 {
            let months = max(1, age / 30)
            return months == 1 ? "1 month ago" : "\(months) months ago"
        }
        let years = max(1, age / 365)
        return years == 1 ? "1 year ago" : "\(years) years ago"
    }

    private func stage() async {
        let url = URL(fileURLWithPath: abs).standardizedFileURL
        if model.isStaged(url) {
            onOpenCleanup()
            return
        }
        let ok = await model.cleanupQueue.stage(url, size: size, reason: "File Browser: " + name)
        await model.refreshQueue()
        model.showToast(ok ? "Added to cleanup review" : "Blocked by safety rules")
        if ok { onOpenCleanup() }
    }
}
