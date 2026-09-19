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
    /// Latest-clicked compare wins — concurrent detached loads must not
    /// let an earlier pair overwrite the rows the user just asked for.
    @State private var compareGeneration = 0

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
        .onAppear { Task { await reload() } }
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

    private func reload() async {
        let rootPath = rootURL.path
        let found = await Task.detached(priority: .userInitiated) {
            SnapshotStore.summaries(in: SnapshotStore.defaultDirectory(), rootPath: rootPath)
        }.value
        summaries = found
        if beforeURL == nil { beforeURL = found.first?.url }
        if afterURL == nil { afterURL = found.last?.url }
    }

    private func save() {
        // Encoding a million-node snapshot blocks; do it off-actor.
        let snapshot = DiskSnapshot(rootPath: rootURL.path, capturedAt: Date(), tree: tree)
        status = "Saving…"
        Task {
            let directory = SnapshotStore.defaultDirectory()
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try SnapshotStore.save(snapshot, in: directory)
                }.value
                status = "Saved"
            } catch {
                status = "Could not save snapshot"
            }
            await reload()
        }
    }

    private func compare() {
        guard let beforeURL, let afterURL else { return }
        compareGeneration += 1
        let generation = compareGeneration
        status = "Comparing…"
        Task {
            do {
                // Decode + diff walk every node twice; off the main actor.
                let diff = try await Task.detached(priority: .userInitiated) {
                    let before = try SnapshotStore.load(from: beforeURL)
                    let after = try SnapshotStore.load(from: afterURL)
                    return SnapshotDiff.changes(before: before, after: after, basis: basis)
                }.value
                guard generation == compareGeneration else { return }
                changes = diff
                status = "\(diff.count) folders changed"
            } catch {
                guard generation == compareGeneration else { return }
                changes = []
                status = "Could not read those snapshots"
            }
        }
    }

    private func deltaText(_ change: SnapshotChange) -> String {
        let sign = change.delta >= 0 ? "+" : "−"
        return "\(sign)\(diskByteString(abs(change.delta)))"
    }
}
