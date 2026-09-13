import DiskMapCore
import SwiftUI

struct SnapshotDiffView: View {
    let tree: FileTree
    let rootURL: URL
    let basis: SizeBasis

    @State private var summaries: [(url: URL, header: SnapshotHeader)] = []
    @State private var beforeURL: URL?
    @State private var afterURL: URL?
    @State private var changes: [SnapshotChange] = []
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Save Snapshot") { save() }
                Spacer()
                Text(status)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack {
                picker("Before", selection: $beforeURL)
                picker("After", selection: $afterURL)
                Button("Compare") { compare() }
                    .disabled(beforeURL == nil || afterURL == nil)
            }
            List(changes, id: \.path) { change in
                HStack {
                    Text(change.path)
                        .lineLimit(1)
                    Spacer()
                    Text(deltaText(change))
                        .foregroundStyle(change.delta >= 0 ? Color.orange : Color.green)
                }
            }
        }
        .padding(8)
        .onAppear(perform: reload)
    }

    private func picker(_ title: String, selection: Binding<URL?>) -> some View {
        Picker(title, selection: selection) {
            Text("None").tag(URL?.none)
            ForEach(summaries, id: \.url) { item in
                Text(item.header.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    .tag(Optional(item.url))
            }
        }
    }

    private func reload() {
        summaries = SnapshotStore.summaries(in: SnapshotStore.defaultDirectory(), rootPath: rootURL.path)
        if beforeURL == nil { beforeURL = summaries.first?.url }
        if afterURL == nil { afterURL = summaries.last?.url }
    }

    private func save() {
        let snapshot = DiskSnapshot(rootPath: rootURL.path, capturedAt: Date(), tree: tree)
        let directory = SnapshotStore.defaultDirectory()
        do {
            _ = try SnapshotStore.save(snapshot, in: directory)
            status = "Saved"
            reload()
        } catch {
            status = "Could not save snapshot"
        }
    }

    private func compare() {
        guard let beforeURL, let afterURL else { return }
        do {
            let before = try SnapshotStore.load(from: beforeURL)
            let after = try SnapshotStore.load(from: afterURL)
            changes = SnapshotDiff.changes(before: before, after: after, basis: basis)
            status = "\(changes.count) folders changed"
        } catch {
            changes = []
            status = "Could not read those snapshots"
        }
    }

    private func deltaText(_ change: SnapshotChange) -> String {
        let sign = change.delta >= 0 ? "+" : "−"
        return "\(sign)\(diskByteString(abs(change.delta)))"
    }
}
