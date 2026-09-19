import DiskMapCore
import SwiftUI

/// Quick Wins grouped by developer ecosystem — node_modules, DerivedData,
/// dependency caches — so it reads as "what a developer wants to reclaim"
/// instead of one flat list. Categories come from the pattern JSON, not
/// hardcoded here.
struct DeveloperView: View {
    let model: ScanModel
    let tree: FileTree
    let totals: [Int64]
    let rootURL: URL

    @State private var hits: [QuickWins.Hit]?
    @State private var selected: Set<Int32> = []

    private let categories = QuickWins.bundledCategories()
    private let impactThreshold: Int64 = 10_000_000

    private func hits(in category: QuickWins.Category) -> [QuickWins.Hit] {
        (hits ?? [])
            .filter { $0.categoryID == category.id }
            .sorted { totals[Int($0.id)] > totals[Int($1.id)] }
    }

    private func bytes(_ hits: [QuickWins.Hit]) -> Int64 {
        hits.reduce(0) { $0 + totals[Int($1.id)] }
    }

    private var totalBytes: Int64 { bytes(hits ?? []) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Regenerable developer data")
                    .font(.headline)
                Text("Dependencies, build output and caches your tools recreate on demand — grouped so you can weigh each ecosystem.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 6)

            if let hits {
                if hits.isEmpty {
                    Spacer()
                    Text("Nothing matched. Nice clean machine.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    List {
                        ForEach(categories) { category in
                            let group = hits(in: category)
                            if !group.isEmpty {
                                Section {
                                    ForEach(group) { hit in
                                        row(hit)
                                    }
                                } header: {
                                    categoryHeader(category, group: group)
                                }
                            }
                        }
                    }
                    footer
                }
            } else {
                Spacer()
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                Spacer()
            }
        }
        .task(id: model.scanID) {
            selected = []
            hits = await Task.detached(priority: .userInitiated) {
                QuickWins.findCategorized(in: tree, root: rootURL, categories: categories)
            }.value
        }
    }

    private func categoryHeader(_ category: QuickWins.Category, group: [QuickWins.Hit]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(category.title) — \(group.count) items, \(ByteCountFormatter.string(fromByteCount: bytes(group), countStyle: .file))")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Stage All") {
                    for hit in group { selected.insert(hit.id) }
                    stageSelected()
                }
            }
            if !category.note.isEmpty {
                Text(category.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.none)
            }
        }
    }

    private func row(_ hit: QuickWins.Hit) -> some View {
        let index = Int(hit.id)
        let url = tree.path(of: hit.id, root: rootURL)
        let size = totals[index]
        return Toggle(isOn: binding(for: hit.id)) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(hit.name).font(.body)
                    if size >= impactThreshold {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("Bigger than 10 MB — worth a look")
                    }
                }
                Text(url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .badge(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Text("Across categories: \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Text("\(selected.count) selected")
                Spacer()
                Button("Stage Selected") { stageSelected() }
                    .disabled(selected.isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Divider() }
    }

    private func binding(for id: Int32) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { isOn in
                if isOn { selected.insert(id) } else { selected.remove(id) }
            }
        )
    }

    private func stageSelected() {
        for id in selected {
            let url = tree.path(of: id, root: rootURL)
            let category = hits?.first { $0.id == id }?.categoryID ?? "dev"
            Task {
                _ = await model.cleanupQueue.stage(url, size: totals[Int(id)], reason: "dev: \(category)")
                await model.refreshQueue()
            }
        }
    }
}
