import SwiftUI
import DiskMapCore

struct QuickWinsView: View {
    @ObservedObject var model: ScanModel
    let tree: FileTree
    let totals: [Int64]
    let rootURL: URL

    @State private var checked: Set<Int32> = []

    private var hits: [QuickWins.Hit] {
        QuickWins.find(in: tree, root: rootURL, patterns: QuickWins.bundledPatterns())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(hits.count) regenerable folders · \(diskByteString(checkedSize)) selected")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add to Cleanup") { Task { await stageSelected() } }
                    .disabled(checked.isEmpty)
            }
            .padding(8)

            if hits.isEmpty {
                Text("No Quick Wins in this scan. The list is quick-wins-patterns.json — directory names like node_modules, plus a few cache paths.")
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(hits) { hit in
                    Toggle(isOn: binding(hit.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tree.path(of: hit.id, root: rootURL).path).lineLimit(1)
                            Text(diskByteString(size(of: hit.id)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var checkedSize: Int64 {
        checked.reduce(Int64(0)) { $0 + size(of: $1) }
    }

    private func size(of id: Int32) -> Int64 {
        let index = Int(id)
        guard totals.indices.contains(index) else { return 0 }
        return totals[index]
    }

    private func binding(_ id: Int32) -> Binding<Bool> {
        Binding(
            get: { checked.contains(id) },
            set: { isOn in
                if isOn { checked.insert(id) } else { checked.remove(id) }
            }
        )
    }

    private func stageSelected() async {
        for hit in hits where checked.contains(hit.id) {
            _ = await model.cleanupQueue.stage(
                tree.path(of: hit.id, root: rootURL),
                size: size(of: hit.id),
                reason: "quick win"
            )
        }
        await model.refreshQueue()
    }
}
