import AppKit
import DiskMapCore
import SwiftUI

/// Review-first duplicates list: select → inspect → stage. Does not rewrite CloneDetector.
struct DuplicatesView: View {
    @ObservedObject var model: ScanModel
    @Environment(\.diskMapContentWidth) private var contentWidth
    let tree: FileTree
    let rootURL: URL

    @State private var checked: Set<Int32> = []

    private var hasGroups: Bool { !model.duplicateGroups.isEmpty && !model.isFindingDuplicates && model.duplicateError == nil }

    var body: some View {
        Group {
            if hasGroups {
                AdaptiveInspectorSplit(windowWidth: contentWidth, inspectionToken: String(model.selectedNode),
                                       main: mainColumn, inspector: inspector)
            } else {
                mainColumn
            }
        }
        .background(DiskMapTheme.canvas)
        .onChange(of: model.duplicateGroups.map { $0.fileIDs }) { _, _ in
            checked.removeAll()
        }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(eyebrow: "Find", title: "Duplicates",
                           subtitle: "Files with identical contents. Tick the copies you don’t need, then review them in Cleanup.") {
                    if model.duplicateDidRun && !model.isFindingDuplicates {
                        Button("Search Again") { Task { await model.findDuplicates() } }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                if hasGroups {
                    FigureStrip(figures: [
                        Figure(label: "Groups", value: model.duplicateGroups.count.formatted()),
                        Figure(label: "Copies", value: duplicateFileIDs.count.formatted()),
                        Figure(label: "Extra copies free", value: ByteFormat.string(extraCopiesBytes),
                               detail: "keeping the newest of each"),
                    ])
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, DiskMapSpace.pageTop)
            .padding(.bottom, 12)
            Hairline()

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
                DiskMapEmptyState(
                    symbol: "doc.on.doc",
                    title: model.duplicateDidRun ? "No duplicates found" : "Find files with identical contents",
                    message: model.duplicateDidRun
                        ? "Nothing in this scan is stored twice."
                        : "freedisk.space compares local files in stages, on this Mac. Cloud-only placeholders are skipped; shared APFS clones are recognised.",
                    primaryTitle: model.duplicateDidRun ? "Search Again" : "Find Duplicates",
                    primaryAction: { Task { await model.findDuplicates() } }
                )
            } else {
                list
                if checked.isEmpty {
                    HStack {
                        Text("Tick copies to remove, or")
                            .font(DiskMapType.secondary)
                            .foregroundStyle(DiskMapTheme.ink3)
                        Button("Select extra copies") { selectOtherCopies() }
                            .buttonStyle(LinkButtonStyle())
                            .font(DiskMapType.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 28)
                    .frame(height: 44)
                    .overlay(alignment: .top) { Hairline() }
                } else {
                    SelectionToolbar(
                        selectedCount: checked.count,
                        selectedBytes: reclaimable,
                        onPrimary: { Task { await stageSelected() } },
                        onClear: { checked.removeAll() },
                        onReveal: {
                            NSWorkspace.shared.activateFileViewerSelecting(checked.sorted().map { tree.path(of: $0, root: rootURL) })
                        },
                        paths: checked.sorted().map { tree.path(of: $0, root: rootURL).path }
                    )
                }
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.duplicateGroups.enumerated()), id: \.offset) { _, group in
                    groupSection(group)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
        }
        .listKeyboard(
            ids: duplicateFileIDs, selection: keyboardSelection,
            path: { tree.path(of: $0, root: rootURL).path },
            stage: { id in
                if let group = model.duplicateGroups.first(where: { $0.fileIDs.contains(id) }),
                   otherCopiesStaged(id, in: group) {
                    model.showToast("Keep at least one copy")
                    return
                }
                model.stageRow(path: tree.path(of: id, root: rootURL).path, size: tree.allocatedSize[Int(id)],
                               reason: "Duplicate of \(tree.name(of: id))")
            }
        )
    }

    private var inspector: some View {
        Group {
            let id = duplicateFileIDs.contains(model.selectedNode) ? model.selectedNode : (duplicateFileIDs.first ?? -1)
            if duplicateFileIDs.contains(id), let group = model.duplicateGroups.first(where: { $0.fileIDs.contains(id) }) {
                FileInspector(
                    model: model, tree: tree, rootURL: rootURL, id: id, size: tree.allocatedSize[Int(id)],
                    reason: group.sharesStorage ? "Shared APFS copy" : "Duplicate copy",
                    extraFacts: [("Copies", "\(group.fileIDs.count) with the same contents")],
                    note: group.sharesStorage
                        ? (label: "Shared storage", text: "These copies are APFS clones. Removing one frees nothing; the space returns only when every copy is gone.")
                        : (label: "Same contents", text: "Every copy in this group is byte-for-byte identical. Keep one."),
                    // Keep at least one copy: no staging the last one left.
                    allowStage: !otherCopiesStaged(id, in: group)
                )
            } else {
                DiskMapEmptyState(symbol: "doc.on.doc", title: "Select a copy", message: "Its details and actions appear here.")
            }
        }
        .background(DiskMapTheme.canvas)
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

    private func otherCopiesStaged(_ id: Int32, in group: DuplicateGroup) -> Bool {
        group.fileIDs.filter { $0 != id }.allSatisfy { model.isStaged(tree.path(of: $0, root: rootURL)) }
    }

    /// On-disk size of one member, the basis every reclaim figure uses.
    private func onDisk(_ group: DuplicateGroup) -> Int64 {
        group.fileIDs.map { tree.allocatedSize[Int($0)] }.max() ?? group.sizeEach
    }

    private var reclaimable: Int64 {
        model.duplicateGroups.reduce(Int64(0)) { total, group in
            total + group.reclaimableBytes(deleting: checked) { tree.allocatedSize[Int($0)] }
        }
    }

    /// What removing every copy but the suggested keeper would free.
    private var extraCopiesBytes: Int64 {
        model.duplicateGroups.reduce(Int64(0)) { total, group in
            let keeper = group.defaultKeeperID { tree.modifiedDay[Int($0)] }
            let extras = Set(group.fileIDs.filter { $0 != keeper })
            return total + group.reclaimableBytes(deleting: extras) { tree.allocatedSize[Int($0)] }
        }
    }

    private func groupSection(_ group: DuplicateGroup) -> some View {
        let keeper = group.defaultKeeperID { tree.modifiedDay[Int($0)] }
        let title = countLabel(group.fileIDs.count, "copy", "copies") + "  ·  " + diskByteString(onDisk(group)) + " each"
            + (group.sharesStorage ? "  ·  APFS clone" : "")
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader(label: title)
                .padding(.horizontal, 10)
                .padding(.top, 18)
                .padding(.bottom, 4)
            if group.sharesStorage {
                Text("Shares storage: removing one copy frees nothing until every copy is gone.")
                    .font(DiskMapType.secondary)
                    .foregroundStyle(DiskMapTheme.ink3)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }
            ForEach(group.fileIDs, id: \.self) { id in
                copyRow(id, keeper: keeper)
            }
        }
    }

    private func copyRow(_ id: Int32, keeper: Int32?) -> some View {
        let abs = tree.path(of: id, root: rootURL).path
        let isOn = checked.contains(id)
        return CheckRow {
            KitCheckbox(isOn: binding(id), label: isOn ? "Unmark \(tree.name(of: id))" : "Mark \(tree.name(of: id)) for removal")
            Button {
                model.selectedNode = id
                let parent = tree.parent[Int(id)]
                if parent >= 0 { model.currentNode = parent }
            } label: {
                KitRow(title: tree.name(of: id), subtitle: relativeParent(of: abs, root: rootURL),
                       selected: id == (duplicateFileIDs.contains(model.selectedNode) ? model.selectedNode : duplicateFileIDs.first),
                       path: abs, onStage: nil) {
                    FileIdentityIcon(url: URL(fileURLWithPath: abs), size: 24)
                } trailing: {
                    if id == keeper {
                        Text("Keeper")
                            .font(DiskMapType.secondary)
                            .foregroundStyle(DiskMapTheme.safe)
                            .help("Suggested keeper: the most recently modified copy")
                    }
                    MonoColumn(text: RelativeAge.short(day: tree.modifiedDay[Int(id)]), width: 74)
                    MonoColumn(text: diskByteString(tree.allocatedSize[Int(id)]), width: 74, emphasis: true)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(tree.name(of: id)), \(diskByteString(tree.allocatedSize[Int(id)]))\(id == keeper ? ", suggested keeper" : "")")
            .rowActions(path: abs, stage: nil)
        }
    }

    private var duplicateFileIDs: [Int32] { model.duplicateGroups.flatMap(\.fileIDs) }

    /// The row highlight already follows `model.selectedNode`; the keyboard
    /// moves the same selection.
    private var keyboardSelection: Binding<Int32?> {
        Binding(
            get: { duplicateFileIDs.contains(model.selectedNode) ? model.selectedNode : nil },
            set: { id in
                guard let id else { return }
                model.selectedNode = id
                let parent = tree.parent[Int(id)]
                if parent >= 0 { model.currentNode = parent }
            }
        )
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
                    size: tree.allocatedSize[Int(id)],
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
