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
                loadingState
            } else if let err = model.duplicateError {
                DiskMapEmptyState(
                    symbol: "exclamationmark.triangle",
                    title: "Couldn’t finish duplicate search",
                    message: err,
                    primaryTitle: "Try again",
                    primaryAction: { Task { await model.findDuplicates() } },
                    secondaryTitle: "Clear",
                    secondaryAction: {
                        model.duplicateError = nil
                        model.duplicatePhase = .idle
                    }
                )
            } else if model.duplicatePhase == .cancelled && model.duplicateGroups.isEmpty {
                DiskMapEmptyState(
                    symbol: "stop.circle",
                    title: "Search cancelled",
                    message: "No duplicate groups were kept from the cancelled run. Start again when you’re ready.",
                    primaryTitle: "Find Duplicates",
                    primaryAction: { Task { await model.findDuplicates() } }
                )
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

                if !checked.isEmpty {
                    SelectionToolbar(
                        selectedCount: checked.count,
                        selectedBytes: reclaimable,
                        primaryTitle: "Add to Cleanup",
                        onPrimary: { Task { await stageSelected() } },
                        onClear: { checked.removeAll() }
                    )
                }
            }
        }
        .background(DiskMapTheme.cream)
        .onChange(of: model.duplicateGroups.map { $0.fileIDs }) { _, _ in
            checked.removeAll()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DiskMapSpace.sm) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: DiskMapSpace.xxs) {
                    Text("Duplicates")
                        .font(DiskMapType.title)
                        .foregroundStyle(DiskMapTheme.ink)
                    Text("Review groups, choose the copies you no longer need, then confirm them in Cleanup.")
                        .font(DiskMapType.body)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
                Spacer(minLength: 8)
                if model.duplicateDidRun || !model.duplicateGroups.isEmpty {
                    VStack(alignment: .trailing, spacing: DiskMapSpace.xxs) {
                        Text("Estimated \(diskByteString(reclaimable))")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(DiskMapTheme.ink)
                        Text("\(model.duplicateGroups.count) groups")
                            .font(DiskMapType.caption)
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                }
            }
            HStack(spacing: DiskMapSpace.xs) {
                if model.isFindingDuplicates {
                    Button("Cancel") { model.cancelDuplicateSearch() }
                        .buttonStyle(InkButtonStyle(filled: false))
                } else if model.duplicateDidRun {
                    Button("Find Duplicates") {
                        Task { await model.findDuplicates() }
                    }
                    .buttonStyle(InkButtonStyle())
                }
                if !model.duplicateGroups.isEmpty {
                    Button("Select other copies") { selectOtherCopies() }
                        .buttonStyle(InkButtonStyle(filled: false))
                }
                if model.duplicateGroups.contains(where: { $0.fileIDs.contains(model.selectedNode) }) {
                    Button("Show in Explore") {
                        model.exploreMode = .treemap
                        model.destination = .visualize
                    }
                    .buttonStyle(InkButtonStyle(filled: false))
                }
            }
        }
        .padding(DiskMapSpace.md)
    }

    private var loadingState: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let total = model.duplicateProgressTotal
            let done = model.duplicateProgressDone
            let fraction: Double? = total > 0 ? Double(done) / Double(total) : nil
            DiskMapLoadingState(
                title: model.duplicatePhase.title,
                detail: loadingDetail(at: context.date),
                fraction: fraction,
                processed: total > 0 ? done : nil,
                total: total > 0 ? total : nil,
                onCancel: { model.cancelDuplicateSearch() }
            )
        }
    }

    private func loadingDetail(at now: Date) -> String {
        let elapsed = Int(now.timeIntervalSince(model.duplicateStartedAt ?? now))
        let stalled = now.timeIntervalSince(model.duplicateLastProgressAt ?? now) >= 30
        let suffix = stalled ? " No progress has been reported for 30 seconds; the disk may still be working. You can cancel safely." : " Elapsed: \(elapsed)s."
        switch model.duplicatePhase {
        case .preparing:
            return "Preparing a local comparison." + suffix
        case .collecting:
            return "\(model.duplicateFilesExamined.formatted()) items checked · \(model.duplicateCandidateCount.formatted()) local candidates. Cloud-only placeholders are skipped." + suffix
        case .grouping:
            return "Looking for files that share the same size — the inexpensive first filter." + suffix
        case .hashing:
            return "Comparing candidate groups locally. Shared APFS clones avoid a full content hash when possible." + suffix
        case .assembling:
            return "Preparing the groups for review." + suffix
        default:
            return "Working…"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            DuplicateEmptyIllustration()
            VStack(spacing: 7) {
                Text(model.duplicateDidRun ? "No duplicate groups found" : "Find files with identical contents")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.ink)
                Text(model.duplicateDidRun
                     ? "DiskMap didn’t find independently stored duplicate groups in this scan."
                     : "DiskMap compares local files in stages and keeps everything on your Mac. Cloud-only placeholders are skipped; shared APFS storage is identified separately.")
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 480)
            }
            Button(model.duplicateDidRun ? "Search Again" : "Find Duplicates") {
                Task { await model.findDuplicates() }
            }
            .buttonStyle(InkButtonStyle())
        }
        .padding(32)
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
                let keeper = group.defaultKeeperID { tree.modifiedDay[Int($0)] }
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
                            Text(CanonicalPath.displayPath(absolutePath: tree.path(of: id, root: rootURL).path))
                                .font(.system(size: 11).monospaced())
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(diskByteString(group.sizeEach))
                                .font(DiskMapType.caption)
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                            if id == keeper {
                                Text("Suggested keeper")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(DiskMapTheme.safe)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listRowBackground(id == model.selectedNode ? DiskMapTheme.navSelected : Color.clear)
            }
        } header: {
            HStack {
                Text(group.sharesStorage ? "Shared clone · \(diskByteString(group.sizeEach)) each" : "Same contents · \(diskByteString(group.sizeEach)) each")
                    .foregroundStyle(DiskMapTheme.ink)
                if group.sharesStorage {
                    ClassificationBadge(kind: .custom(title: "APFS clone", tint: DiskMapTheme.info))
                }
            }
        }
    }

    private func binding(_ id: Int32) -> Binding<Bool> {
        Binding(
            get: { checked.contains(id) },
            set: { isOn in
                if isOn {
                    guard let group = model.duplicateGroups.first(where: { $0.fileIDs.contains(id) }) else {
                        checked.insert(id)
                        return
                    }
                    let selectedInGroup = group.fileIDs.filter { checked.contains($0) }.count
                    if selectedInGroup < group.fileIDs.count - 1 {
                        checked.insert(id)
                    } else {
                        model.showToast("Keep at least one copy")
                    }
                } else {
                    checked.remove(id)
                }
            }
        )
    }

    private func selectOtherCopies() {
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
        var requests: [CleanupStageRequest] = []
        for group in model.duplicateGroups {
            let selected = group.fileIDs.filter { checked.contains($0) }
            guard !selected.isEmpty else { continue }
            let key = group.sharesStorage ? "clone-\(group.fileIDs.map(String.init).joined(separator: "-"))" : nil
            for id in selected {
                let url = tree.path(of: id, root: rootURL)
                requests.append(CleanupStageRequest(
                    url: url,
                    size: group.sizeEach,
                    reason: group.sharesStorage ? "Shared APFS copy" : "Duplicate copy",
                    sharesStorageGroup: key,
                    groupCopyCount: group.fileIDs.count
                ))
            }
        }
        let result = await model.stageForCleanup(requests)
        let rejected = Set(result.rejectedURLs.map(\.standardizedFileURL.path))
        checked = Set(checked.filter { rejected.contains(tree.path(of: $0, root: rootURL).standardizedFileURL.path) })
        model.showToast(result.added > 0 ? "Added \(result.added) copies to Cleanup" : "Nothing new added")
    }
}

private struct DuplicateEmptyIllustration: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(DiskMapTheme.info.opacity(0.08))
                .frame(width: 116, height: 92)
            fileCard(offset: CGSize(width: 14, height: -8), tint: DiskMapTheme.developer.opacity(0.22))
            fileCard(offset: CGSize(width: -14, height: 8), tint: DiskMapTheme.info.opacity(0.18))
            Image(systemName: "equal.circle.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(DiskMapTheme.ink)
                .background(Circle().fill(DiskMapTheme.cardFill).frame(width: 34, height: 34))
        }
        .accessibilityHidden(true)
    }

    private func fileCard(offset: CGSize, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(DiskMapTheme.cardFill)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(DiskMapTheme.cardStroke, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 22, height: 6)
                    RoundedRectangle(cornerRadius: 2).fill(DiskMapTheme.cardStroke).frame(width: 36, height: 4)
                }.padding(9)
            }
            .frame(width: 58, height: 68)
            .offset(offset)
    }
}
