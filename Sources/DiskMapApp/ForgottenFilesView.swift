import AppKit
import DiskMapCore
import SwiftUI

/// Find → Forgotten Files. Uses ScanModel.cachedForgotten (computed once per scan).
struct ForgottenFilesView: View {
    @ObservedObject var model: ScanModel
    @Environment(\.diskMapContentWidth) private var contentWidth
    let tree: FileTree
    let rootURL: URL
    var onOpenCleanup: () -> Void = {}

    enum FilterTab: String, CaseIterable, Identifiable {
        case all, likely, worth, excluded
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .likely: return "Likely forgotten"
            case .worth: return "Worth reviewing"
            case .excluded: return "Excluded"
            }
        }
    }

    enum SortMode: String, CaseIterable, Identifiable {
        case reviewValue, largest, oldest, name
        var id: String { rawValue }
        var title: String {
            switch self {
            case .reviewValue: return "Most relevant"
            case .largest: return "Largest"
            case .oldest: return "Oldest"
            case .name: return "Name"
            }
        }
    }

    @State private var query = ""
    @State private var filterTab: FilterTab = .all
    @State private var sortMode: SortMode = .reviewValue
    @State private var selectedID: Int32?
    @State private var ageFilter: ForgottenAgeBucket?
    @State private var onlyLarge = false
    @State private var onlyDownloads = false
    @State private var onlyMedia = false

    private var allCandidates: [ForgottenCandidate] { model.cachedForgotten }
    private var summary: ForgottenSummary { model.cachedForgottenSummary }

    private var visible: [ForgottenCandidate] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var list = allCandidates.filter { c in
            switch filterTab {
            case .all: return c.isReviewable
            case .likely: return c.confidence == .likelyForgotten
            case .worth: return c.confidence == .worthReviewing
            case .excluded: return c.confidence == .oldImportant
            }
        }
        if let ageFilter {
            list = list.filter { ForgottenAgeBucket.bucket(ageDays: $0.ageDays) == ageFilter }
        }
        if onlyLarge { list = list.filter { $0.bytes >= 1_000_000_000 } }
        if onlyDownloads { list = list.filter { $0.absolutePath.lowercased().contains("/downloads/") } }
        if onlyMedia {
            list = list.filter { [.video, .diskImage, .archive, .deviceBackup].contains($0.kind) }
        }
        if !q.isEmpty {
            list = list.filter {
                $0.name.lowercased().contains(q)
                    || $0.displayPath.lowercased().contains(q)
                    || $0.parentDisplay.lowercased().contains(q)
            }
        }
        switch sortMode {
        case .reviewValue: list.sort { $0.score > $1.score }
        case .largest: list.sort { $0.bytes > $1.bytes }
        case .oldest: list.sort { $0.ageDays > $1.ageDays }
        case .name: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return list
    }

    private var active: ForgottenCandidate? {
        if let selectedID, let hit = visible.first(where: { $0.id == selectedID }) { return hit }
        if let selectedID, let hit = allCandidates.first(where: { $0.id == selectedID }) { return hit }
        return visible.first
    }

    /// ⌘-selected rows that may be staged: excluded (app-managed) files never are.
    private var checkedReviewable: [ForgottenCandidate] {
        visible.filter { model.multiSelection.contains($0.id) && $0.isReviewable && $0.safety.level != .protected }
    }

    var body: some View {
        AdaptiveInspectorSplit(windowWidth: contentWidth, inspectionToken: selectedID.map(String.init), main: mainColumn, inspector: inspectorColumn)
        .background(DiskMapTheme.canvas)
        .catalogGate(.forgotten, model: model, title: "Finding forgotten files…")
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(eyebrow: "Find", title: "Forgotten Files",
                           subtitle: "Personal files untouched for a year or more, by last-modified date. App and system data is left out.")
                FigureStrip(figures: [
                    Figure(label: "Reviewable", value: ByteFormat.string(summary.reviewableBytes), detail: countLabel(summary.reviewableCount, "file")),
                    Figure(label: "Likely forgotten", value: ByteFormat.string(summary.likelyBytes), detail: countLabel(summary.likelyCount, "file")),
                    Figure(label: "Worth reviewing", value: ByteFormat.string(summary.worthBytes), detail: countLabel(summary.worthCount, "file")),
                ])
                ageBar
                KitTabs(tabs: [
                    .init(id: FilterTab.all, title: "All", count: "\(summary.reviewableCount)"),
                    .init(id: .likely, title: "Likely forgotten", count: "\(summary.likelyCount)"),
                    .init(id: .worth, title: "Worth reviewing", count: "\(summary.worthCount)"),
                    .init(id: .excluded, title: "Excluded", count: "\(summary.excludedCount)"),
                ], selection: $filterTab)
                filterBar
            }
            .padding(.horizontal, 28)
            .padding(.top, DiskMapSpace.pageTop)
            .padding(.bottom, 12)
            Hairline()
            if visible.isEmpty {
                emptyState
            } else {
                list
            }
            if model.multiSelection.count > 1 {
                SelectionToolbar(
                    selectedCount: checkedReviewable.count,
                    selectedBytes: checkedReviewable.reduce(0) { $0 + $1.bytes },
                    primaryEnabled: !checkedReviewable.isEmpty,
                    onPrimary: { Task { await stageSelected() } },
                    onClear: { model.clearMultiSelection() },
                    onReveal: {
                        NSWorkspace.shared.activateFileViewerSelecting(checkedReviewable.map { URL(fileURLWithPath: $0.absolutePath) })
                    },
                    paths: checkedReviewable.map(\.absolutePath)
                )
            }
        }
    }

    static func ageTint(_ bucket: ForgottenAgeBucket) -> Color {
        switch bucket {
        case .oneToTwoYears: return DiskMapTheme.hex("B9A071")
        case .twoToThreeYears: return DiskMapTheme.hex("C99A7E")
        case .threeToFiveYears: return DiskMapTheme.hex("C78797")
        case .overFiveYears: return DiskMapTheme.hex("A795C7")
        }
    }

    /// One stacked bar by age; the legend entries filter.
    private var ageBar: some View {
        let dist = summary.ageDistribution
        let total = max(1, ForgottenAgeBucket.allCases.reduce(Int64(0)) { $0 + (dist[$1] ?? 0) })
        return VStack(alignment: .leading, spacing: 10) {
            SegmentedStorageBar(segments: ForgottenAgeBucket.allCases.map { bucket in
                (Self.ageTint(bucket).opacity(ageFilter == nil || ageFilter == bucket ? 1 : 0.3),
                 Double(dist[bucket] ?? 0) / Double(total))
            })
            .accessibilityHidden(true)
            HStack(spacing: 16) {
                ForEach(ForgottenAgeBucket.allCases) { bucket in
                    let bytes = dist[bucket] ?? 0
                    if bytes > 0 {
                        let on = ageFilter == bucket
                        Button { ageFilter = on ? nil : bucket } label: {
                            HStack(spacing: 6) {
                                Circle().fill(Self.ageTint(bucket)).frame(width: 7, height: 7)
                                Text(bucket.title)
                                    .font(on ? DiskMapType.bodyEmphasis : DiskMapType.secondary)
                                    .foregroundStyle(on ? DiskMapTheme.ink : DiskMapTheme.ink2)
                                Text(ByteFormat.string(bytes))
                                    .font(DiskMapType.figureSmall)
                                    .foregroundStyle(DiskMapTheme.ink3)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(bucket.title), \(ByteFormat.string(bytes))")
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                Spacer(minLength: 0)
                if ageFilter != nil {
                    Button("Clear age") { ageFilter = nil }
                        .buttonStyle(LinkButtonStyle())
                        .font(DiskMapType.secondary)
                }
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            DiskMapSearchField(placeholder: "Search forgotten files", text: $query)
                .frame(maxWidth: 300)
            HStack(spacing: 2) {
                Chip(title: "Over 1 GB", isOn: onlyLarge) { onlyLarge.toggle() }
                Chip(title: "Downloads", isOn: onlyDownloads) { onlyDownloads.toggle() }
                Chip(title: "Media", isOn: onlyMedia) { onlyMedia.toggle() }
            }
            Spacer(minLength: 8)
            DiskMapMenu(label: "Sort", options: SortMode.allCases, selection: $sortMode, title: { $0.title })
        }
    }

    private var list: some View {
        let ids = visible.map(\.id)
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(visible) { c in
                    row(c, ordered: ids)
                    RowSeparator(indent: 10 + 14 + 12 + 24 + 12)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 4)
        }
        .listKeyboard(
            ids: ids, selection: $selectedID,
            path: { id in visible.first { $0.id == id }?.absolutePath },
            stage: { id in
                if let candidate = visible.first(where: { $0.id == id }) { stageOne(candidate) }
            },
            selectAll: { model.multiSelection = Set(ids) },
            clearSelection: { model.clearMultiSelection() }
        )
        .onChange(of: selectedID) { _, id in if let id { model.selectedNode = id } }
    }

    private func row(_ c: ForgottenCandidate, ordered: [Int32]) -> some View {
        let inMulti = model.multiSelection.contains(c.id)
        let stageable = c.isReviewable && c.safety.level != .protected
        return Button {
            selectedID = c.id
            model.select(c.id, ordered: ordered)
        } label: {
            KitRow(title: c.name, subtitle: relativeParent(of: c.absolutePath, root: rootURL),
                   selected: c.id == active?.id || inMulti, path: c.absolutePath,
                   onStage: stageable ? { stageOne(c) } : nil) {
                MultiSelectMark(on: inMulti)
                FileIdentityIcon(url: URL(fileURLWithPath: c.absolutePath), kind: c.kind, size: 24)
            } trailing: {
                SafetyLabel(level: nil, title: Self.confidenceLabel(c.confidence), tint: Self.confidenceTint(c.confidence))
                    .frame(width: 128, alignment: .leading)
                    .help(c.confidence == .oldImportant
                          ? "Excluded from recommendations because this appears to be app-managed or important data."
                          : c.confidence.title)
                MonoColumn(text: ForgottenAgeFormat.short(c.ageDays), width: 74)
                MonoColumn(text: ByteFormat.string(c.bytes), width: 74, emphasis: true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(c.name), \(ByteFormat.string(c.bytes)), \(ForgottenAgeFormat.string(c.ageDays)), \(Self.confidenceLabel(c.confidence))")
        .rowActions(path: c.absolutePath, stage: stageable ? { stageOne(c) } : nil)
    }

    static func confidenceLabel(_ confidence: ForgottenConfidence) -> String {
        switch confidence {
        case .likelyForgotten: return "Likely forgotten"
        case .worthReviewing: return "Worth reviewing"
        case .oldImportant: return "Excluded"
        }
    }

    static func confidenceTint(_ confidence: ForgottenConfidence) -> Color {
        switch confidence {
        case .likelyForgotten: return DiskMapTheme.safe
        case .worthReviewing: return DiskMapTheme.review
        case .oldImportant: return DiskMapTheme.ink3
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if summary.excludedCount > 0 && summary.reviewableCount == 0 && filterTab != .excluded {
            VStack(spacing: 12) {
                DiskMapEmptyState(symbol: "clock", title: "Nothing worth reviewing yet",
                                  message: "Old files were found, but they belong to apps, package managers or macOS, so they aren’t suggested here.")
                    .frame(maxHeight: 200)
                Button("Show excluded") { filterTab = .excluded }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            DiskMapEmptyState(symbol: "clock",
                              title: filterTab == .excluded ? "No excluded old files" : "No forgotten files found",
                              message: "Try another filter, or clear the search.")
        }
    }

    private var inspectorColumn: some View {
        Group {
            if let c = active {
                FileInspector(
                    model: model, tree: tree, rootURL: rootURL, id: c.id, size: c.bytes,
                    reason: "Forgotten: " + c.confidence.title,
                    extraFacts: [("Recommendation", c.confidence.title)],
                    note: (label: "Why it was flagged", text: c.reasons.joined(separator: " · ")),
                    allowStage: c.isReviewable
                )
            } else {
                DiskMapEmptyState(symbol: "clock", title: "Select a file", message: "Its details and actions appear here.")
            }
        }
        .background(DiskMapTheme.canvas)
    }

    private func stageSelected() async {
        let items = checkedReviewable
        let summary = await model.stageForCleanup(items.map {
            CleanupStageRequest(url: URL(fileURLWithPath: $0.absolutePath).standardizedFileURL, size: $0.bytes,
                                reason: "Forgotten: " + $0.confidence.title)
        })
        model.showToast(summary.added > 0 ? "Added \(summary.added) to Cleanup — ⇧⌘⌫ to review"
                        : summary.alreadyPresent > 0 ? "Already in Cleanup" : "Nothing could be added")
        if summary.added > 0 { model.clearMultiSelection() }
    }

    private func stageOne(_ c: ForgottenCandidate) {
        guard c.isReviewable, c.safety.level != .protected else {
            model.showToast("Not recommended for cleanup")
            return
        }
        model.stageRow(path: c.absolutePath, size: c.bytes, reason: "Forgotten: " + c.confidence.title)
    }
}

enum ForgottenAgeFormat {
    /// For list columns: "8 mo", "3 y", "Very old".
    static func short(_ ageDays: Int32) -> String {
        if ageDays >= 15 * 365 { return "Very old" }
        if ageDays < 365 { return "\(max(1, ageDays / 30)) mo" }
        return "\(ageDays / 365) y"
    }

    static func string(_ ageDays: Int32) -> String {
        // Packaging mtimes (cargo/npm sources) can look absurdly old — keep honest but compact.
        if ageDays >= 15 * 365 { return "Very old" }
        if ageDays < 60 { return "\(ageDays)d ago" }
        if ageDays < 365 {
            let m = max(1, ageDays / 30)
            return m == 1 ? "1 month ago" : "\(m) months ago"
        }
        let y = max(1, ageDays / 365)
        return y == 1 ? "1 year ago" : "\(y) years ago"
    }
}

