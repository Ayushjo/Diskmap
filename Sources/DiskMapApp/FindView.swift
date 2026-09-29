import AppKit
import DiskMapCore
import SwiftUI

/// Find (TASK-060): one list over the whole scan, narrowed by chips and the
/// query language (TASK-059). A chip is only a shortcut for a query token, so
/// the text box always shows exactly what is being asked. Ships alongside the
/// existing Find/Clean screens; see ARCHITECTURE.md before removing any.
struct FindView: View {
    @ObservedObject var model: ScanModel
    let tree: FileTree
    let rootURL: URL
    var onOpenCleanup: () -> Void = {}

    struct Chip: Identifiable {
        var id: String
        var title: String
        var token: String
        var symbol: String
    }

    static let chips: [Chip] = [
        Chip(id: "large", title: "Large", token: "size>500MB", symbol: "arrow.up.right.square"),
        Chip(id: "old", title: "Old", token: "age>1y", symbol: "clock"),
        Chip(id: "duplicated", title: "Duplicated", token: "is:duplicate", symbol: "doc.on.doc"),
        Chip(id: "cached", title: "Cached", token: "in:caches", symbol: "internaldrive"),
        Chip(id: "media", title: "Media", token: "kind:media", symbol: "film"),
        Chip(id: "downloads", title: "Downloads", token: "in:downloads", symbol: "arrow.down.circle"),
    ]

    static let examples = [
        "ext:mp4,mov size>500MB",
        "in:downloads age>6m",
        "name:*.log size>50MB",
        "type:folder node_modules",
        "kind:archive in:library",
        "is:hardlink",
    ]

    struct Row: Identifiable, Sendable {
        var id: Int32
        var name: String
        var absolutePath: String
        var parentDisplay: String
        var kind: FileKind
        var bytes: Int64
        var modifiedDay: Int32
        var isDirectory: Bool
    }

    @State private var rows: [Row] = []
    @State private var matchCount = 0
    @State private var matchedBytes: Int64 = 0
    @State private var notes: [String] = []
    @State private var isRunning = false
    @State private var checked = Set<Int32>()
    @State private var selectedID: Int32?

    private var home: String { NSHomeDirectory() }
    private var trimmedQuery: String { model.findQuery.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsed: FileQuery.Parsed { FileQuery.parse(model.findQuery, home: home, root: rootURL.path) }

    private var runKey: String {
        "\(model.findQuery)|\(model.findSort.rawValue)|\(tree.count)|\(model.sizeBasis)|\(model.duplicateDidRun)|\(model.duplicateGroups.count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            controls
            Divider().overlay(DiskMapTheme.cardStroke)
            if trimmedQuery.isEmpty {
                startState
            } else if rows.isEmpty && !isRunning {
                emptyState
            } else {
                list
            }
            if !checked.isEmpty {
                SelectionToolbar(
                    selectedCount: checked.count,
                    selectedBytes: rows.filter { checked.contains($0.id) }.reduce(0) { $0 + $1.bytes },
                    onPrimary: { Task { await stageChecked() } },
                    onClear: { checked.removeAll() },
                    onReveal: {
                        NSWorkspace.shared.activateFileViewerSelecting(checkedRows.map { URL(fileURLWithPath: $0.absolutePath) })
                    },
                    paths: checkedRows.map(\.absolutePath)
                )
            }
        }
        .background(DiskMapTheme.cream)
        .task(id: runKey) { await run() }
    }

    private var checkedRows: [Row] { rows.filter { checked.contains($0.id) } }

    // MARK: Header and controls

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Find")
                    .font(DiskMapType.title)
                    .foregroundStyle(DiskMapTheme.ink)
                Text("Everything in this scan, narrowed by chips or a query. Chips just add words to the query — combine them freely.")
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            if !trimmedQuery.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(isRunning ? "Searching…" : "\(matchCount.formatted()) match\(matchCount == 1 ? "" : "es")")
                        .font(DiskMapType.caption)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                    if matchCount > 0 {
                        Text(ByteFormat.string(matchedBytes))
                            .font(DiskMapType.bodyStrong.monospacedDigit())
                            .foregroundStyle(DiskMapTheme.ink)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                DiskMapSearchField(placeholder: "ext:mp4 size>500MB age>1y in:downloads…", text: $model.findQuery)
                    .accessibilityLabel("Find query")
                DiskMapMenu(label: "Sort", options: FileQuery.Sort.allCases, selection: $model.findSort, title: Self.sortTitle)
                    .frame(width: 150)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.chips) { chip in
                        chipButton(chip)
                    }
                }
            }
            if !trimmedQuery.isEmpty {
                meaning
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    static func sortTitle(_ sort: FileQuery.Sort) -> String {
        switch sort {
        case .largest: return "Largest"
        case .oldest: return "Oldest"
        case .newest: return "Recently modified"
        }
    }

    private func chipButton(_ chip: Chip) -> some View {
        let selected = FileQuery.contains(chip.token, in: model.findQuery)
        return Button {
            if !selected { Self.recordChipUse(chip.id) }
            model.findQuery = FileQuery.toggling(chip.token, in: model.findQuery)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: chip.symbol)
                    .font(DiskMapType.micro)
                    .accessibilityHidden(true)
                Text(chip.title)
                    .font(DiskMapType.captionStrong)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? DiskMapTheme.onInk : DiskMapTheme.ink)
            .background(Capsule().fill(selected ? DiskMapTheme.ink : DiskMapTheme.navSelected))
        }
        .buttonStyle(.plain)
        .help(chip.token)
        .accessibilityLabel("\(chip.title), adds \(chip.token)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// What the query means, in words, plus anything it could not use.
    private var meaning: some View {
        let parsed = self.parsed
        return VStack(alignment: .leading, spacing: 4) {
            Text(parsed.query.describe(home: home).joined(separator: " · "))
                .font(DiskMapType.caption)
                .foregroundStyle(DiskMapTheme.ink)
                .lineLimit(2)
            ForEach(parsed.problems, id: \.token) { problem in
                Label("Ignoring \(problem.token) — \(problem.message)", systemImage: "exclamationmark.circle")
                    .font(DiskMapType.caption)
                    .foregroundStyle(DiskMapTheme.review)
            }
            ForEach(notes, id: \.self) { note in
                HStack(spacing: 8) {
                    Label(note, systemImage: "info.circle")
                        .font(DiskMapType.caption)
                        .foregroundStyle(DiskMapTheme.review)
                    if note.hasPrefix("Duplicates") {
                        Button("Find Duplicates") { model.destination = .duplicates }
                            .buttonStyle(.link)
                            .font(DiskMapType.captionStrong)
                    }
                }
            }
        }
    }

    // MARK: States

    private var startState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Start with a chip, or try one of these")
                .font(DiskMapType.section)
                .foregroundStyle(DiskMapTheme.ink)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.examples, id: \.self) { example in
                    Button { model.findQuery = example } label: {
                        Text(example)
                            .font(DiskMapType.body.monospaced())
                            .foregroundStyle(DiskMapTheme.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(DiskMapTheme.navSelected))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("""
            Keys: ext:  name:  kind:  size>  size<  age>  age<  path:  in:  is:  type:
            in: downloads, desktop, documents, library, caches · is: duplicate, hardlink, cloud
            kind: video, audio, image, media, document, developer, archive · type: file, folder, any
            Bare words match names; -word excludes. Sizes like 500MB or 2GB; ages like 30d, 6m, 1y.
            """)
            .font(DiskMapType.caption)
            .foregroundStyle(DiskMapTheme.mutedLabel)
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Text("Nothing matches")
                .font(DiskMapType.section)
                .foregroundStyle(DiskMapTheme.ink)
            Text("Remove a chip or loosen a size or age.")
                .font(DiskMapType.body)
                .foregroundStyle(DiskMapTheme.mutedLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if matchCount > rows.count {
                    Text("Showing the first \(rows.count.formatted()) of \(matchCount.formatted()) — narrow the query to see the rest.")
                        .font(DiskMapType.caption)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                ForEach(rows) { row in
                    rowView(row)
                    Rectangle()
                        .fill(DiskMapTheme.cardStroke.opacity(0.65))
                        .frame(height: 1)
                        .padding(.leading, 56)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .listKeyboard(
            ids: rows.map(\.id), selection: $selectedID,
            path: { id in rows.first { $0.id == id }?.absolutePath },
            stage: { id in
                if let row = rows.first(where: { $0.id == id }) {
                    model.stageRow(path: row.absolutePath, size: row.bytes, reason: "Find: \(trimmedQuery)")
                }
            },
            selectAll: { checked = Set(rows.map(\.id)) },
            clearSelection: { checked.removeAll() }
        )
        .opacity(isRunning ? 0.6 : 1)
    }

    private func rowView(_ row: Row) -> some View {
        let isChecked = checked.contains(row.id)
        return HStack(alignment: .center, spacing: 12) {
            Button {
                if isChecked { checked.remove(row.id) } else { checked.insert(row.id) }
            } label: {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(isChecked ? DiskMapTheme.ink : DiskMapTheme.mutedLabel)
                    .frame(width: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isChecked ? "Deselect \(row.name)" : "Select \(row.name)")
            FileIdentityIcon(url: URL(fileURLWithPath: row.absolutePath), kind: row.isDirectory ? nil : row.kind, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)
                    .font(DiskMapType.bodyStrong)
                    .foregroundStyle(DiskMapTheme.ink)
                    .lineLimit(1)
                Text(row.parentDisplay)
                    .font(DiskMapType.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            Text(row.isDirectory ? "Folder" : row.kind.title)
                .font(DiskMapType.caption)
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .frame(width: 84, alignment: .leading)
            Text(Self.relativeModified(row.modifiedDay))
                .font(DiskMapType.caption)
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .frame(width: 96, alignment: .trailing)
            Text(ByteFormat.string(row.bytes))
                .font(DiskMapType.bodyStrong.monospacedDigit())
                .foregroundStyle(DiskMapTheme.ink)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isChecked || selectedID == row.id ? DiskMapTheme.ink.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.absolutePath)])
        }
        .simultaneousGesture(TapGesture().onEnded { selectedID = row.id })
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.absolutePath)])
            }
            Button("Quick Look") { DiskMapQuickLook.shared.show(URL(fileURLWithPath: row.absolutePath)) }
            Button("Show in Visualize") {
                model.selectedNode = row.id
                model.currentNode = row.isDirectory ? row.id : max(0, tree.parent[Int(row.id)])
                model.destination = .visualize
            }
            Button("Copy Path") { copyPaths([row.absolutePath]) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.name), \(ByteFormat.string(row.bytes)), \(Self.relativeModified(row.modifiedDay))")
    }

    static func relativeModified(_ day: Int32) -> String {
        guard day > 0 else { return "Unknown" }
        let age = AgeMap.today() - day
        if age <= 0 { return "Today" }
        if age == 1 { return "Yesterday" }
        if age < 30 { return "\(age) days ago" }
        if age < 365 { let months = max(1, age / 30); return months == 1 ? "1 month ago" : "\(months) months ago" }
        let years = max(1, age / 365)
        return years == 1 ? "1 year ago" : "\(years) years ago"
    }

    // MARK: Running

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
        let duplicates: Set<Int32>? = model.duplicateDidRun ? Set(model.duplicateGroups.flatMap(\.fileIDs)) : nil
        let context = FileQuery.Context(home: home, duplicateFileIDs: duplicates)
        let sort = model.findSort
        let sourceTree = tree
        let root = rootURL
        let work = Task.detached(priority: .userInitiated) { () -> (FileQuery.Result, [Row]) in
            let result = query.run(tree: sourceTree, root: root, totals: totals, context: context,
                                   sort: sort, limit: 500, isCancelled: { Task.isCancelled })
            let rows = result.ids.map { id -> Row in
                let path = sourceTree.path(of: id, root: root).path
                let name = sourceTree.name(of: id)
                return Row(id: id, name: name, absolutePath: path,
                           parentDisplay: CanonicalPath.parentDisplay(of: path),
                           kind: FileKind.classify(fileName: name, path: path),
                           bytes: totals.indices.contains(Int(id)) ? totals[Int(id)] : 0,
                           modifiedDay: sourceTree.modifiedDay[Int(id)],
                           isDirectory: sourceTree.isDirectory[Int(id)])
            }
            return (result, rows)
        }
        let (result, newRows) = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard !Task.isCancelled, !result.wasCancelled else { return }
        rows = newRows
        matchCount = result.matchCount
        matchedBytes = result.matchedBytes
        notes = result.notes
        checked.formIntersection(Set(newRows.map(\.id)))
        isRunning = false
    }

    private func stageChecked() async {
        let selection = checkedRows
        let summary = await model.stageForCleanup(selection.map {
            CleanupStageRequest(url: URL(fileURLWithPath: $0.absolutePath), size: $0.bytes, reason: "Find: \(trimmedQuery)")
        })
        let rejected = Set(summary.rejectedURLs.map(\.path))
        checked = Set(selection.filter { rejected.contains($0.absolutePath) }.map(\.id))
        model.showToast(summary.added > 0 ? "Added \(summary.added) to Cleanup" : "Nothing new added")
    }

    // MARK: Chip use, measured locally

    /// How often each chip is switched on, kept in this Mac's preferences
    /// only (nothing leaves the machine). This is the "measure which chips
    /// get used before deleting screens" step: `defaults read <bundle id>
    /// FindChipUses` shows the counts.
    static let chipUseKey = "FindChipUses"

    static func recordChipUse(_ id: String, defaults: UserDefaults = .standard) {
        var counts = defaults.dictionary(forKey: chipUseKey) as? [String: Int] ?? [:]
        counts[id, default: 0] += 1
        defaults.set(counts, forKey: chipUseKey)
    }
}
