import DiskMapCore
import SwiftUI

/// Find-as-you-type file search over the current scan. The index is built
/// once per scan; each keystroke only touches nodes whose interned name
/// matched, so the list stays live on million-item trees.
struct SearchView: View {
    let model: ScanModel
    let tree: FileTree
    let totals: [Int64]
    let rootURL: URL
    @Binding var currentNode: Int32
    /// Jump to the Map page centered on a hit.
    let openInMap: () -> Void

    @State private var index: FileSearchIndex?
    @State private var query = ""
    @State private var kind: FileSearchIndex.KindFilter = .all
    @State private var result = FileSearchIndex.Result.empty
    /// Bumped when the index finishes building, so a query typed during
    /// the build re-runs once the index exists.
    @State private var indexGeneration = 0

    /// The inputs a run depends on — `.task(id:)` keys to this.
    private struct SearchKey: Equatable {
        var query: String
        var kind: FileSearchIndex.KindFilter
        var scanID: UUID
        var indexGeneration: Int
        /// Ranking input — toggling it must re-run, not just re-render.
        var basis: SizeBasis
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search \(rootURL.lastPathComponent)", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                }
                Picker("Kind", selection: $kind) {
                    ForEach(FileSearchIndex.KindFilter.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
                .labelsHidden()
            }
            .padding(10)

            Divider()

            if index == nil {
                Spacer()
                HStack {
                    Spacer()
                    ProgressView()
                    Text("Indexing \(tree.count.formatted()) items…")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Spacer()
            } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                hint("Type to search every scanned name — matches against folders and files as you type.")
            } else if result.ids.isEmpty {
                hint("No matches for “\(query)”.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(result.ids, id: \.self) { id in
                            row(id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                footer
            }
        }
        .task(id: model.scanID) {
            index = nil
            result = .empty
            // One interned-name pass per scan — cheap compared to the scan.
            let built = await Task.detached(priority: .userInitiated) {
                FileSearchIndex(tree: tree)
            }.value
            index = built
            indexGeneration += 1
        }
        .task(id: SearchKey(
            query: query,
            kind: kind,
            scanID: model.scanID,
            indexGeneration: indexGeneration,
            basis: model.sizeBasis
        )) {
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let index, !needle.isEmpty else {
                result = .empty
                return
            }
            // Debounce: wait out a fast typist, then run off-actor.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) {
                index.search(needle, in: tree, totals: totals, kind: kind)
            }.value
            // A newer keystroke already superseded this result.
            guard !Task.isCancelled else { return }
            result = found
        }
    }

    private func hint(_ text: String) -> some View {
        Spacer()
            .overlay {
                Text(text)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
    }

    private var footer: some View {
        HStack {
            let shown = result.ids.count
            let total = result.totalMatches
            Text(total > shown
                 ? "Showing \(shown) biggest of \(total.formatted()) matches across \(result.matchedNames.formatted()) names"
                 : "\(total.formatted()) matches")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private func row(_ id: Int32) -> some View {
        let index = Int(id)
        let isDirectory = tree.isDirectory[index]
        let notDownloaded = tree.flags[index] & NodeFlags.notDownloaded != 0
        HStack(spacing: 8) {
            Image(systemName: notDownloaded
                  ? "icloud"
                  : isDirectory ? "folder" : "doc")
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(tree.name(of: id))
                .lineLimit(1)
            Text(tree.path(of: id, root: rootURL).path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: totals[index], countStyle: .file))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Show") {
                currentNode = isDirectory ? id : tree.parent[index]
                openInMap()
            }
            .help("Show in map")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { revealDownloadedFile(id, tree: tree, root: rootURL) }
        .onTapGesture(count: 1) {}
    }
}
