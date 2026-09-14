import SwiftUI

struct CommandPalette: View {
    @ObservedObject var model: ScanModel
    @Binding var isPresented: Bool
    @State private var query = ""
    var onReviewCleanup: () -> Void

    private struct Command: Identifiable {
        var id: String { title }
        var title: String
        var subtitle: String
        var symbol: String
        var run: () -> Void
    }

    private var commands: [Command] {
        [
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
            Command(title: "Review cleanup", subtitle: "Opens review queue — never deletes directly", symbol: "leaf") {
                onReviewCleanup()
            },
            Command(title: "Scan again", subtitle: "Rescan current root", symbol: "arrow.clockwise") {
                if let root = model.rootURL {
                    Task { await model.scan(root) }
                }
            },
        ]
    }

    private var filtered: [Command] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return commands }
        return commands.filter {
            $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                TextField("Type a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                Button("Esc") { isPresented = false }
                    .buttonStyle(.plain)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
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
                    }
                }
                .padding(8)
            }
            Text("Destructive actions never run from here — they only open review flows.")
                .font(.system(size: 10))
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .padding(10)
        }
        .frame(width: 520, height: 420)
        .background(DiskMapTheme.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
    }
}
