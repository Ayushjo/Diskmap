import AppKit
import DiskMapCore
import SwiftUI

/// Clean → Caches: cache folders grouped by the app that owns them.
struct CachesReviewView: View {
    @ObservedObject var model: ScanModel
    @Environment(\.diskMapContentWidth) private var contentWidth

    enum Filter: String, CaseIterable, Identifiable {
        case all, safe, review
        var id: String { rawValue }
    }

    enum SortMode: String, CaseIterable, Identifiable {
        case largest, name
        var id: String { rawValue }
        var title: String { self == .largest ? "Largest" : "Name" }
    }

    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var sortMode: SortMode = .largest
    @State private var checked: Set<String> = []
    @State private var selectedID: String?

    private var caches: [ReviewableTarget] {
        model.cachedReviewables.filter { $0.category == .caches }.sorted { $0.bytes > $1.bytes }
    }

    private var totalBytes: Int64 { caches.reduce(0) { $0 + $1.bytes } }

    private var visible: [ReviewableTarget] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var list = caches
        switch filter {
        case .all: break
        case .safe: list = list.filter(\.isGenerallySafe)
        case .review: list = list.filter(\.isReviewFirst)
        }
        if !q.isEmpty {
            list = list.filter {
                $0.displayName.lowercased().contains(q)
                    || $0.detail.lowercased().contains(q)
                    || $0.primaryPath.lowercased().contains(q)
            }
        }
        if sortMode == .name {
            list.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
        return list
    }

    private var active: ReviewableTarget? {
        if let selectedID, let hit = visible.first(where: { $0.id == selectedID }) { return hit }
        return visible.first
    }

    private var checkedTargets: [ReviewableTarget] { visible.filter { checked.contains($0.id) } }

    var body: some View {
        AdaptiveInspectorSplit(windowWidth: contentWidth, inspectionToken: selectedID, main: mainColumn, inspector: inspector)
        .background(DiskMapTheme.canvas)
        .catalogGate(.reviewables, model: model, title: "Finding caches…")
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(eyebrow: "Clean", title: "Caches",
                           subtitle: "Temporary app data. Clearing it won’t touch your documents; apps rebuild it, sometimes slower the first time.") {
                    HeaderSummary(parts: [ByteFormat.string(totalBytes), countLabel(caches.count, "app")])
                }
                SegmentedStorageBar(segments: caches.prefix(6).enumerated().map { index, t in
                    (DiskMapTheme.data(index), Double(t.bytes) / Double(max(1, totalBytes)))
                } + [(DiskMapTheme.data(6), Double(caches.dropFirst(6).reduce(0) { $0 + $1.bytes }) / Double(max(1, totalBytes)))])
                .accessibilityHidden(true)
                KitTabs(tabs: [
                    .init(id: Filter.all, title: "All", count: "\(caches.count)"),
                    .init(id: .safe, title: "Safe to clear", count: "\(caches.filter(\.isGenerallySafe).count)"),
                    .init(id: .review, title: "Review first", count: "\(caches.filter(\.isReviewFirst).count)"),
                ], selection: $filter)
                HStack(spacing: 10) {
                    DiskMapSearchField(placeholder: "Search apps", text: $query)
                        .frame(maxWidth: 300)
                    Spacer(minLength: 8)
                    DiskMapMenu(label: "Sort", options: SortMode.allCases, selection: $sortMode, title: { $0.title })
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, DiskMapSpace.pageTop)
            .padding(.bottom, 12)
            Hairline()
            if visible.isEmpty {
                DiskMapEmptyState(symbol: "internaldrive", title: caches.isEmpty ? "No caches found" : "Nothing matches",
                                  message: caches.isEmpty ? "This scan didn’t include Library/Caches, or the caches are empty."
                                      : "Try another tab, or clear the search.",
                                  dusty: caches.isEmpty ? .proud : nil)
            } else {
                SelectAllBar(
                    shownCount: visible.filter { !$0.isProtected }.count,
                    checkedCount: checkedTargets.count,
                    checkedBytes: checkedTargets.reduce(0) { $0 + $1.bytes },
                    onSelectAll: { checked = Set(visible.filter { !$0.isProtected }.map(\.id)) },
                    onClear: { checked.removeAll() },
                    quickTitle: "Select generally safe",
                    quickEnabled: visible.contains(where: \.isGenerallySafe),
                    onQuick: { checked = Set(visible.filter(\.isGenerallySafe).map(\.id)) }
                )
                list
            }
            ReviewSelectionFooter(
                checkedTargets: checkedTargets,
                hint: "Tick apps to clear, or",
                quickSelectTitle: "Select all generally safe",
                quickSelectEnabled: visible.contains(where: \.isGenerallySafe),
                onQuickSelect: { checked = Set(visible.filter(\.isGenerallySafe).map(\.id)) },
                onStage: { Task { await stage(checkedTargets) } },
                onClear: { checked.removeAll() }
            )
        }
    }

    private var list: some View {
        // Worked out once per draw, not once per row.
        let items = visible
        let activeID = active?.id
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { t in
                    ReviewTargetRow(
                        target: t, subtitle: t.detail,
                        checked: checked.contains(t.id), selected: t.id == activeID,
                        onToggle: { if checked.contains(t.id) { checked.remove(t.id) } else { checked.insert(t.id) } },
                        onSelect: { selectedID = t.id },
                        onStage: t.isProtected ? nil : { Task { await stage([t]) } }
                    )
                    RowSeparator(indent: 10 + 18 + 10 + 24 + 12)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 4)
        }
        .listKeyboard(
            ids: items.map(\.id), selection: $selectedID,
            path: { id in items.first { $0.id == id }?.primaryPath },
            stage: { id in
                if let target = items.first(where: { $0.id == id }) { Task { await stage([target]) } }
            },
            selectAll: { checked = Set(items.map(\.id)) },
            clearSelection: { checked.removeAll() }
        )
    }

    private var inspector: some View {
        Group {
            if let t = active {
                ReviewableInspector(model: model, target: t) { Task { await stage([t]) } }
            } else {
                DiskMapEmptyState(symbol: "internaldrive", title: "Select an app", message: "Its cache details appear here.")
            }
        }
        .background(DiskMapTheme.canvas)
    }

    private func stage(_ items: [ReviewableTarget]) async {
        let added = await model.stageReviewTargets(items) { "Cache: " + $0.displayName }
        if added > 0 { checked.subtract(items.map(\.id)) }
    }
}
