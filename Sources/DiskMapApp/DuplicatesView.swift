import SwiftUI
import DiskMapCore

struct DuplicatesView: View {
    @ObservedObject var model: ScanModel
    let tree: FileTree
    let rootURL: URL

    @State private var checked: Set<Int32> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(model.isFindingDuplicates ? "Searching…" : "Find Duplicates") {
                    Task { await model.findDuplicates() }
                }
                .disabled(model.isFindingDuplicates)
                Spacer()
                Text("Will free \(diskByteString(reclaimable))")
                    .foregroundStyle(.secondary)
                Button("Stage Selected") { Task { await stageSelected() } }
                    .disabled(checked.isEmpty)
            }
            .padding(8)

            if model.isFindingDuplicates {
                ProgressView("Hashing files that are not shared clones…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.duplicateGroups.isEmpty {
                Text("No duplicate groups yet. Find Duplicates reads local file contents. Cloud-only files are skipped so they are not downloaded.")
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(model.duplicateGroups.enumerated()), id: \.offset) { _, group in
                        groupSection(group)
                    }
                }
            }
        }
        .onChange(of: model.duplicateGroups.map { $0.fileIDs }) { _, _ in
            loadDefaultChecks()
        }
    }

    private var reclaimable: Int64 {
        model.duplicateGroups.reduce(Int64(0)) { total, group in
            total + group.reclaimableBytes(deleting: checked)
        }
    }

    @ViewBuilder
    private func groupSection(_ group: DuplicateGroup) -> some View {
        Section {
            if group.sharesStorage {
                Text("Shares storage. Deleting one copy does not free \(diskByteString(group.sizeEach)). That space is freed only if every copy in this group is removed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(group.fileIDs, id: \.self) { id in
                Toggle(isOn: binding(id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tree.path(of: id, root: rootURL).path)
                            .lineLimit(1)
                        Text(diskByteString(group.sizeEach))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text(group.sharesStorage ? "Shared clone · \(diskByteString(group.sizeEach)) each" : "Same contents · \(diskByteString(group.sizeEach)) each")
        }
    }

    private func binding(_ id: Int32) -> Binding<Bool> {
        Binding(
            get: { checked.contains(id) },
            set: { isOn in
                if isOn { checked.insert(id) } else { checked.remove(id) }
            }
        )
    }

    private func loadDefaultChecks() {
        var next: Set<Int32> = []
        for group in model.duplicateGroups {
            let keeper = group.defaultKeeperID { tree.modifiedDay[Int($0)] }
            for id in group.fileIDs where id != keeper {
                next.insert(id)
            }
        }
        checked = next
    }

    private func stageSelected() async {
        for group in model.duplicateGroups {
            let selected = group.fileIDs.filter { checked.contains($0) }
            guard !selected.isEmpty else { continue }
            let key = group.sharesStorage ? "clone-\(group.fileIDs.map(String.init).joined(separator: "-"))" : nil
            for id in selected {
                let url = tree.path(of: id, root: rootURL)
                _ = await model.cleanupQueue.stage(
                    url,
                    size: group.sizeEach,
                    reason: group.sharesStorage ? "shared clone" : "duplicate",
                    sharesStorageGroup: key,
                    groupCopyCount: group.fileIDs.count
                )
            }
        }
        await model.refreshQueue()
    }
}
