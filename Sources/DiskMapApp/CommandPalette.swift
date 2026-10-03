import SwiftUI
import DiskMapCore

struct CommandPalette: View {
    @ObservedObject var model: ScanModel
    @Binding var isPresented: Bool
    @State private var query: String
    @State private var searchHits: [SearchHit] = []
    @State private var isSearching = false
    @State private var queryMatchCount = 0
    @State private var queryMatchedBytes: Int64 = 0
    var onReviewCleanup: () -> Void
    var onExplain: () -> Void

    init(model: ScanModel, isPresented: Binding<Bool>, initialQuery: String = "", onReviewCleanup: @escaping () -> Void, onExplain: @escaping () -> Void) {
        self.model = model
        self._isPresented = isPresented
        self._query = State(initialValue: initialQuery)
        self.onReviewCleanup = onReviewCleanup
        self.onExplain = onExplain
    }

    private enum Category: String, CaseIterable { case actions = "Actions", files = "Files", folders = "Folders", applications = "Applications" }

    private struct SearchHit: Identifiable, Sendable {
        var id: Int32 { nodeID }
        var nodeID: Int32
        var parentID: Int32
        var name: String
        var path: String
        var isDirectory: Bool
        var isApplication: Bool
        var bytes: Int64
    }

    /// TASK-059: the palette speaks the Find query language. Anything with a
    /// `key:` or `size>`-style token is a query, not a command search.
    private var parsedQuery: FileQuery.Parsed? {
        guard let root = model.rootURL else { return nil }
        return FileQuery.parse(query, home: NSHomeDirectory(), root: root.path)
    }

    private var isStructuredQuery: Bool { parsedQuery?.query.isStructured ?? false }

    private func openInFind() {
        model.findQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        model.destination = .find
    }

    private struct Command: Identifiable {
        var id: String { title + subtitle }
        var title: String
        var subtitle: String
        var symbol: String
        var category: Category = .actions
        var run: () -> Void
    }

    private var commands: [Command] {
        var list: [Command] = [
            Command(title: "Go to Overview", subtitle: "Home", symbol: "square.grid.2x2") {
                model.destination = .overview
            },
            Command(title: "Find files larger than 1 GB", subtitle: "Biggest Files", symbol: "doc.fill") {
                model.destination = .biggestFiles
            },
            Command(title: "Open Find", subtitle: "Search the scan: ext:mp4 size>500MB age>1y in:downloads", symbol: "magnifyingglass") {
                model.destination = .find
            },
            Command(title: "Show biggest folders", subtitle: "Find", symbol: "folder.fill") {
                model.destination = .biggestFolders
            },
            Command(title: "Show forgotten files", subtitle: "Files not modified in over a year", symbol: "clock") {
                model.destination = .forgottenFiles
            },
            Command(title: "Show duplicates", subtitle: "Find", symbol: "doc.on.doc") {
                model.destination = .duplicates
            },
            Command(title: "Show caches", subtitle: "Clean · review first", symbol: "internaldrive") {
                model.destination = .cleanCaches
            },
            Command(title: "Show developer storage", subtitle: "Explore", symbol: "chevron.left.forwardslash.chevron.right") {
                model.destination = .developerStorage
            },
            Command(title: "Open Visualize", subtitle: "Treemap and charts", symbol: "square.grid.3x3") {
                model.destination = .visualize
                model.exploreMode = .treemap
            },
            Command(title: "Explain my storage", subtitle: "Structured summary from scan facts", symbol: "sparkles") {
                onExplain()
            },
            Command(title: "Review cleanup", subtitle: "Opens review queue — never deletes directly", symbol: "leaf") {
                onReviewCleanup()
            },
            Command(title: "Scan again", subtitle: "Re-read what changed since the last scan", symbol: "arrow.clockwise") {
                if let root = model.rootURL {
                    Task { await model.scan(root) }
                }
            },
            Command(title: "Full rescan", subtitle: "Walk every folder again, ignoring the last scan", symbol: "arrow.clockwise.circle") {
                if let root = model.rootURL {
                    Task { await model.scan(root, mode: .full) }
                }
            },
        ]
        // TASK-081: saved searches are commands too.
        for search in model.savedSearches {
            let total = model.savedSearchTotals[search.id]
            list.append(Command(title: search.name,
                                subtitle: "Saved search · " + (total.map { "\($0.count.formatted()) · \(ByteFormat.string($0.bytes))" } ?? search.query),
                                symbol: "magnifyingglass.circle") {
                model.openSavedSearch(search)
            })
        }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for hit in searchHits {
                list.append(Command(
                    title: hit.name,
                    subtitle: ByteFormat.string(hit.bytes) + " · " + hit.path,
                    symbol: hit.isApplication ? "app" : (hit.isDirectory ? "folder" : "doc"),
                    category: hit.isApplication ? .applications : (hit.isDirectory ? .folders : .files)
                ) {
                    model.destination = .visualize
                    model.selectedNode = hit.nodeID
                    model.currentNode = hit.isDirectory ? hit.nodeID : max(0, hit.parentID)
                })
            }
        }
        return list
    }

    private var filtered: [Command] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return commands.filter { $0.category == .actions } }
        if isStructuredQuery {
            let meaning = parsedQuery?.query.describe(home: NSHomeDirectory()).joined(separator: " · ") ?? ""
            let summary = isSearching ? "Searching…"
                : "\(queryMatchCount.formatted()) match\(queryMatchCount == 1 ? "" : "es") · \(ByteFormat.string(queryMatchedBytes))"
            let findAll = Command(title: "Show all in Find — \(summary)", subtitle: meaning, symbol: "magnifyingglass") {
                openInFind()
            }
            return [findAll] + commands.filter { $0.category != .actions }
        }
        // File hits were already matched word by word; only actions are
        // matched against the typed text here.
        return commands.filter {
            $0.category != .actions || $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .accessibilityHidden(true)
                TextField("Type a command, a file name, or a query like ext:mp4 size>1GB", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .accessibilityLabel("Command palette search")
                Button("Esc") { isPresented = false }
                    .buttonStyle(.plain)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .accessibilityLabel("Close command palette")
            }
            .padding(14)
            if isStructuredQuery, let problems = parsedQuery?.problems, !problems.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(problems, id: \.token) { problem in
                        Text("Ignoring \(problem.token) — \(problem.message)")
                            .font(DiskMapType.caption)
                            .foregroundStyle(DiskMapTheme.review)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Category.allCases, id: \.self) { category in
                        let section = filtered.filter { $0.category == category }
                        if !section.isEmpty {
                            Text(category.rawValue.uppercased())
                                .font(DiskMapType.microStrong)
                                .tracking(0.8)
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                            ForEach(section) { cmd in
                        Button {
                            cmd.run()
                            isPresented = false
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: cmd.symbol)
                                    .frame(width: 22)
                                    .foregroundStyle(DiskMapTheme.ink)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cmd.title)
                                        .font(DiskMapType.bodyMedium)
                                        .foregroundStyle(DiskMapTheme.ink)
                                    Text(cmd.subtitle)
                                        .font(DiskMapType.caption)
                                        .foregroundStyle(DiskMapTheme.mutedLabel)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(cmd.title). \(cmd.subtitle)")
                            }
                        }
                    }
                    if isSearching {
                        ProgressView("Searching this scan…")
                            .controlSize(.small)
                            .padding(12)
                    }
                }
                .padding(8)
            }
            Text("Destructive actions never run from here — they only open review flows.")
                .font(DiskMapType.micro)
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .padding(10)
                .accessibilityLabel("Safety note: destructive actions never run from the command palette")
        }
        .frame(width: 520, height: 420)
        .background(DiskMapTheme.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
        .task(id: query) { await updateSearch() }
    }

    @MainActor
    private func updateSearch() async {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, let tree = model.tree, let root = model.rootURL,
              model.selectedTotals.count == tree.count else {
            searchHits = []
            isSearching = false
            return
        }
        isSearching = true
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        // Plain words search names only, largest first — the old search built
        // a full path for every node on every keystroke.
        let parsed = FileQuery.parse(normalized, home: NSHomeDirectory(), root: root.path)
        let limit = parsed.query.isStructured ? 8 : 100
        let totals = model.selectedTotals
        let duplicates: Set<Int32>? = model.duplicateDidRun ? Set(model.duplicateGroups.flatMap(\.fileIDs)) : nil
        let context = FileQuery.Context(home: NSHomeDirectory(), duplicateFileIDs: duplicates)
        let work = Task.detached(priority: .userInitiated) { () -> (FileQuery.Result, [SearchHit]) in
            let result = parsed.query.run(tree: tree, root: root, totals: totals, context: context,
                                          limit: limit, isCancelled: { Task.isCancelled })
            let hits = result.ids.map { id -> SearchHit in
                let index = Int(id)
                let name = tree.name(of: id)
                let directory = tree.isDirectory[index]
                return SearchHit(
                    nodeID: id,
                    parentID: tree.parent[index],
                    name: name,
                    path: CanonicalPath.displayPath(absolutePath: tree.path(of: id, root: root).path),
                    isDirectory: directory,
                    isApplication: directory && name.lowercased().hasSuffix(".app"),
                    bytes: totals[index]
                )
            }
            return (result, hits)
        }
        let (result, hits) = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard !Task.isCancelled, !result.wasCancelled else { return }
        searchHits = hits
        queryMatchCount = result.matchCount
        queryMatchedBytes = result.matchedBytes
        isSearching = false
    }
}
