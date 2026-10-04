import AppKit
import DiskMapCore
import SwiftUI

/// Find (TASK-060): one list over the whole scan, narrowed by chips and the
/// query language (TASK-059). A chip is only a shortcut for a query token, so
/// the text box always shows exactly what is being asked.
///
/// Also the old Search page: a query of one bare word (optionally with
/// `type:`) runs through `FileSearchIndex`, the as-you-type name index;
/// anything else runs through `FileQuery`. One page, both engines.
struct FindView: View {
    @ObservedObject var model: ScanModel
    @Environment(\.diskMapContentWidth) private var contentWidth
    let tree: FileTree
    let rootURL: URL

    struct QueryChip: Identifiable {
        var id: String
        var title: String
        var token: String
        var symbol: String
    }

    static let chips: [QueryChip] = [
        QueryChip(id: "large", title: "Large", token: "size>500MB", symbol: "arrow.up.right.square"),
        QueryChip(id: "old", title: "Old", token: "age>1y", symbol: "clock"),
        QueryChip(id: "duplicated", title: "Duplicated", token: "is:duplicate", symbol: "doc.on.doc"),
        QueryChip(id: "cached", title: "Cached", token: "in:caches", symbol: "internaldrive"),
        QueryChip(id: "media", title: "Media", token: "kind:media", symbol: "film"),
        QueryChip(id: "downloads", title: "Downloads", token: "in:downloads", symbol: "arrow.down.circle"),
        QueryChip(id: "folders", title: "Folders", token: "type:folder", symbol: "folder"),
    ]

    static let examples = [
        "ext:mp4,mov size>500MB",
        "in:downloads age>6m",
        "name:*.log size>50MB",
        "type:folder node_modules",
        "kind:archive in:library",
        "is:hardlink",
    ]

    static let exampleMeanings = [
        "Videos over 500 MB",
        "Downloads untouched for six months",
        "Log files over 50 MB",
        "Every node_modules folder",
        "Archives inside Library",
        "Files with more than one hard link",
    ]

    static let keyReference: [(String, String)] = [
        ("ext:  name:", "extension or name pattern"),
        ("kind:", "video audio image media document developer archive"),
        ("size>  size<", "500MB, 2GB"),
        ("age>  age<", "30d, 6m, 1y"),
        ("in:", "downloads desktop documents library caches"),
        ("is:", "duplicate hardlink cloud"),
        ("type:", "file folder any"),
        ("word  -word", "name contains / excludes"),
    ]

    struct Row: Identifiable, Sendable {
        var id: Int32
        var name: String
        var absolutePath: String
        var kind: FileKind
        var bytes: Int64
        var modifiedDay: Int32
        var isDirectory: Bool
    }

    @State private var rows: [Row] = []
    @State private var savingSearch = false
    @State private var matchCount = 0
    /// Nil when the name index answered (it counts matches, not bytes).
    @State private var matchedBytes: Int64? = 0
    @State private var notes: [String] = []
    @State private var isRunning = false
    @State private var selectedID: Int32?
    @State private var index: FileSearchIndex?
    @State private var indexGeneration = 0

    private var home: String { NSHomeDirectory() }
    private var trimmedQuery: String { model.findQuery.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsed: FileQuery.Parsed { FileQuery.parse(model.findQuery, home: home, root: rootURL.path) }

    private var runKey: String {
        "\(model.findQuery)|\(model.findSort.rawValue)|\(tree.count)|\(model.sizeBasis)|\(model.duplicateDidRun)|\(model.duplicateGroups.count)|\(indexGeneration)"
    }

    private var activeSelection: Int32? {
        if let selectedID, rows.contains(where: { $0.id == selectedID }) { return selectedID }
        return rows.first?.id
    }

    var body: some View {
        Group {
            if trimmedQuery.isEmpty {
                mainColumn
            } else {
                AdaptiveInspectorSplit(windowWidth: contentWidth, inspectionToken: selectedID.map(String.init),
                                       main: mainColumn, inspector: inspector)
            }
        }
        .background(DiskMapTheme.canvas)
        .task(id: runKey) { await run() }
        .task(id: model.scanID) {
            index = nil
            let source = tree
            let built = await Task.detached(priority: .userInitiated) { FileSearchIndex(tree: source) }.value
            guard !Task.isCancelled else { return }
            index = built
            indexGeneration += 1
        }
        .sheet(isPresented: $savingSearch) {
            SaveSearchSheet(model: model, isPresented: $savingSearch,
                            suggestedName: SavedSearches.defaultName(for: model.findQuery, home: home, root: rootURL.path))
        }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(eyebrow: "Find", title: "Find",
                           subtitle: "Type a name, or narrow by size, age, kind and place.") {
                    if !trimmedQuery.isEmpty {
                        HeaderSummary(parts: summaryParts)
                    }
                }
                controls
            }
            .padding(.horizontal, 28)
            .padding(.top, DiskMapSpace.pageTop)
            .padding(.bottom, 12)
            Hairline()
            if trimmedQuery.isEmpty {
                startState
            } else if rows.isEmpty && !isRunning {
                DiskMapEmptyState(symbol: "magnifyingglass", title: "Nothing matches",
                                  message: "Remove a chip or loosen a size or age.")
            } else {
                list
            }
            NodeSelectionToolbar(model: model)
        }
    }

    private var summaryParts: [String] {
        if isRunning && rows.isEmpty { return ["Searching…"] }
        var parts = ["\(matchCount.formatted()) match\(matchCount == 1 ? "" : "es")"]
        if let matchedBytes, matchCount > 0 { parts.append(ByteFormat.string(matchedBytes)) }
        return parts
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                DiskMapSearchField(placeholder: "Name, or ext:mp4 size>500MB age>1y in:downloads…",
                                   text: $model.findQuery)
                    .accessibilityLabel("Find query")
                DiskMapMenu(label: "Sort", options: FileQuery.Sort.allCases, selection: $model.findSort, title: Self.sortTitle)
                // TASK-081: keep this query in the sidebar (⌘S).
                Button("Save…") { savingSearch = true }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(trimmedQuery.isEmpty)
                    .help("Keep this search in the sidebar, with its size kept up to date")
            }
            FlowLayout(spacing: 2) {
                ForEach(Self.chips) { chip in
                    let on = FileQuery.contains(chip.token, in: model.findQuery)
                    Chip(title: chip.title, isOn: on) {
                        if !on { Self.recordChipUse(chip.id) }
                        model.findQuery = FileQuery.toggling(chip.token, in: model.findQuery)
                    }
                    .help(chip.token)
                    .accessibilityLabel("\(chip.title), adds \(chip.token)")
                }
            }
            if !trimmedQuery.isEmpty {
                meaning
            }
        }
    }

    static func sortTitle(_ sort: FileQuery.Sort) -> String {
        switch sort {
        case .largest: return "Largest"
        case .oldest: return "Oldest"
        case .newest: return "Recently modified"
        }
    }

    /// What the query means, in words, plus anything it could not use.
    private var meaning: some View {
        let parsed = self.parsed
        return VStack(alignment: .leading, spacing: 4) {
            Text(parsed.query.describe(home: home).joined(separator: "  ·  "))
                .font(DiskMapType.figureSmall)
                .foregroundStyle(DiskMapTheme.ink3)
                .lineLimit(2)
            ForEach(parsed.problems, id: \.token) { problem in
                Text("Ignoring \(problem.token) — \(problem.message)")
                    .font(DiskMapType.secondary)
                    .foregroundStyle(DiskMapTheme.review)
            }
            ForEach(notes, id: \.self) { note in
                HStack(spacing: 8) {
                    Text(note)
                        .font(DiskMapType.secondary)
                        .foregroundStyle(DiskMapTheme.review)
                    if note.hasPrefix("Duplicates") {
                        Button("Find Duplicates") { model.destination = .duplicates }
                            .buttonStyle(LinkButtonStyle())
                            .font(DiskMapType.secondary)
                    }
                }
            }
        }
    }

    // MARK: Start state

    private var startState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DiskMapSpace.xl) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionHeader(label: "Try")
                    ForEach(Array(Self.examples.enumerated()), id: \.offset) { offset, example in
                        ExampleRow(query: example, meaning: Self.exampleMeanings[offset]) {
                            model.findQuery = example
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(label: "Keep one in the sidebar")
                    FlowLayout(spacing: 16) {
                        ForEach(SavedSearches.starters, id: \.query) { starter in
                            let saved = model.savedSearches.contains { $0.query == starter.query }
                            Button {
                                model.saveSearch(name: starter.name, query: starter.query, sort: .largest)
                            } label: {
                                Label(starter.name, systemImage: saved ? "checkmark" : "plus")
                            }
                            .buttonStyle(LinkButtonStyle())
                            .font(DiskMapType.secondary)
                            .disabled(saved)
                            .opacity(saved ? 0.5 : 1)
                            .help(starter.query)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(label: "Keys")
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                        ForEach(Self.keyReference, id: \.0) { key, detail in
                            GridRow {
                                Text(key)
                                    .font(DiskMapType.figure)
                                    .foregroundStyle(DiskMapTheme.ink)
                                Text(detail)
                                    .font(DiskMapType.secondary)
                                    .foregroundStyle(DiskMapTheme.ink2)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, DiskMapSpace.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: List

    private var list: some View {
        let ids = rows.map(\.id)
        return ScrollView {
            LazyVStack(spacing: 0) {
                if matchCount > rows.count {
                    Text("Showing the first \(rows.count.formatted()) of \(matchCount.formatted()) — narrow the query to see the rest.")
                        .font(DiskMapType.secondary)
                        .foregroundStyle(DiskMapTheme.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                ForEach(rows) { row in
                    rowView(row, ordered: ids)
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
                if let row = rows.first(where: { $0.id == id }) {
                    model.stageRow(path: row.absolutePath, size: row.bytes, reason: "Find: \(trimmedQuery)")
                }
            },
            selectAll: { model.multiSelection = Set(ids) },
            clearSelection: { model.clearMultiSelection() }
        )
        .onChange(of: selectedID) { _, id in if let id { model.selectedNode = id } }
        .opacity(isRunning ? 0.6 : 1)
    }

    private func rowView(_ row: Row, ordered: [Int32]) -> some View {
        let inMulti = model.multiSelection.contains(row.id)
        let stage = { model.stageRow(path: row.absolutePath, size: row.bytes, reason: "Find: \(trimmedQuery)") }
        return Button {
            selectedID = row.id
            model.select(row.id, ordered: ordered)
        } label: {
            KitRow(title: row.name, subtitle: relativeParent(of: row.absolutePath, root: rootURL),
                   selected: row.id == activeSelection || inMulti, path: row.absolutePath, onStage: stage) {
                MultiSelectMark(on: inMulti)
                if row.isDirectory {
                    Image(systemName: "folder")
                        .font(.system(size: DiskMapType.scaled(14)))
                        .foregroundStyle(DiskMapTheme.ink2)
                        .frame(width: 24, height: 24)
                } else {
                    FileIdentityIcon(url: URL(fileURLWithPath: row.absolutePath), kind: row.kind, size: 24)
                }
            } trailing: {
                TextColumn(text: row.isDirectory ? "Folder" : row.kind.title, width: 92)
                MonoColumn(text: RelativeAge.short(day: row.modifiedDay), width: 74)
                MonoColumn(text: ByteFormat.string(row.bytes), width: 74, emphasis: true)
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if row.isDirectory {
                model.currentNode = row.id
                model.selectedNode = row.id
                model.destination = .fileBrowser
            } else {
                revealDownloadedFile(row.id, tree: tree, root: rootURL)
            }
        })
        .accessibilityLabel("\(row.name), \(ByteFormat.string(row.bytes)), modified \(RelativeAge.long(day: row.modifiedDay))")
        .rowActions(path: row.absolutePath, stage: stage)
        .contextMenu {
            Button("Show in Visualize") {
                model.selectedNode = row.id
                model.currentNode = row.isDirectory ? row.id : max(0, tree.parent[Int(row.id)])
                model.destination = .visualize
            }
            Button("Show in File Browser") {
                model.currentNode = row.isDirectory ? row.id : max(0, tree.parent[Int(row.id)])
                model.selectedNode = row.id
                model.destination = .fileBrowser
            }
        }
    }

    private var inspector: some View {
        Group {
            if let id = activeSelection, let row = rows.first(where: { $0.id == id }) {
                if row.isDirectory {
                    FolderInspector(model: model, tree: tree, rootURL: rootURL, id: id, reason: "Find: \(trimmedQuery)")
                } else {
                    FileInspector(model: model, tree: tree, rootURL: rootURL, id: id, size: row.bytes,
                                  reason: "Find: \(trimmedQuery)")
                }
            } else {
                DiskMapEmptyState(symbol: "magnifyingglass", title: "Select a result", message: "Its details and actions appear here.")
            }
        }
        .background(DiskMapTheme.canvas)
    }

    static func relativeModified(_ day: Int32) -> String { RelativeAge.long(day: day) }

    // MARK: Running

    /// The name index answers a single bare word ranked by size — it is
    /// instant on million-item trees. Everything else needs `FileQuery`.
    static func indexNeedle(for query: FileQuery, sort: FileQuery.Sort) -> (String, FileSearchIndex.KindFilter)? {
        guard sort == .largest, query.words.count == 1 else { return nil }
        var plain = FileQuery()
        plain.words = query.words
        plain.explicitType = query.explicitType
        guard query == plain else { return nil }
        let kind: FileSearchIndex.KindFilter
        switch query.explicitType {
        case .files: kind = .files
        case .folders: kind = .folders
        case .any, .none: kind = .all
        }
        return (query.words[0], kind)
    }

    nonisolated static func makeRow(_ id: Int32, tree: FileTree, root: URL, totals: [Int64]) -> Row {
        let path = tree.path(of: id, root: root).path
        let name = tree.name(of: id)
        return Row(id: id, name: name, absolutePath: path,
                   kind: FileKind.classify(fileName: name, path: path),
                   bytes: totals.indices.contains(Int(id)) ? totals[Int(id)] : 0,
                   modifiedDay: tree.modifiedDay[Int(id)],
                   isDirectory: tree.isDirectory[Int(id)])
    }

    @MainActor
    private func run() async {
        let text = trimmedQuery
        guard !text.isEmpty else {
            rows = []; matchCount = 0; matchedBytes = 0; notes = []; isRunning = false
            return
        }
        isRunning = true
        try? await Task.sleep(for: .milliseconds(120))   // let typing settle
        guard !Task.isCancelled else { return }
        let query = parsed.query
        let totals = model.selectedTotals
        let sort = model.findSort
        let sourceTree = tree
        let root = rootURL

        if let index, let (needle, kind) = Self.indexNeedle(for: query, sort: sort) {
            let work = Task.detached(priority: .userInitiated) { () -> (FileSearchIndex.Result, [Row]) in
                let found = index.search(needle, in: sourceTree, totals: totals, kind: kind, limit: 500)
                return (found, found.ids.map { Self.makeRow($0, tree: sourceTree, root: root, totals: totals) })
            }
            let (found, newRows) = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }
            rows = newRows
            matchCount = found.totalMatches
            // A folder's size already holds its matching children, so only a
            // complete, files-only answer can be summed.
            matchedBytes = found.totalMatches == newRows.count && !newRows.contains(where: \.isDirectory)
                ? newRows.reduce(0) { $0 + $1.bytes } : nil
            notes = []
            isRunning = false
            return
        }

        let duplicates: Set<Int32>? = model.duplicateDidRun ? Set(model.duplicateGroups.flatMap(\.fileIDs)) : nil
        let context = FileQuery.Context(home: home, duplicateFileIDs: duplicates)
        let work = Task.detached(priority: .userInitiated) { () -> (FileQuery.Result, [Row]) in
            let result = query.run(tree: sourceTree, root: root, totals: totals, context: context,
                                   sort: sort, limit: 500, isCancelled: { Task.isCancelled })
            return (result, result.ids.map { Self.makeRow($0, tree: sourceTree, root: root, totals: totals) })
        }
        let (result, newRows) = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard !Task.isCancelled, !result.wasCancelled else { return }
        rows = newRows
        matchCount = result.matchCount
        matchedBytes = result.matchedBytes
        notes = result.notes
        isRunning = false
    }

    // MARK: Chip use, measured locally

    /// How often each chip is switched on, kept in this Mac's preferences
    /// only (nothing leaves the machine). `defaults read <bundle id>
    /// FindChipUses` shows the counts.
    static let chipUseKey = "FindChipUses"

    static func recordChipUse(_ id: String, defaults: UserDefaults = .standard) {
        var counts = defaults.dictionary(forKey: chipUseKey) as? [String: Int] ?? [:]
        counts[id, default: 0] += 1
        defaults.set(counts, forKey: chipUseKey)
    }
}

/// An example query: mono query, then what it means.
private struct ExampleRow: View {
    var query: String
    var meaning: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DiskMapSpace.md) {
                Text(query)
                    .font(DiskMapType.figure)
                    .foregroundStyle(DiskMapTheme.ink)
                    .frame(width: 230, alignment: .leading)
                Text(meaning)
                    .font(DiskMapType.secondary)
                    .foregroundStyle(DiskMapTheme.ink2)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.system(size: DiskMapType.scaled(10), weight: .semibold))
                    .foregroundStyle(hovering ? DiskMapTheme.accent : .clear)
            }
            .padding(.horizontal, 10)
            .frame(height: DiskMapSpace.row)
            .background(RowBackground(selected: false, hovering: hovering))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, -10)
        .accessibilityLabel("\(meaning): \(query)")
    }
}
