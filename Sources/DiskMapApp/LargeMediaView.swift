import AppKit
import DiskMapCore
import SwiftUI

/// Clean → Large Media: media-storage intelligence workspace (not Biggest Files).
struct LargeMediaView: View {
    @ObservedObject var model: ScanModel
    @Environment(\.diskMapContentWidth) private var contentWidth
    var pickFolder: () -> Void

    @State private var selectedID: Int32?
    @State private var checked: Set<Int32> = []
    @State private var query = ""
    @State private var typeFilter: MediaTypeFilter = .all
    @State private var sizeFilter: MediaSizeFilter = .any
    @State private var ageFilter: MediaAgeFilter = .all
    @State private var locationFilter: MediaLocationFilter = .any
    @State private var sort: MediaSort = .largest

    private var catalog: MediaCatalogResult { model.cachedLargeMedia }
    private var summary: MediaSummary { catalog.summary }

    private var visible: [MediaCandidate] {
        let filtered = MediaCatalog.filter(
            catalog.candidates,
            type: typeFilter,
            size: sizeFilter,
            age: ageFilter,
            location: locationFilter,
            query: query
        )
        return MediaCatalog.sorted(filtered, by: sort)
    }

    private var active: MediaCandidate? {
        if let selectedID,
           let hit = visible.first(where: { $0.nodeID == selectedID })
            ?? catalog.candidates.first(where: { $0.nodeID == selectedID }) {
            return hit
        }
        return visible.first
    }

    private var checkedItems: [MediaCandidate] {
        catalog.candidates.filter { checked.contains($0.nodeID) }
    }

    private var checkedBytes: Int64 {
        checkedItems.reduce(Int64(0)) { $0 + $1.bytes }
    }

    private var shown: [MediaCandidate] { Array(visible.prefix(300)) }

    private var filtersAreDefault: Bool {
        query.isEmpty && typeFilter == .all && sizeFilter == .any && ageFilter == .all && locationFilter == .any
    }

    var body: some View {
        Group {
            if model.tree == nil {
                DiskMapEmptyState(symbol: "film", title: "Scan to find large media",
                                  message: "Videos, photos, audio and media projects, after a scan.",
                                  primaryTitle: "Choose Folder…", primaryAction: pickFolder)
            } else {
                AdaptiveInspectorSplit(windowWidth: contentWidth, inspectionToken: selectedID.map(String.init), main: mainColumn, inspector: inspector)
            }
        }
        .background(DiskMapTheme.canvas)
        .catalogGate(.largeMedia, model: model, title: "Finding large media…")
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(eyebrow: "Clean", title: "Large Media",
                           subtitle: "The videos, photos, audio and media projects using the most space.") {
                    HeaderSummary(parts: catalog.isTruncated
                                  ? ["largest " + countLabel(summary.totalCount, "file"), ByteFormat.string(summary.totalBytes)]
                                  : [ByteFormat.string(summary.totalBytes), countLabel(summary.totalCount, "file")])
                }
                if filtersAreDefault && sort == .largest && !catalog.opportunities.isEmpty {
                    thumbnailStrip
                }
                filterBar
            }
            .padding(.horizontal, 28)
            .padding(.top, DiskMapSpace.pageTop)
            .padding(.bottom, 12)
            Hairline()
            if visible.isEmpty {
                VStack(spacing: 12) {
                    DiskMapEmptyState(symbol: "film",
                                      title: catalog.candidates.isEmpty ? "No large media found" : "No media matches these filters",
                                      message: catalog.candidates.isEmpty ? "Nothing in this scan is above the size threshold."
                                          : "Clear the filters or broaden the search.")
                        .frame(maxHeight: 220)
                    if !catalog.candidates.isEmpty {
                        Button("Clear filters", action: clearFilters).buttonStyle(SecondaryButtonStyle())
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
            ReviewFooter(
                checkedCount: checkedItems.count, checkedBytes: checkedBytes,
                hint: visible.count > shown.count ? "Showing 300 of \(visible.count.formatted()) — narrow the filters. Tick files, or"
                    : "\(countLabel(visible.count, "file")) · \(ByteFormat.string(visible.reduce(0) { $0 + $1.bytes })). Tick files, or",
                quickSelectTitle: "Select all shown",
                onQuickSelect: { checked = Set(shown.map(\.nodeID)) },
                onStage: { Task { await stage(checkedItems) } },
                onClear: { checked.removeAll() },
                onReveal: { NSWorkspace.shared.activateFileViewerSelecting(checkedItems.map { URL(fileURLWithPath: $0.absolutePath) }) },
                paths: checkedItems.map(\.absolutePath)
            )
        }
    }

    /// The page's one visual: the largest media as thumbnails.
    private var thumbnailStrip: some View {
        let activeID = active?.nodeID
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(catalog.opportunities.prefix(6)) { item in
                    Button { selectedID = item.nodeID } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            MediaThumbnailView(
                                url: URL(fileURLWithPath: item.absolutePath),
                                size: CGSize(width: 140, height: 80),
                                fallbackSymbol: item.kind.symbolName,
                                showPlayBadge: item.kind == .video,
                                fallsBackToFileIcon: false
                            )
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(item.nodeID == activeID ? DiskMapTheme.accent : DiskMapTheme.line,
                                        lineWidth: item.nodeID == activeID ? 2 : 1))
                            Text(item.name)
                                .font(DiskMapType.secondary)
                                .foregroundStyle(DiskMapTheme.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 140, alignment: .leading)
                            Text(ByteFormat.string(item.bytes))
                                .font(DiskMapType.figureSmall)
                                .foregroundStyle(DiskMapTheme.ink2)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.name), \(ByteFormat.string(item.bytes))")
                }
            }
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                DiskMapSearchField(placeholder: "Search media", text: $query)
                    .frame(maxWidth: 260)
                Spacer(minLength: 8)
                DiskMapMenu(label: "Where", options: MediaLocationFilter.allCases, selection: $locationFilter, title: { $0.title })
                DiskMapMenu(label: "Age", options: MediaAgeFilter.allCases, selection: $ageFilter, title: { $0.title })
                DiskMapMenu(label: "Size", options: MediaSizeFilter.allCases, selection: $sizeFilter, title: { $0.title })
                DiskMapMenu(label: "Sort", options: MediaSort.allCases, selection: $sort, title: { $0.title })
            }
            FlowLayout(spacing: 2) {
                ForEach(MediaTypeFilter.allCases) { type in
                    let count = MediaCatalog.filter(catalog.candidates, type: type, size: sizeFilter, age: ageFilter,
                                                    location: locationFilter, query: "").count
                    if type == .all || count > 0 {
                        Chip(title: type.title, count: "\(count)", isOn: typeFilter == type) { typeFilter = type }
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
                    RowSeparator(indent: 10 + 18 + 10 + 32 + 12)
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

    private func row(_ item: MediaCandidate, activeID: Int32?) -> some View {
        let isChecked = checked.contains(item.nodeID)
        let stageItem: () -> Void = { Task { await stage([item]) } }
        return CheckRow {
            KitCheckbox(isOn: Binding(get: { isChecked }, set: { on in
                if on { checked.insert(item.nodeID) } else { checked.remove(item.nodeID) }
            }), label: isChecked ? "Unmark \(item.name)" : "Mark \(item.name)")
            Button { selectedID = item.nodeID } label: {
                KitRow(title: item.name, subtitle: model.rootURL.map { relativeParent(of: item.absolutePath, root: $0) } ?? parentDisplay(item.displayPath),
                       selected: item.nodeID == activeID, path: item.absolutePath, onStage: stageItem) {
                    MediaThumbnailView(
                        url: URL(fileURLWithPath: item.absolutePath),
                        size: CGSize(width: 32, height: 22),
                        fallbackSymbol: item.kind.symbolName,
                        showPlayBadge: false,
                        fallsBackToFileIcon: false
                    )
                } trailing: {
                    TextColumn(text: item.location.title, width: 84)
                    MonoColumn(text: RelativeAge.short(ageDays: item.ageDays), width: 56)
                    MonoColumn(text: ByteFormat.string(item.bytes), width: 74, emphasis: true)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.name), \(ByteFormat.string(item.bytes)), \(item.kind.shortTitle)")
            .rowActions(path: item.absolutePath, stage: stageItem)
        }
    }

    private var inspector: some View {
        Group {
            if let item = active, let tree = model.tree, let root = model.rootURL {
                FileInspector(
                    model: model, tree: tree, rootURL: root, id: item.nodeID, size: item.bytes,
                    reason: "Large media: \(item.kind.shortTitle)",
                    extraFacts: [item.durationLabel.map { ("Duration", $0) }, item.dimensionsLabel.map { ("Dimensions", $0) }].compactMap { $0 },
                    note: (label: "Why it’s here", text: item.whyHere),
                    preview: AnyView(
                        MediaThumbnailView(
                            url: URL(fileURLWithPath: item.absolutePath),
                            size: CGSize(width: 260, height: 146),
                            fallbackSymbol: item.kind.symbolName,
                            showPlayBadge: item.kind == .video,
                            fallsBackToFileIcon: false
                        )
                    )
                )
            } else {
                DiskMapEmptyState(symbol: "film", title: "Select a file", message: "Its preview, details and actions appear here.")
            }
        }
        .background(DiskMapTheme.canvas)
    }

    private func clearFilters() {
        query = ""
        typeFilter = .all
        sizeFilter = .any
        ageFilter = .all
        locationFilter = .any
    }

    private func parentDisplay(_ path: String) -> String {
        if let slash = path.lastIndex(of: "/") {
            return String(path[...slash])
        }
        return path
    }

    private func stage(_ items: [MediaCandidate]) async {
        let result = await model.stageForCleanup(items.map {
            CleanupStageRequest(
                url: URL(fileURLWithPath: $0.absolutePath),
                size: $0.bytes,
                reason: "Large media: \($0.kind.shortTitle)"
            )
        })
        let rejected = Set(result.rejectedURLs.map(\.path))
        checked = Set(items.filter { rejected.contains($0.absolutePath) }.map(\.nodeID))
        model.showToast(result.added > 0 ? "Added \(countLabel(result.added, "file")) to Cleanup — ⇧⌘⌫ to review"
                        : result.alreadyPresent > 0 ? "Already in Cleanup" : "Nothing new added")
    }

}
