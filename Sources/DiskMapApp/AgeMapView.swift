import AppKit
import DiskMapCore
import SwiftUI

/// Visualize → Age Map: the scan by last-modified age, and the largest
/// files untouched for over a year.
struct AgeMapView: View {
    @ObservedObject var model: ScanModel
    let tree: FileTree
    let totals: [Int64]
    let rootURL: URL

    @State private var checked: Set<Int32> = []
    @State private var filterBucket: AgeBucket? = nil
    @State private var bucketSizes: [AgeBucket: Int64] = [:]
    @State private var untouched: [Int32] = []
    @State private var isPreparing = true

    private var today: Int32 { AgeMap.today() }

    private var filteredUntouched: [Int32] {
        guard let filterBucket else { return untouched }
        return untouched.filter { AgeMap.bucket(modifiedDay: tree.modifiedDay[Int($0)], today: today) == filterBucket }
    }

    private var forgottenBytes: Int64 {
        if model.analysis.forgottenBytes > 0 { return model.analysis.forgottenBytes }
        return untouched.reduce(Int64(0)) { $0 + (Int($1) < totals.count ? totals[Int($1)] : 0) }
    }

    private var forgottenBuckets: [AgeBucket] {
        [.oneToTwoYears, .overTwoYears].filter { (bucketSizes[$0] ?? 0) > 0 }
    }

    private func size(_ id: Int32) -> Int64 { totals.indices.contains(Int(id)) ? totals[Int(id)] : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isPreparing {
                DiskMapLoadingState(title: "Preparing Age Map", detail: "Grouping modification dates off the main thread.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                heatmap
                    .frame(minHeight: 160, maxHeight: 240)
                SectionHeader(label: "Untouched for over a year",
                              detail: "\(ByteFormat.string(forgottenBytes)) · \(countLabel(filteredUntouched.count, "file"))") {
                    HStack(spacing: 2) {
                        Chip(title: "All", isOn: filterBucket == nil) { filterBucket = nil }
                        ForEach(forgottenBuckets, id: \.self) { bucket in
                            Chip(title: bucket.shortTitle, isOn: filterBucket == bucket) { filterBucket = bucket }
                        }
                    }
                }
                if filteredUntouched.isEmpty {
                    DiskMapEmptyState(symbol: "clock",
                                      title: untouched.isEmpty ? "Nothing untouched for a year" : "Nothing in this age",
                                      message: untouched.isEmpty ? "Every file in this scan was modified in the last year."
                                          : "Pick another age.")
                } else {
                    SelectAllBar(
                        shownCount: filteredUntouched.count, checkedCount: checked.count,
                        checkedBytes: checked.reduce(0) { $0 + size($1) },
                        onSelectAll: { checked = Set(filteredUntouched) },
                        onClear: { checked.removeAll() },
                        leadingInset: 8, trailingInset: 0
                    )
                    candidateList
                    ReviewFooter(
                        checkedCount: checked.count,
                        checkedBytes: checked.reduce(0) { $0 + size($1) },
                        hint: "Tick files to clean, or",
                        quickSelectTitle: "Select all shown",
                        onQuickSelect: { checked = Set(filteredUntouched) },
                        onStage: { Task { await stageSelected() } },
                        onClear: { checked.removeAll() },
                        onReveal: { NSWorkspace.shared.activateFileViewerSelecting(checked.map { tree.path(of: $0, root: rootURL) }) },
                        paths: checked.map { tree.path(of: $0, root: rootURL).path }
                    )
                }
            }
        }
        .task(id: totals.count) { await prepareAgeMap() }
    }

    @MainActor
    private func prepareAgeMap() async {
        guard totals.count == tree.count else {
            bucketSizes = [:]
            untouched = []
            isPreparing = false
            return
        }
        isPreparing = true
        let sourceTree = tree
        let sourceTotals = totals
        let referenceDay = today
        let result = await Task.detached(priority: .utility) {
            let buckets = AgeMap.bucketSizes(in: sourceTree, totals: sourceTotals, today: referenceDay)
            guard !Task.isCancelled else { return ([AgeBucket: Int64](), [Int32]()) }
            let candidates = AgeMap.untouched(in: sourceTree, totals: sourceTotals, today: referenceDay, limit: 200)
            return (buckets, candidates)
        }.value
        guard !Task.isCancelled else { return }
        bucketSizes = result.0
        untouched = result.1
        isPreparing = false
    }

    private var candidateList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredUntouched, id: \.self) { id in
                    candidateRow(id)
                    RowSeparator(indent: 10 + 18 + 10 + 24 + 12)
                }
            }
        }
        .listKeyboard(
            ids: filteredUntouched,
            selection: Binding(get: { filteredUntouched.contains(model.selectedNode) ? model.selectedNode : nil },
                               set: { if let id = $0 { model.selectedNode = id } }),
            path: { tree.path(of: $0, root: rootURL).path },
            stage: { id in stageOne(id) },
            selectAll: { checked = Set(filteredUntouched) },
            clearSelection: { checked.removeAll() }
        )
    }

    private func candidateRow(_ id: Int32) -> some View {
        let abs = tree.path(of: id, root: rootURL).path
        let isOn = checked.contains(id)
        let cloudOnly = tree.flags[Int(id)] & NodeFlags.notDownloaded != 0
        return CheckRow {
            KitCheckbox(isOn: Binding(get: { isOn }, set: { on in
                if on { checked.insert(id) } else { checked.remove(id) }
            }), label: isOn ? "Unmark \(tree.name(of: id))" : "Mark \(tree.name(of: id))")
            Button { model.selectedNode = id } label: {
                KitRow(title: tree.name(of: id), subtitle: relativeParent(of: abs, root: rootURL),
                       selected: model.selectedNode == id, path: abs, onStage: { stageOne(id) }) {
                    FileIdentityIcon(url: URL(fileURLWithPath: abs), size: 24)
                } trailing: {
                    if cloudOnly {
                        Image(systemName: "icloud")
                            .font(.system(size: DiskMapType.scaled(11)))
                            .foregroundStyle(DiskMapTheme.ink3)
                            .help("Not downloaded — revealing may trigger an iCloud download")
                    }
                    MonoColumn(text: RelativeAge.short(day: tree.modifiedDay[Int(id)]), width: 64)
                    MonoColumn(text: ByteFormat.string(size(id)), width: 74, emphasis: true)
                }
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded { showInTreemap(id) })
            .accessibilityLabel("\(tree.name(of: id)), \(ByteFormat.string(size(id))), modified \(RelativeAge.long(day: tree.modifiedDay[Int(id)]))")
            .accessibilityAction(named: "Show in Treemap") { showInTreemap(id) }
            .rowActions(path: abs, stage: { stageOne(id) })
            .contextMenu {
                Button("Show in Treemap") { showInTreemap(id) }
                Button("Show in File Browser") {
                    model.currentNode = max(0, tree.parent[Int(id)])
                    model.selectedNode = id
                    model.destination = .fileBrowser
                }
            }
        }
    }

    /// Age treemap: one tile per age bucket, same tile style as the main treemap.
    private var heatmap: some View {
        Canvas { context, size in
            let items = AgeBucket.allCases.enumerated().compactMap { index, bucket -> (id: Int32, size: Int64)? in
                let bytes = bucketSizes[bucket] ?? 0
                return bytes > 0 ? (Int32(index), bytes) : nil
            }
            let rects = SquarifiedTreemap.layout(items: items, in: CGRect(origin: .zero, size: size))
            for rect in rects {
                let bucket = AgeBucket.allCases[Int(rect.id)]
                let inset = rect.rect.insetBy(dx: 1.5, dy: 1.5)
                let path = Path(roundedRect: inset, cornerRadius: min(6, min(inset.width, inset.height) / 3), style: .continuous)
                context.fill(path, with: .color(DiskMapTheme.ageColor(bucket).opacity(filterBucket == nil || filterBucket == bucket ? 1 : 0.4)))
                if inset.width > 64 && inset.height > 40 {
                    context.draw(
                        Text(bucket.shortTitle).font(.system(size: DiskMapType.scaled(12), weight: .medium))
                            .foregroundStyle(DiskMapTheme.tileLabel.opacity(0.85)),
                        at: CGPoint(x: inset.minX + 8, y: inset.minY + 7), anchor: .topLeading)
                    context.draw(
                        Text(diskByteString(bucketSizes[bucket] ?? 0)).font(DiskMapType.figureSmall)
                            .foregroundStyle(DiskMapTheme.tileLabel.opacity(0.6)),
                        at: CGPoint(x: inset.minX + 8, y: inset.minY + 25), anchor: .topLeading)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage by age: " + AgeBucket.allCases.compactMap { bucket in
            (bucketSizes[bucket] ?? 0) > 0 ? "\(bucket.shortTitle) \(ByteFormat.string(bucketSizes[bucket] ?? 0))" : nil
        }.joined(separator: ", "))
    }

    /// Opens the file's folder in the treemap with the file selected
    /// (it used to switch to Age Map, where it already was).
    private func showInTreemap(_ id: Int32) {
        model.currentNode = max(0, tree.parent[Int(id)])
        model.selectedNode = id
        model.exploreMode = .treemap
    }

    private func stageOne(_ id: Int32) {
        guard id >= 0, Int(id) < totals.count else { return }
        model.stageRow(path: tree.path(of: id, root: rootURL).path, size: totals[Int(id)], reason: "Untouched for over a year")
    }

    private func stageSelected() async {
        let summary = await model.stageForCleanup(checked.compactMap { id in
            guard id >= 0, Int(id) < totals.count else { return nil }
            return CleanupStageRequest(url: tree.path(of: id, root: rootURL), size: totals[Int(id)], reason: "Untouched for over a year")
        })
        model.showToast(summary.added > 0 ? "Added \(countLabel(summary.added, "file")) to Cleanup — ⇧⌘⌫ to review"
                        : summary.alreadyPresent > 0 ? "Already in Cleanup" : "Nothing could be added")
        if summary.added > 0 { checked.removeAll() }
    }
}
