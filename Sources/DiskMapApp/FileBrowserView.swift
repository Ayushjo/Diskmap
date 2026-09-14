import AppKit
import DiskMapCore
import SwiftUI

/// Explore → File Browser: storage-aware Finder (ref DiskMapFileBrowser.png).
/// Not ExploreShell — no secondary sidebar, no bottom largest strip, no viz toolbar.
struct FileBrowserView: View {
    @ObservedObject var model: ScanModel
    let tree: FileTree
    let rootURL: URL
    var onOpenCleanup: () -> Void = {}

    enum SortMode: String, CaseIterable, Identifiable {
        case size, name, modified, kind
        var id: String { rawValue }
        var title: String {
            switch self {
            case .size: return "Largest"
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
    @State private var showTechnical = false

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

    private var folderPath: String {
        tree.path(of: currentID, root: rootURL).path
    }

    private var folderDisplayPath: String {
        CanonicalPath.displayPath(absolutePath: folderPath)
    }

    private var fileCount: Int {
        let i = Int(currentID)
        return model.descendantFileCounts.indices.contains(i) ? model.descendantFileCounts[i] : 0
    }

    private var folderCount: Int {
        let i = Int(currentID)
        return model.descendantFolderCounts.indices.contains(i) ? model.descendantFolderCounts[i] : 0
    }

    private var itemCount: Int { fileCount + folderCount }

    private var composition: [FileTypeTotals] {
        FileTypeCatalog.totals(
            under: currentID,
            in: tree,
            sizes: totals,
            categories: model.fileTypeCategories
        )
    }

    private static let hiddenTechnical: Set<String> = [
        ".vol", ".file", "cores", "dev", "bin", "sbin", "Network", "automount",
        "home", "net",
    ]

    private var rawChildren: [(id: Int32, size: Int64)] {
        guard currentID >= 0,
              Int(currentID) < tree.count,
              totals.count == tree.count else { return [] }
        return tree.children(of: currentID, totals: totals)
    }

    private var rows: [(id: Int32, size: Int64)] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let atRoot = currentID == 0
        let scanningRoot = rootURL.path == "/" || rootURL.standardizedFileURL.path == "/"
        var list = rawChildren.filter { row in
            let name = tree.name(of: row.id)
            if atRoot, scanningRoot, !showTechnical {
                if row.size <= 0 { return false }
                if Self.hiddenTechnical.contains(name) { return false }
            }
            if q.isEmpty { return true }
            return name.lowercased().contains(q)
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
        if let selectedID, Int(selectedID) < tree.count { return selectedID }
        return currentID
    }

    private var canGoBack: Bool { historyIndex > 0 }
    private var canGoForward: Bool { historyIndex + 1 < history.count }

    var body: some View {
        HStack(spacing: 0) {
            mainColumn
            if showInspector {
                Divider().overlay(DiskMapTheme.cardStroke)
                inspector
                    .frame(width: 300)
            }
        }
        .background(DiskMapTheme.cream)
        .onAppear { syncFromModel() }
        .onChange(of: model.currentNode) { _, newValue in
            if newValue != currentID {
                jumpTo(newValue, recordHistory: true)
            }
        }
        .onChange(of: model.selectedNode) { _, newValue in
            if newValue != selectedID { selectedID = newValue }
        }
        .focusable()
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            folderHeader
            controls
            listHeader
            Divider().overlay(DiskMapTheme.cardStroke)
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

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Button { goBack() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(!canGoBack)
                .foregroundStyle(canGoBack ? DiskMapTheme.ink : DiskMapTheme.mutedLabel)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back")

                Button { goForward() } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(!canGoForward)
                .foregroundStyle(canGoForward ? DiskMapTheme.ink : DiskMapTheme.mutedLabel)
                .keyboardShortcut("]", modifiers: .command)
                .help("Forward")

                Button { jumpTo(0, recordHistory: true) } label: {
                    Image(systemName: "house")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DiskMapTheme.ink)
                .help("Scan root")
            }

            breadcrumb
            Spacer(minLength: 8)
            Button {
                showInspector.toggle()
            } label: {
                Image(systemName: showInspector ? "sidebar.right" : "sidebar.trailing")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .help("Toggle inspector")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(DiskMapTheme.cardFill.opacity(0.55))
        .overlay(alignment: .bottom) { Divider().overlay(DiskMapTheme.cardStroke) }
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
                    Button {
                        jumpTo(id, recordHistory: true)
                    } label: {
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

    // MARK: - Folder header

    private var folderHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color(red: 0.35, green: 0.55, blue: 0.95))
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(red: 0.35, green: 0.55, blue: 0.95).opacity(0.12))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(folderName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                        .lineLimit(1)
                    Text("\(ByteFormat.string(folderBytes)) · \(itemCount.formatted()) items")
                        .font(.system(size: 12))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
                Spacer(minLength: 8)
                if currentID == 0, let vol = model.analysis.volume {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(ByteFormat.string(Int64(vol.usedBytes))) used")
                            .font(.system(size: 12, weight: .semibold))
                        Text("\(ByteFormat.string(Int64(vol.freeBytes))) free")
                            .font(.system(size: 11))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                }
            }

            if !composition.isEmpty {
                compositionBar
                compositionLegend
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var compositionBar: some View {
        let total = max(1, composition.reduce(Int64(0)) { $0 + $1.bytes })
        return Color.clear
            .frame(height: 10)
            .overlay {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(Array(composition.prefix(6).enumerated()), id: \.element.categoryID) { _, row in
                            let w = geo.size.width * CGFloat(Double(row.bytes) / Double(total))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(DiskMapTheme.hex(row.colorHex))
                                .frame(width: max(row.bytes > 0 ? 4 : 0, w))
                        }
                    }
                }
            }
    }

    private var compositionLegend: some View {
        HStack(spacing: 12) {
            ForEach(Array(composition.prefix(5).enumerated()), id: \.element.categoryID) { _, row in
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

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                TextField("Filter this folder…", text: $query)
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

            if currentID == 0 {
                Toggle("Technical", isOn: $showTechnical)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var listHeader: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 22)
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Kind").frame(width: 100, alignment: .leading)
            Text("Size").frame(width: 150, alignment: .leading)
            Text("Modified").frame(width: 96, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(DiskMapTheme.mutedLabel)
        .padding(.horizontal, 24)
        .padding(.vertical, 7)
        .background(DiskMapTheme.cardFill.opacity(0.72))
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows, id: \.id) { row in
                    browserRow(row)
                    Rectangle()
                        .fill(DiskMapTheme.cardStroke.opacity(0.55))
                        .frame(height: 1)
                        .padding(.leading, 48)
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func browserRow(_ row: (id: Int32, size: Int64)) -> some View {
        let isDir = tree.isDirectory[Int(row.id)]
        let name = tree.name(of: row.id)
        let selected = row.id == activeID
        let on = checked.contains(row.id)
        let frac = Double(row.size) / Double(max(1, folderBytes))
        let kind = kindTitle(of: row.id)
        let modified = relativeModified(tree.modifiedDay[Int(row.id)])
        let symbol = isDir ? "folder.fill" : FileKind.classify(fileName: name, path: tree.path(of: row.id, root: rootURL).path).symbolName

        return HStack(spacing: 8) {
            Button {
                if on { checked.remove(row.id) } else { checked.insert(row.id) }
            } label: {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(on ? DiskMapTheme.ink : DiskMapTheme.mutedLabel)
            }
            .buttonStyle(.plain)
            .frame(width: 22)

            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isDir ? Color(red: 0.35, green: 0.55, blue: 0.95) : DiskMapTheme.mutedLabel)
                    .frame(width: 22, height: 22)

                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DiskMapTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(name)

                Text(kind)
                    .font(.system(size: 11))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .lineLimit(1)
                    .frame(width: 100, alignment: .leading)

                HStack(spacing: 8) {
                    ProportionBar(fraction: frac, tint: DiskMapTheme.ink.opacity(0.22))
                        .frame(height: 4)
                    Text(ByteFormat.string(row.size))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(DiskMapTheme.ink)
                        .frame(width: 72, alignment: .trailing)
                }
                .frame(width: 150, alignment: .leading)

                Text(modified)
                    .font(.system(size: 11))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .frame(width: 96, alignment: .trailing)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? DiskMapTheme.ink.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                openItem(row.id)
            }
            .onTapGesture(count: 1) {
                selectedID = row.id
                model.selectedNode = row.id
            }
            .contextMenu { contextMenu(for: row.id) }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 40)
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
                model.folderFilterPath = CanonicalPath.parentDisplay(of: abs)
                // Prefer absolute parent path for filter when possible
                let parent = (abs as NSString).deletingLastPathComponent
                model.folderFilterPath = parent
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
            if rawChildren.isEmpty {
                Text("This folder is empty")
                    .font(DiskMapType.section)
                Text("Nothing to show here in the current scan.")
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            } else {
                Text("No items match this filter")
                    .font(DiskMapType.section)
                Text("Clear the filter or change sort.")
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
        }
        .foregroundStyle(DiskMapTheme.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var selectionBar: some View {
        HStack {
            Text("\(checked.count.formatted()) selected")
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

    // MARK: - Inspector

    private var inspector: some View {
        Group {
            if Int(activeID) < tree.count, tree.isDirectory[Int(activeID)] {
                FolderBrowserInspector(
                    model: model,
                    tree: tree,
                    rootURL: rootURL,
                    nodeID: activeID,
                    usedDenominator: usedDenominator,
                    onOpen: { jumpTo(activeID, recordHistory: true) },
                    onOpenCleanup: onOpenCleanup
                )
            } else if Int(activeID) < tree.count {
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

    // MARK: - Navigation

    private func syncFromModel() {
        let start = model.currentNode
        history = [start]
        historyIndex = 0
        selectedID = model.selectedNode >= 0 ? model.selectedNode : start
        model.currentNode = start
    }

    private func jumpTo(_ id: Int32, recordHistory: Bool) {
        guard id >= 0, Int(id) < tree.count, tree.isDirectory[Int(id)] || id == 0 else {
            if id >= 0, Int(id) < tree.count {
                selectedID = id
                model.selectedNode = id
            }
            return
        }
        if recordHistory {
            if historyIndex < history.count - 1 {
                history = Array(history.prefix(historyIndex + 1))
            }
            if history.last != id {
                history.append(id)
                historyIndex = history.count - 1
            }
        }
        model.currentNode = id
        selectedID = id
        model.selectedNode = id
        checked.removeAll()
        // Keep query + sort across navigation (prompt §20)
    }

    private func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        let id = history[historyIndex]
        model.currentNode = id
        selectedID = id
        model.selectedNode = id
    }

    private func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        let id = history[historyIndex]
        model.currentNode = id
        selectedID = id
        model.selectedNode = id
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

// MARK: - Folder inspector

private struct FolderBrowserInspector: View {
    @ObservedObject var model: ScanModel
    let tree: FileTree
    let rootURL: URL
    let nodeID: Int32
    let usedDenominator: Int64
    var onOpen: () -> Void
    var onOpenCleanup: () -> Void
    @State private var showTechnical = false

    private var insight: FolderInsight? {
        FolderInsight.build(
            nodeID: nodeID,
            tree: tree,
            root: rootURL,
            totals: model.selectedTotals,
            fileCounts: model.descendantFileCounts,
            folderCounts: model.descendantFolderCounts,
            categories: model.fileTypeCategories
        )
    }

    private var topChildren: [(id: Int32, size: Int64)] {
        guard insight != nil else { return [] }
        return tree.children(of: nodeID, totals: model.selectedTotals)
            .sorted { $0.size > $1.size }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        ScrollView {
            if let insight {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(Color(red: 0.35, green: 0.55, blue: 0.95))
                            .frame(width: 52, height: 52)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(red: 0.35, green: 0.55, blue: 0.95).opacity(0.12))
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(insight.name == "/" ? (VolumeStats.forPath(rootURL.path)?.volumeName ?? "Macintosh HD") : insight.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(DiskMapTheme.ink)
                            Text(ByteFormat.string(insight.bytes))
                                .font(.system(size: 24, weight: .semibold).monospacedDigit())
                            Text(String(format: "%.1f%% of used storage", min(100, Double(insight.bytes) / Double(usedDenominator) * 100)))
                                .font(.system(size: 11))
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                        }
                    }

                    meta("Location", insight.displayPath)
                    meta(
                        "Contents",
                        "\(insight.fileCount.formatted()) files · \(insight.folderCount.formatted()) folders"
                    )

                    if !insight.composition.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("What's inside?")
                                .font(.system(size: 12, weight: .semibold))
                            ForEach(Array(insight.composition.prefix(5).enumerated()), id: \.element.categoryID) { _, row in
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
                                    fraction: Double(row.bytes) / Double(max(1, insight.bytes)),
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
                                    if tree.isDirectory[Int(child.id)] {
                                        model.currentNode = child.id
                                    }
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
                        Text(insight.whyLarge)
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

                    if insight.safety.level == .protected {
                        Text("macOS system / protected location. Diskmap does not recommend deleting items here.")
                            .font(.system(size: 11))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    DisclosureGroup("Technical details", isExpanded: $showTechnical) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(insight.absolutePath)
                                .font(.system(size: 11).monospaced())
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                                .textSelection(.enabled)
                            Text("Node \(insight.nodeID)")
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
                            Button("Open in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: insight.absolutePath)])
                            }
                            .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                        } else {
                            Button("Open in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: insight.absolutePath)])
                            }
                            .buttonStyle(PrimaryCTAStyle(fullWidth: true))
                        }

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

                        if insight.safety.level != .protected {
                            Button(model.isStaged(URL(fileURLWithPath: insight.absolutePath, isDirectory: true))
                                   ? "Open Cleanup Queue"
                                   : "Add to Cleanup") {
                                Task { await stage(insight) }
                            }
                            .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                        }

                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(insight.displayPath, forType: .string)
                            model.showToast("Path copied")
                        }
                        .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                    }
                }
                .padding(16)
            }
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

    private func stage(_ insight: FolderInsight) async {
        let url = URL(fileURLWithPath: insight.absolutePath, isDirectory: true).standardizedFileURL
        if model.isStaged(url) {
            onOpenCleanup()
            return
        }
        let ok = await model.cleanupQueue.stage(url, size: insight.bytes, reason: "File Browser: " + insight.name)
        await model.refreshQueue()
        model.showToast(ok ? "Added to cleanup review" : "Blocked by safety rules")
        if ok { onOpenCleanup() }
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
