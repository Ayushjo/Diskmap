import DiskMapCore
import SwiftUI

/// Review-first duplicates list: select → inspect → stage. Does not rewrite CloneDetector.
struct DuplicatesView: View {
    @ObservedObject var model: ScanModel
    let tree: FileTree
    let rootURL: URL

    @State private var checked: Set<Int32> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(DiskMapTheme.cardStroke)

            if model.isFindingDuplicates {
                ProgressView("Hashing files that are not shared clones…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.duplicateGroups.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(Array(model.duplicateGroups.enumerated()), id: \.offset) { _, group in
                        groupSection(group)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(DiskMapTheme.cream)
            }
        }
        .background(DiskMapTheme.cream)
        .onChange(of: model.duplicateGroups.map { $0.fileIDs }) { _, _ in
            loadDefaultChecks()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Duplicates")
                        .font(DiskMapType.title)
                        .foregroundStyle(DiskMapTheme.ink)
                    Text("Review groups, keep one copy, stage the rest. Nothing moves to Trash until you confirm in Cleanup Review.")
                        .font(DiskMapType.body)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Will free \(diskByteString(reclaimable))")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(DiskMapTheme.ink)
                    Text("\(model.duplicateGroups.count) groups")
                        .font(DiskMapType.caption)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
            }
            HStack(spacing: 8) {
                Button(model.isFindingDuplicates ? "Searching…" : "Find Duplicates") {
                    Task { await model.findDuplicates() }
                }
                .buttonStyle(InkButtonStyle())
                .disabled(model.isFindingDuplicates)
                Button("Stage selected") { Task { await stageSelected() } }
                    .buttonStyle(PrimaryCTAStyle())
                    .disabled(checked.isEmpty)
                if model.duplicateGroups.contains(where: { $0.fileIDs.contains(model.selectedNode) }) {
                    Button("Show in Explore") {
                        model.exploreMode = .treemap
                        model.destination = .visualize
                    }
                    .buttonStyle(InkButtonStyle(filled: false))
                }
            }
        }
        .padding(16)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Text("No duplicate groups yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DiskMapTheme.ink)
            Text("Find Duplicates reads local file contents. Cloud-only files are skipped so they are not downloaded. Shared APFS clones are labeled separately.")
                .font(DiskMapType.body)
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Find Duplicates") {
                Task { await model.findDuplicates() }
            }
            .buttonStyle(InkButtonStyle())
            .disabled(model.isFindingDuplicates)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
            ForEach(group.fileIDs, id: \.self) { id in
                HStack(alignment: .center, spacing: 10) {
                    Toggle(isOn: binding(id)) { EmptyView() }
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                    Button {
                        model.selectedNode = id
                        let parent = tree.parent[Int(id)]
                        if parent >= 0 { model.currentNode = parent }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tree.name(of: id))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(DiskMapTheme.ink)
                                .lineLimit(1)
                            Text(tree.path(of: id, root: rootURL).path)
                                .font(.system(size: 11).monospaced())
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(diskByteString(group.sizeEach))
                                .font(DiskMapType.caption)
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listRowBackground(id == model.selectedNode ? DiskMapTheme.ink.opacity(0.08) : Color.clear)
            }
        } header: {
            Text(group.sharesStorage ? "Shared clone · \(diskByteString(group.sizeEach)) each" : "Same contents · \(diskByteString(group.sizeEach)) each")
                .foregroundStyle(DiskMapTheme.ink)
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
                if model.isStaged(url) { continue }
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
        model.showToast("Added to cleanup review")
    }
}
