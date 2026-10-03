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
    @State private var rankedFileIDs: [Int32] = []
    @State private var isPreparingRanking = true

    private var totals: [Int64] { model.selectedTotals }

    private var allFileIDs: [Int32] {
        rankedFileIDs
    }

    private var filtered: [Int32] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pathPrefix = model.folderFilterPath
        var ids = allFileIDs.filter { id in
            let name = tree.name(of: id)
            let abs = tree.path(of: id, root: rootURL).path
            if let pathPrefix {
                let prefix = pathPrefix.hasSuffix("/") ? pathPrefix : pathPrefix + "/"
                if abs != pathPrefix && !abs.hasPrefix(prefix) { return false }
            }
            let kind = FileKind.classify(fileName: name, path: abs)
            // "Other" holds every kind without its own chip.
            if let kindFilter {
                let grouped = Self.kinds.contains(kind) ? kind : .other
                if grouped != kindFilter { return false }
            }
            if q.isEmpty { return true }
            let display = CanonicalPath.displayPath(absolutePath: abs).lowercased()
            return name.lowercased().contains(q) || display.contains(q)
        }
        switch sortMode {
        case .largest:
            ids.sort { totals[Int($0)] > totals[Int($1)] }
        case .smallest:
            ids.sort { totals[Int($0)] < totals[Int($1)] }
        case .newest:
            ids.sort { tree.modifiedDay[Int($0)] > tree.modifiedDay[Int($1)] }
        case .oldest:
            ids.sort { a, b in
                let da = tree.modifiedDay[Int(a)]
                let db = tree.modifiedDay[Int(b)]
                if da == 0 { return false }
                if db == 0 { return true }
                return da < db
            }
        case .name:
            ids.sort {
                tree.name(of: $0).localizedCaseInsensitiveCompare(tree.name(of: $1)) == .orderedAscending
            }
        }
        return ids
    }

    private var totalBytes: Int64 {
        filtered.reduce(Int64(0)) { $0 + totals[Int($1)] }
    }

    private var activeSelection: Int32? {
        if let selectedID, filtered.contains(selectedID) { return selectedID }
        return filtered.first
    }

    @State private var kindCounts: [FileKind: Int] = [:]

    nonisolated private static let kinds: [FileKind] = [.video, .diskImage, .archive, .application, .document, .other]

    var body: some View {
        AdaptiveInspectorSplit(windowWidth: contentWidth, inspectionToken: selectedID.map(String.init), main: mainColumn, inspector: inspector)
        .background(DiskMapTheme.canvas)
        .task(id: rankingID) { await prepareRanking() }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(eyebrow: "Find", title: "Biggest Files",
                           subtitle: "Files only, largest first. ⌘-click to select several, ⇧-click for a range.") {
                    HeaderSummary(parts: [countLabel(filtered.count, "file"), ByteFormat.string(totalBytes)])
                }
                filterBar
            }
            .padding(.horizontal, 28)
            .padding(.top, DiskMapSpace.pageTop)
            .padding(.bottom, 12)
            if isPreparingRanking {
                DiskMapLoadingState(title: "Finding biggest files", detail: "Ranking the scan without blocking the window.")
            } else if filtered.isEmpty {
                DiskMapEmptyState(
                    symbol: "doc",
                    title: allFileIDs.isEmpty ? "No large files" : "No files match",
                    message: allFileIDs.isEmpty ? "The scan found no files of note." : "Try another type or clear the search."
                )
            } else {
                columnHeader
                list
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
            rankedFileIDs = []
            isPreparingRanking = false
            return
        }
        isPreparingRanking = true
        let sourceTree = tree
        let sourceTotals = totals
        let root = rootURL
        let (result, counts) = await Task.detached(priority: .userInitiated) { () -> ([Int32], [FileKind: Int]) in
            let ids = TopSizes.rankedFiles(tree: sourceTree, totals: sourceTotals, limit: 2_000)
            var counts: [FileKind: Int] = [:]
            for id in ids {
                let kind = FileKind.classify(fileName: sourceTree.name(of: id), path: sourceTree.path(of: id, root: root).path)
                counts[Self.kinds.contains(kind) ? kind : .other, default: 0] += 1
            }
            return (ids, counts)
        }.value
        guard !Task.isCancelled else { return }
        rankedFileIDs = result
        kindCounts = counts
        isPreparingRanking = false
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
            HStack(spacing: 2) {
                Chip(title: "All", count: "\(allFileIDs.count)", isOn: kindFilter == nil) { kindFilter = nil }
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
                ColumnHeaderLabel(title: "Kind", width: 92)
                ColumnHeaderLabel(title: "Modified", alignment: .trailing, width: 74)
                ColumnHeaderLabel(title: "Size", alignment: .trailing, width: 74)
            }
            .padding(.horizontal, 10 + 18)
            .frame(height: DiskMapMetric.tableHeaderHeight)
            Hairline()
        }
    }

    private var list: some View {
        let ids = Array(filtered.prefix(500))
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(ids, id: \.self) { id in
                    fileRow(id: id, ordered: ids)
                    RowSeparator(indent: 10 + 14 + 12 + 24 + 12)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 4)
        }
        .listKeyboard(
            ids: ids, selection: $selectedID,
            path: { tree.path(of: $0, root: rootURL).path },
            stage: { id in
                model.stageRow(path: tree.path(of: id, root: rootURL).path, size: totals[Int(id)],
                               reason: "Biggest file: " + tree.name(of: id))
            },
            selectAll: { model.multiSelection = Set(ids) },
            clearSelection: { model.clearMultiSelection() }
        )
        .onChange(of: selectedID) { _, id in if let id { model.selectedNode = id } }
    }

    private func fileRow(id: Int32, ordered: [Int32]) -> some View {
        let i = Int(id)
        let name = tree.name(of: id)
        let abs = tree.path(of: id, root: rootURL).path
        let kind = FileKind.classify(fileName: name, path: abs)
        let size = totals[i]
        let inMulti = model.multiSelection.contains(id)
        let selected = id == activeSelection || inMulti
        let stage = { model.stageRow(path: abs, size: size, reason: "Biggest file: " + name) }
        return Button {
            selectedID = id
            model.select(id, ordered: ordered)
        } label: {
            KitRow(title: name, subtitle: relativeParent(of: abs, root: rootURL), selected: selected,
                   path: abs, onStage: stage) {
                MultiSelectMark(on: inMulti)
                FileIdentityIcon(url: URL(fileURLWithPath: abs), kind: kind, size: 24)
            } trailing: {
                TextColumn(text: kind.title, width: 92)
                MonoColumn(text: RelativeAge.short(day: tree.modifiedDay[i]), width: 74)
                MonoColumn(text: ByteFormat.string(size), width: 74, emphasis: true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(kind.title), \(ByteFormat.string(size)), modified \(RelativeAge.long(day: tree.modifiedDay[i]))")
        .rowActions(path: abs, stage: stage)
    }

    private var inspector: some View {
        Group {
            if let id = activeSelection {
                FileInspector(model: model, tree: tree, rootURL: rootURL, id: id, size: totals[Int(id)],
                              reason: "Biggest file: " + tree.name(of: id))
            } else {
                DiskMapEmptyState(symbol: "doc", title: "Select a file", message: "Its details and actions appear here.")
            }
        }
        .background(DiskMapTheme.canvas)
    }
}

