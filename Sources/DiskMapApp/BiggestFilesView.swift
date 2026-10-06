import AppKit
import DiskMapCore
import SwiftUI

/// Find → Biggest Files: files only, ranked by size, with inspector matching DiskMap-BiggestFiles ref.
struct BiggestFilesView: View {
    @ObservedObject var model: ScanModel
    @Environment(\.diskMapContentWidth) private var contentWidth
    let tree: FileTree
    let rootURL: URL
    var onOpenCleanup: () -> Void = {}

    enum SortMode: String, CaseIterable, Identifiable {
        case largest, smallest, newest, oldest, name
        var id: String { rawValue }
        var title: String {
            switch self {
            case .largest: return "Largest"
            case .smallest: return "Smallest"
            case .newest: return "Recently modified"
            case .oldest: return "Oldest"
            case .name: return "Name"
            }
        }
    }

    @State private var query = ""
    @State private var kindFilter: FileKind? = nil
    @State private var sortMode: SortMode = .largest
    @State private var selectedID: Int32?
    @State private var isPreparingRanking = true
    /// Everything a row needs, worked out once per ranking off the main thread.
    @State private var entries: [Entry] = []
    /// `entries` narrowed and sorted — recomputed only when a filter changes,
    /// never while drawing (it used to rebuild 2,000 paths once per row).
    @State private var visible: [Entry] = []
    @State private var kindCounts: [FileKind: Int] = [:]
    /// Storage categories among the ranked files, biggest first.
    @State private var categoryCounts: [(id: String, title: String, count: Int, bytes: Int64)] = []

    struct Entry: Identifiable, Sendable {
        var id: Int32
        var name: String
        var absolutePath: String
        var parent: String
        var kind: FileKind
        var size: Int64
        var modifiedDay: Int32
        /// Lowercased name + display path, for the search box.
        var searchText: String
        /// Storage category (MAC-FIXES-FROM-WINDOWS §4.5) and what removing it means.
        var category: StorageVerdict
    }

    nonisolated private static let kinds: [FileKind] = [.video, .diskImage, .archive, .application, .document, .other]

    private var totals: [Int64] { model.selectedTotals }

    private var filterKey: String {
        "\(query)|\(kindFilter?.rawValue ?? "")|\(sortMode.rawValue)|\(model.folderFilterPath ?? "")|\(model.categoryFilter ?? "")|\(entries.count)"
    }

    private func refilter() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pathPrefix = model.folderFilterPath
        let prefix = pathPrefix.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        let category = model.categoryFilter
        var list = entries.filter { entry in
            if let category, entry.category.storageClass.id != category { return false }
            if let pathPrefix, let prefix, entry.absolutePath != pathPrefix, !entry.absolutePath.hasPrefix(prefix) { return false }
            // "Other" holds every kind without its own chip.
            if let kindFilter, (Self.kinds.contains(entry.kind) ? entry.kind : .other) != kindFilter { return false }
            return q.isEmpty || entry.searchText.contains(q)
        }
        switch sortMode {
        case .largest: list.sort { $0.size > $1.size }
        case .smallest: list.sort { $0.size < $1.size }
        case .newest: list.sort { $0.modifiedDay > $1.modifiedDay }
        case .oldest:
            list.sort { a, b in
                if a.modifiedDay == 0 { return false }
                if b.modifiedDay == 0 { return true }
                return a.modifiedDay < b.modifiedDay
            }
        case .name: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        visible = list
    }

    var body: some View {
        // Worked out once per draw and handed to every row.
        let active = selectedID.flatMap { id in visible.first(where: { $0.id == id }) } ?? visible.first
        return AdaptiveInspectorSplit(windowWidth: contentWidth, inspectionToken: selectedID.map(String.init),
                                      main: mainColumn(active: active?.id), inspector: inspector(active))
        .background(DiskMapTheme.canvas)
        .task(id: rankingID) { await prepareRanking() }
        .onChange(of: filterKey) { _, _ in refilter() }
    }

    private func mainColumn(active: Int32?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(eyebrow: "Find", title: "Biggest Files",
                           subtitle: "Files only, largest first. ⌘-click to select several, ⇧-click for a range.") {
                    HeaderSummary(parts: [countLabel(visible.count, "file"), ByteFormat.string(visible.reduce(0) { $0 + $1.size })])
                }
                filterBar
            }
            .padding(.horizontal, 28)
            .padding(.top, DiskMapSpace.pageTop)
            .padding(.bottom, 12)
            if isPreparingRanking {
                DiskMapLoadingState(title: "Finding biggest files", detail: "Ranking the scan without blocking the window.")
            } else if visible.isEmpty {
                DiskMapEmptyState(
                    symbol: "doc",
                    title: entries.isEmpty ? "No large files" : "No files match",
                    message: entries.isEmpty ? "The scan found no files of note." : "Try another type or clear the search."
                )
            } else {
                columnHeader
                list(active: active)
            }
            NodeSelectionToolbar(model: model)
        }
    }

    private var rankingID: String {
        let rootSize = totals.first ?? 0
        return "\(tree.count):\(rootSize):\(model.sizeBasis)"
    }

    @MainActor
    private func prepareRanking() async {
        guard totals.count == tree.count else {
            entries = []
            visible = []
            isPreparingRanking = false
            return
        }
        isPreparingRanking = true
        let sourceTree = tree
        let sourceTotals = totals
        let root = rootURL
        let (built, counts) = await Task.detached(priority: .userInitiated) { () -> ([Entry], [FileKind: Int]) in
            let ids = TopSizes.rankedFiles(tree: sourceTree, totals: sourceTotals, limit: 2_000)
            var counts: [FileKind: Int] = [:]
            var built: [Entry] = []
            built.reserveCapacity(ids.count)
            for id in ids {
                let name = sourceTree.name(of: id)
                let abs = sourceTree.path(of: id, root: root).path
                let kind = FileKind.classify(fileName: name, path: abs)
                counts[Self.kinds.contains(kind) ? kind : .other, default: 0] += 1
                built.append(Entry(
                    id: id, name: name, absolutePath: abs, parent: relativeParent(of: abs, root: root),
                    kind: kind, size: sourceTotals[Int(id)], modifiedDay: sourceTree.modifiedDay[Int(id)],
                    searchText: name.lowercased() + "\n" + CanonicalPath.displayPath(absolutePath: abs).lowercased(),
                    category: StorageClassifier.classify(path: abs, isDirectory: false)
                ))
            }
            return (built, counts)
        }.value
        guard !Task.isCancelled else { return }
        entries = built
        kindCounts = counts
        categoryCounts = Self.categoryCounts(built)
        refilter()
        isPreparingRanking = false
    }

    /// Categories among `entries`, by bytes, Other last.
    static func categoryCounts(_ entries: [Entry]) -> [(id: String, title: String, count: Int, bytes: Int64)] {
        var byID: [String: (title: String, count: Int, bytes: Int64)] = [:]
        for entry in entries {
            let cls = entry.category.storageClass
            var row = byID[cls.id] ?? (cls.title, 0, 0)
            row.count += 1
            row.bytes += entry.size
            byID[cls.id] = row
        }
        return byID.map { (id: $0.key, title: $0.value.title, count: $0.value.count, bytes: $0.value.bytes) }
            .sorted { ($0.id == "other") != ($1.id == "other") ? $1.id == "other" : $0.bytes > $1.bytes }
    }

    /// Category pills: the seven biggest, the rest in a menu (as on Windows).
    @ViewBuilder
    private var categoryBar: some View {
        if categoryCounts.count > 1 {
            let active = model.categoryFilter
            let top = Array(categoryCounts.prefix(7))
            let rest = Array(categoryCounts.dropFirst(7))
            FlowLayout(spacing: 2) {
                MonoLabel("Category").padding(.trailing, 6).padding(.top, 6)
                Chip(title: "All", isOn: active == nil) { model.categoryFilter = nil }
                ForEach(top, id: \.id) { row in
                    Chip(title: row.title, count: ByteFormat.string(row.bytes), isOn: active == row.id) {
                        model.categoryFilter = active == row.id ? nil : row.id
                    }
                }
                // A filter set from Overview may be outside the top seven.
                if let active, !top.contains(where: { $0.id == active }), let row = categoryCounts.first(where: { $0.id == active }) {
                    Chip(title: row.title, count: ByteFormat.string(row.bytes), isOn: true) { model.categoryFilter = nil }
                }
                if !rest.isEmpty {
                    Menu {
                        ForEach(rest, id: \.id) { row in
                            Button("\(row.title) · \(ByteFormat.string(row.bytes))") { model.categoryFilter = row.id }
                        }
                    } label: {
                        Text("\(rest.count) more categories…").font(DiskMapType.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .padding(.leading, 6)
                }
            }
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                DiskMapSearchField(placeholder: "Search by name or path", text: $query)
                    .frame(maxWidth: 340)
                if let pathPrefix = model.folderFilterPath {
                    Chip(title: "In " + CanonicalPath.displayPath(absolutePath: pathPrefix), symbol: "xmark", isOn: true) {
                        model.folderFilterPath = nil
                    }
                    .help("Show files from everywhere")
                }
                Spacer(minLength: 8)
                DiskMapMenu(label: "Sort", options: SortMode.allCases, selection: $sortMode, title: { $0.title })
                    .accessibilityLabel("Sort by " + sortMode.title)
            }
            categoryBar
            FlowLayout(spacing: 2) {
                Chip(title: "All", count: "\(entries.count)", isOn: kindFilter == nil) { kindFilter = nil }
                ForEach(Self.kinds, id: \.self) { kind in
                    if let count = kindCounts[kind], count > 0 {
                        Chip(title: kind.title, count: "\(count)", isOn: kindFilter == kind) {
                            kindFilter = (kindFilter == kind) ? nil : kind
                        }
                    }
                }
            }
        }
    }

    private var columnHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 14 + 12 + 24, height: 1)
                ColumnHeaderLabel(title: "Name")
                ColumnHeaderLabel(title: "Category", width: 150)
                ColumnHeaderLabel(title: "Modified", alignment: .trailing, width: 74)
                ColumnHeaderLabel(title: "Size", alignment: .trailing, width: 74)
            }
            .padding(.horizontal, 10 + 18)
            .frame(height: DiskMapMetric.tableHeaderHeight)
            Hairline()
        }
    }

    private func list(active: Int32?) -> some View {
        let rows = Array(visible.prefix(500))
        let ids = rows.map(\.id)
        let multi = model.multiSelection
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { entry in
                    fileRow(entry, selected: entry.id == active || multi.contains(entry.id), inMulti: multi.contains(entry.id), ordered: ids)
                    RowSeparator(indent: 10 + 14 + 12 + 24 + 12)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 4)
        }
        .listKeyboard(
            ids: ids, selection: $selectedID,
            path: { id in rows.first { $0.id == id }?.absolutePath },
            stage: { id in
                if let entry = rows.first(where: { $0.id == id }) {
                    model.stageRow(path: entry.absolutePath, size: entry.size, reason: "Biggest file: " + entry.name)
                }
            },
            selectAll: { model.multiSelection = Set(ids) },
            clearSelection: { model.clearMultiSelection() }
        )
        .onChange(of: selectedID) { _, id in if let id { model.selectedNode = id } }
    }

    private func fileRow(_ entry: Entry, selected: Bool, inMulti: Bool, ordered: [Int32]) -> some View {
        let stage = { model.stageRow(path: entry.absolutePath, size: entry.size, reason: "Biggest file: " + entry.name) }
        return Button {
            selectedID = entry.id
            model.select(entry.id, ordered: ordered)
        } label: {
            KitRow(title: entry.name, subtitle: entry.parent, selected: selected,
                   path: entry.absolutePath, onStage: stage) {
                MultiSelectMark(on: inMulti)
                FileIdentityIcon(url: URL(fileURLWithPath: entry.absolutePath), kind: entry.kind, size: 24)
            } trailing: {
                TextColumn(text: (entry.category.advice.isRisky ? "⚠ " : "") + entry.category.storageClass.title, width: 150)
                    .help([entry.category.note, entry.category.instead.map { "Instead: " + $0 }].compactMap { $0 }.joined(separator: "\n\n"))
                MonoColumn(text: RelativeAge.short(day: entry.modifiedDay), width: 74)
                MonoColumn(text: ByteFormat.string(entry.size), width: 74, emphasis: true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.name), \(entry.category.storageClass.title), \(ByteFormat.string(entry.size)), modified \(RelativeAge.long(day: entry.modifiedDay))")
        .rowActions(path: entry.absolutePath, stage: stage)
    }

    private func inspector(_ active: Entry?) -> some View {
        Group {
            if let active {
                FileInspector(model: model, tree: tree, rootURL: rootURL, id: active.id, size: active.size,
                              reason: "Biggest file: " + active.name)
            } else {
                DiskMapEmptyState(symbol: "doc", title: "Select a file", message: "Its details and actions appear here.")
            }
        }
        .background(DiskMapTheme.canvas)
    }
}
