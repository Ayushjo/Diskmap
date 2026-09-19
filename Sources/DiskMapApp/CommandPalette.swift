import SwiftUI
import DiskMapCore

struct CommandPalette: View {
    @ObservedObject var model: ScanModel
    @Binding var isPresented: Bool
    @State private var query: String
    @State private var searchHits: [SearchHit] = []
    @State private var isSearching = false
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
            Command(title: "Scan again", subtitle: "Rescan current root", symbol: "arrow.clockwise") {
                if let root = model.rootURL {
                    Task { await model.scan(root) }
                }
            },
        ]
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for hit in searchHits {
                list.append(Command(
                    title: hit.name,
                    subtitle: hit.path,
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
        return commands.filter {
            $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .accessibilityHidden(true)
                TextField("Type a command or file name…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .accessibilityLabel("Command palette search")
                Button("Esc") { isPresented = false }
                    .buttonStyle(.plain)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .accessibilityLabel("Close command palette")
            }
            .padding(14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Category.allCases, id: \.self) { category in
                        let section = filtered.filter { $0.category == category }
                        if !section.isEmpty {
                            Text(category.rawValue.uppercased())
                                .font(.system(size: 10, weight: .semibold))
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
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(DiskMapTheme.ink)
                                    Text(cmd.subtitle)
                                        .font(.system(size: 11))
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
                .font(.system(size: 10))
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
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, let tree = model.tree, let root = model.rootURL else {
            searchHits = []
            isSearching = false
            return
        }
        isSearching = true
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let hits = await Task.detached(priority: .userInitiated) {
            var found: [SearchHit] = []
            found.reserveCapacity(100)
            for index in 1..<tree.count {
                if index & 1_023 == 0, Task.isCancelled { return found }
                let id = Int32(index)
                let name = tree.name(of: id)
                let path = tree.path(of: id, root: root).path
                guard name.localizedCaseInsensitiveContains(normalized)
                        || path.localizedCaseInsensitiveContains(normalized) else { continue }
                let directory = tree.isDirectory[index]
                found.append(SearchHit(
                    nodeID: id,
                    parentID: tree.parent[index],
                    name: name,
                    path: CanonicalPath.displayPath(absolutePath: path),
                    isDirectory: directory,
                    isApplication: directory && name.lowercased().hasSuffix(".app")
                ))
                if found.count == 100 { break }
            }
            return found
        }.value
        guard !Task.isCancelled else { return }
        searchHits = hits
        isSearching = false
    }
}
