import AppKit
import DiskMapCore
import SwiftUI

/// Clean → Safe to Review: categorized, selectable cleanup opportunities.
/// One bar whose segments are the tabs; one list; one inspector.
struct SafeToReviewView: View {
    @ObservedObject var model: ScanModel
    @Environment(\.diskMapContentWidth) private var contentWidth
    var onOpenCaches: () -> Void

    @State private var checked: Set<String> = []
    @State private var selectedID: String?
    @State private var query = ""
    @State private var category: ReviewableCategory?

    private var targets: [ReviewableTarget] { model.cachedReviewables.filter { $0.safety.level != .protected } }
    private var summary: ReviewableSummary { model.cachedReviewableSummary }

    private var visible: [ReviewableTarget] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var list = targets
        if let category { list = list.filter { $0.category == category } }
        if q.isEmpty { return list }
        return list.filter {
            $0.displayName.lowercased().contains(q)
                || $0.detail.lowercased().contains(q)
                || $0.primaryPath.lowercased().contains(q)
        }
    }

    private var active: ReviewableTarget? {
        if let selectedID, let hit = visible.first(where: { $0.id == selectedID }) { return hit }
        return visible.first
    }

    private var checkedTargets: [ReviewableTarget] { visible.filter { checked.contains($0.id) } }

    /// The four categories, each with its bar colour and size.
    private var segments: [(category: ReviewableCategory, bytes: Int64, color: Color)] {
        [
            (.caches, summary.cacheBytes, DiskMapTheme.data(0)),
            (.buildArtifacts, summary.buildBytes, DiskMapTheme.data(4)),
            (.packageCaches, summary.packageBytes, DiskMapTheme.data(1)),
            (.other, summary.otherBytes, DiskMapTheme.data(6)),
        ]
    }

    var body: some View {
        AdaptiveInspectorSplit(windowWidth: contentWidth, inspectionToken: selectedID, main: mainColumn, inspector: inspector)
        .background(DiskMapTheme.canvas)
        .catalogGate(.reviewables, model: model, title: "Finding safe-to-review items…")
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(eyebrow: "Clean", title: "Safe to Review",
                           subtitle: "Storage with a clear cleanup path. Nothing is removed until you confirm in Cleanup.") {
                    HeaderSummary(parts: [ByteFormat.string(summary.totalBytes), countLabel(summary.targetCount, "item")])
                }
                categoryBar
                HStack(spacing: 10) {
                    DiskMapSearchField(placeholder: "Search items", text: $query)
                        .frame(maxWidth: 300)
                    Spacer(minLength: 8)
                    if category == .caches {
                        Button("Caches by app →", action: onOpenCaches)
                            .buttonStyle(LinkButtonStyle())
                            .font(DiskMapType.secondary)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, DiskMapSpace.pageTop)
            .padding(.bottom, 12)
            Hairline()
            if visible.isEmpty {
                DiskMapEmptyState(symbol: "leaf", title: targets.isEmpty ? "Nothing to clean up" : "Nothing matches",
                                  message: targets.isEmpty ? "DiskMap didn’t find high-confidence cleanup candidates in this scan."
                                      : "Try another category, or clear the search.")
            } else {
                list
            }
            ReviewSelectionFooter(
                checkedTargets: checkedTargets,
                hint: "Tick items to clean, or",
                quickSelectTitle: "Select generally safe",
                quickSelectEnabled: visible.contains(where: \.isGenerallySafe),
                onQuickSelect: { checked = Set(visible.filter(\.isGenerallySafe).map(\.id)) },
                onStage: { Task { await stage(checkedTargets) } },
                onClear: { checked.removeAll() }
            )
        }
    }

    /// The stacked bar and, under it, the tabs that filter by its segments.
    private var categoryBar: some View {
        let total = max(1, summary.totalBytes)
        return VStack(alignment: .leading, spacing: 12) {
            SegmentedStorageBar(segments: segments.map { seg in
                (seg.color.opacity(category == nil || category == seg.category ? 1 : 0.3), Double(seg.bytes) / Double(total))
            })
            .accessibilityHidden(true)
            HStack(spacing: DiskMapSpace.lg) {
                tab(nil, title: "All", bytes: summary.totalBytes, color: nil)
                ForEach(segments.filter { $0.bytes > 0 }, id: \.category) { seg in
                    tab(seg.category, title: Self.shortTitle(seg.category), bytes: seg.bytes, color: seg.color)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func tab(_ value: ReviewableCategory?, title: String, bytes: Int64, color: Color?) -> some View {
        let on = category == value
        return Button { category = value } label: {
            HStack(spacing: 6) {
                if let color { Circle().fill(color).frame(width: 7, height: 7) }
                Text(title)
                    .font(on ? DiskMapType.bodyEmphasis : DiskMapType.body)
                    .foregroundStyle(on ? DiskMapTheme.ink : DiskMapTheme.ink2)
                Text(ByteFormat.string(bytes))
                    .font(DiskMapType.figureSmall)
                    .foregroundStyle(DiskMapTheme.ink3)
            }
            .fixedSize()
            .padding(.vertical, 4)
            .overlay(alignment: .bottom) {
                Rectangle().fill(on ? DiskMapTheme.ink : .clear).frame(height: 1.5).offset(y: 5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(ByteFormat.string(bytes))")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    static func shortTitle(_ category: ReviewableCategory) -> String {
        switch category {
        case .caches: return "Caches"
        case .buildArtifacts: return "Build output"
        case .packageCaches: return "Packages"
        case .other: return "Other"
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
                        target: t, subtitle: "\(t.detail) · \(t.category.title)",
                        checked: checked.contains(t.id), selected: t.id == activeID,
                        onToggle: { toggle(t.id) },
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

    private func toggle(_ id: String) {
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
    }

    private var inspector: some View {
        Group {
            if let t = active {
                ReviewableInspector(model: model, target: t) { Task { await stage([t]) } }
            } else {
                DiskMapEmptyState(symbol: "leaf", title: "Select an item", message: "Its details and actions appear here.")
            }
        }
        .background(DiskMapTheme.canvas)
    }

    private func stage(_ items: [ReviewableTarget]) async {
        let added = await model.stageReviewTargets(items) { "Safe to review: " + $0.displayName }
        if added > 0 { checked.subtract(items.map(\.id)) }
    }
}
