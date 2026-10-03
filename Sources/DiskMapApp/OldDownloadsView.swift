import AppKit
import DiskMapCore
import SwiftUI

/// Clean → Old Downloads: curated review of large/older Downloads files.
struct OldDownloadsView: View {
    @ObservedObject var model: ScanModel
    @Environment(\.diskMapContentWidth) private var contentWidth
    var pickFolder: () -> Void

    @State private var selectedID: Int32?
    @State private var checked: Set<Int32> = []
    @State private var query = ""
    @State private var ageFilter: OldDownloadsAgeFilter = .days30
    @State private var sizeFilter: OldDownloadsSizeFilter = .any
    @State private var typeFilter: OldDownloadsTypeFilter = .all
    @State private var sort: OldDownloadsSort = .largest

    private var catalog: OldDownloadsCatalogResult { model.cachedOldDownloads }
    private var summary: OldDownloadsSummary { catalog.summary }

    private var visible: [OldDownloadsCandidate] {
        let filtered = OldDownloadsCatalog.filter(
            catalog.candidates,
            age: ageFilter,
            size: sizeFilter,
            type: typeFilter,
            query: query
        )
        return OldDownloadsCatalog.sorted(filtered, by: sort)
    }

    private var active: OldDownloadsCandidate? {
        if let selectedID, let hit = visible.first(where: { $0.nodeID == selectedID })
            ?? catalog.candidates.first(where: { $0.nodeID == selectedID }) {
            return hit
        }
        return visible.first
    }

    private var checkedItems: [OldDownloadsCandidate] {
        catalog.candidates.filter { checked.contains($0.nodeID) }
    }

    private var checkedBytes: Int64 {
        checkedItems.reduce(Int64(0)) { $0 + $1.bytes }
    }

    private var thresholdItems: [OldDownloadsCandidate] {
        OldDownloadsCatalog.filter(catalog.candidates, age: ageFilter, size: .any, type: .all, query: "")
    }

    private var shown: [OldDownloadsCandidate] { Array(visible.prefix(200)) }

    var body: some View {
        Group {
            if model.tree == nil {
                DiskMapEmptyState(symbol: "arrow.down.circle", title: "Scan to find older downloads",
                                  message: "DiskMap looks through Downloads after a scan.",
                                  primaryTitle: "Choose Folder…", primaryAction: pickFolder)
            } else {
                AdaptiveInspectorSplit(windowWidth: contentWidth, inspectionToken: selectedID.map(String.init), main: mainColumn, inspector: inspector)
            }
        }
        .background(DiskMapTheme.canvas)
        .catalogGate(.oldDownloads, model: model, title: "Looking through Downloads…")
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(eyebrow: "Clean", title: "Old Downloads",
                           subtitle: "Large or older files in Downloads you may no longer need. Age is the last-modified date.") {
                    Button("Reveal Downloads", action: revealDownloads)
                        .buttonStyle(QuietButtonStyle())
                }
                FigureStrip(figures: [
                    Figure(label: "In Downloads", value: ByteFormat.string(summary.totalBytes), detail: countLabel(summary.totalCount, "file")),
                    Figure(label: ageFilter == .all ? "Any age" : "Older than \(ageFilter.title.replacingOccurrences(of: "+", with: ""))",
                           value: ByteFormat.string(thresholdItems.reduce(0) { $0 + $1.bytes }),
                           detail: countLabel(thresholdItems.count, "file")),
                ])
                .frame(maxWidth: 520, alignment: .leading)
                filterBar
            }
            .padding(.horizontal, 28)
            .padding(.top, DiskMapSpace.pageTop)
            .padding(.bottom, 12)
            Hairline()
            if visible.isEmpty {
                DiskMapEmptyState(
                    symbol: "arrow.down.circle",
                    title: catalog.candidates.isEmpty ? "Nothing old enough to review" : "No files match these filters",
                    message: catalog.candidates.isEmpty ? "Downloads has nothing matching this view. That’s a good thing."
                        : "Try another age, size or type."
                )
            } else {
                list
            }
            ReviewFooter(
                checkedCount: checkedItems.count, checkedBytes: checkedBytes,
                hint: visible.count > shown.count ? "Showing the largest 200 of \(visible.count.formatted()). Tick files to clean, or"
                    : "Tick files to clean, or",
                quickSelectTitle: "Select all shown",
                onQuickSelect: { checked = Set(shown.map(\.nodeID)) },
                onStage: { Task { await stage(checkedItems) } },
                onClear: { checked.removeAll() },
                onReveal: { NSWorkspace.shared.activateFileViewerSelecting(checkedItems.map { URL(fileURLWithPath: $0.absolutePath) }) },
                paths: checkedItems.map(\.absolutePath)
            )
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                DiskMapSearchField(placeholder: "Search Downloads", text: $query)
                    .frame(maxWidth: 300)
                Spacer(minLength: 8)
                DiskMapMenu(label: "Size", options: OldDownloadsSizeFilter.allCases, selection: $sizeFilter, title: { $0.title })
                DiskMapMenu(label: "Sort", options: OldDownloadsSort.allCases, selection: $sort, title: { $0.title })
            }
            HStack(spacing: DiskMapSpace.md) {
                HStack(spacing: 2) {
                    ForEach(OldDownloadsAgeFilter.allCases) { age in
                        Chip(title: age.title, isOn: ageFilter == age) { ageFilter = age }
                            .help("Modified more than \(age.title.replacingOccurrences(of: "+", with: "")) ago")
                    }
                }
                Rectangle().fill(DiskMapTheme.line).frame(width: 1, height: 16)
                HStack(spacing: 2) {
                    ForEach(OldDownloadsTypeFilter.allCases) { type in
                        let count = OldDownloadsCatalog.filter(catalog.candidates, age: ageFilter, size: sizeFilter, type: type, query: "").count
                        if type == .all || count > 0 {
                            Chip(title: type.title, count: "\(count)", isOn: typeFilter == type) { typeFilter = type }
                        }
                    }
                }
            }
        }
    }

    private var list: some View {
        // Worked out once per draw, not once per row.
        let items = shown
        let activeID = active?.nodeID
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    row(item, activeID: activeID)
                    RowSeparator(indent: 10 + 18 + 10 + 24 + 12)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 4)
        }
        .listKeyboard(
            ids: items.map(\.nodeID), selection: $selectedID,
            path: { id in visible.first { $0.nodeID == id }?.absolutePath },
            stage: { id in
                if let item = visible.first(where: { $0.nodeID == id }) { Task { await stage([item]) } }
            },
            selectAll: { checked = Set(items.map(\.nodeID)) },
            clearSelection: { checked.removeAll() }
        )
        .onChange(of: selectedID) { _, id in if let id { model.selectedNode = id } }
    }

    private func row(_ item: OldDownloadsCandidate, activeID: Int32?) -> some View {
        let isChecked = checked.contains(item.nodeID)
        let stageItem = { Task { await stage([item]) } }
        return CheckRow {
            KitCheckbox(isOn: Binding(get: { isChecked }, set: { on in
                if on { checked.insert(item.nodeID) } else { checked.remove(item.nodeID) }
            }), label: isChecked ? "Unmark \(item.name)" : "Mark \(item.name)")
            Button { selectedID = item.nodeID } label: {
                KitRow(title: item.name, subtitle: model.rootURL.map { relativeParent(of: item.absolutePath, root: $0) } ?? parentDisplay(item.displayPath),
                       selected: item.nodeID == activeID, path: item.absolutePath, onStage: { _ = stageItem() }) {
                    FileIdentityIcon(url: URL(fileURLWithPath: item.absolutePath), kind: item.kind, size: 24)
                } trailing: {
                    SafetyLabel(level: item.status == .reviewFirst ? .review : .safe)
                        .frame(width: DiskMapType.scaled(96), alignment: .leading)
                    TextColumn(text: item.kind.title, width: 80)
                    MonoColumn(text: RelativeAge.short(ageDays: item.ageDays), width: 64)
                    MonoColumn(text: ByteFormat.string(item.bytes), width: 74, emphasis: true)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.name), \(ByteFormat.string(item.bytes)), \(OldDownloadsCatalog.ageLabel(item.ageDays))")
            .rowActions(path: item.absolutePath, stage: { _ = stageItem() })
        }
    }

    private var inspector: some View {
        Group {
            if let item = active, let tree = model.tree, let root = model.rootURL {
                FileInspector(model: model, tree: tree, rootURL: root, id: item.nodeID, size: item.bytes,
                              reason: "Old Downloads: \(item.name)",
                              note: (label: "Why it’s here", text: item.whyHere))
            } else {
                DiskMapEmptyState(symbol: "arrow.down.circle", title: "Select a file",
                                  message: "See why it’s here and what you can do.")
            }
        }
        .background(DiskMapTheme.canvas)
    }

    private func parentDisplay(_ path: String) -> String {
        if let slash = path.lastIndex(of: "/") {
            return String(path[...slash])
        }
        return path
    }

    private func typeFilterFor(_ kind: FileKind) -> OldDownloadsTypeFilter {
        switch kind {
        case .video: return .video
        case .archive: return .archive
        case .diskImage: return .installer
        case .document: return .document
        default: return .other
        }
    }

    private func reveal(_ item: OldDownloadsCandidate) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.absolutePath)])
    }

    private func revealDownloads() {
        let home = NSHomeDirectory() + "/Downloads"
        NSWorkspace.shared.open(URL(fileURLWithPath: home, isDirectory: true))
    }

    private func stage(_ items: [OldDownloadsCandidate]) async {
        let result = await model.stageForCleanup(items.map {
            CleanupStageRequest(
                url: URL(fileURLWithPath: $0.absolutePath),
                size: $0.bytes,
                reason: "Old Downloads: \($0.name)"
            )
        })
        let rejected = Set(result.rejectedURLs.map(\.path))
        checked = Set(items.filter { rejected.contains($0.absolutePath) }.map(\.nodeID))
        model.showToast(result.added > 0 ? "Added \(countLabel(result.added, "file")) to Cleanup — ⇧⌘⌫ to review"
                        : result.alreadyPresent > 0 ? "Already in Cleanup" : "Nothing new added")
    }
}
