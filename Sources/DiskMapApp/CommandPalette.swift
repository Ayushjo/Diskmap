import SwiftUI
import DiskMapCore

struct CommandPalette: View {
    @ObservedObject var model: ScanModel
    @Binding var isPresented: Bool
    @State private var query: String
    var onReviewCleanup: () -> Void

    init(model: ScanModel, isPresented: Binding<Bool>, initialQuery: String = "", onReviewCleanup: @escaping () -> Void) {
        self.model = model
        self._isPresented = isPresented
        self._query = State(initialValue: initialQuery)
        self.onReviewCleanup = onReviewCleanup
    }

    private struct Command: Identifiable {
        var id: String { title + subtitle }
        var title: String
        var subtitle: String
        var symbol: String
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
                model.destination = .overview
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
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            for file in model.analysis.topFiles where file.name.lowercased().contains(q) || file.relativePath.lowercased().contains(q) {
                let hit = file
                list.append(Command(
                    title: hit.name,
                    subtitle: "File · \(hit.relativePath)",
                    symbol: "doc"
                ) {
                    model.destination = .visualize
                    model.selectedNode = hit.nodeID
                    model.currentNode = hit.nodeID
                })
            }
            for folder in model.analysis.topFolders where folder.name.lowercased().contains(q) || folder.relativePath.lowercased().contains(q) {
                let hit = folder
                list.append(Command(
                    title: hit.name,
                    subtitle: "Folder · \(hit.relativePath)",
                    symbol: "folder"
                ) {
                    model.destination = .visualize
                    model.selectedNode = hit.nodeID
                    model.currentNode = hit.nodeID
                })
            }
        }
        return list
    }

    private var filtered: [Command] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return commands.filter { !$0.subtitle.hasPrefix("File ·") && !$0.subtitle.hasPrefix("Folder ·") } }
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
                    ForEach(filtered) { cmd in
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
    }
}
