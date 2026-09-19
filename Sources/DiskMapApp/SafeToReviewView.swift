import AppKit
import DiskMapCore
import SwiftUI

/// Clean → Safe to Review: categorized, selectable cleanup opportunities.
struct SafeToReviewView: View {
    @ObservedObject var model: ScanModel
    @Environment(\.diskMapContentWidth) private var contentWidth
    var onOpenCleanup: () -> Void
    var onOpenCaches: () -> Void

    @State private var checked: Set<String> = []
    @State private var selectedID: String?
    @State private var query = ""

    private var targets: [ReviewableTarget] { model.cachedReviewables }
    private var summary: ReviewableSummary { model.cachedReviewableSummary }

    private var visible: [ReviewableTarget] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let list = targets.filter { $0.safety.level != .protected }
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

    private var selectedBytes: Int64 {
        visible.filter { checked.contains($0.id) }.reduce(Int64(0)) { $0 + $1.bytes }
    }

    var body: some View {
        AdaptiveInspectorSplit(windowWidth: contentWidth, inspectionToken: selectedID, main: mainColumn, inspector: inspector)
        .background(DiskMapTheme.cream)
        .task {
            if model.cachedReviewables.isEmpty, model.tree != nil {
                model.refreshReviewableCache()
            }
        }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            summaryCard
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            quickWins
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            listControls
            VStack(alignment: .leading, spacing: 0) {
                Divider().overlay(DiskMapTheme.cardStroke)
                if visible.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            selectionBar
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Safe to Review")
                .font(DiskMapType.title)
                .foregroundStyle(DiskMapTheme.ink)
            Text("Storage with an understandable cleanup path. Nothing is deleted automatically — you review, then confirm in Cleanup.")
                .font(DiskMapType.body)
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Potentially reviewable")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Text(ByteFormat.string(summary.totalBytes))
                .font(.system(size: 28, weight: .semibold).monospacedDigit())
                .foregroundStyle(DiskMapTheme.ink)
            Text("\(summary.targetCount.formatted()) items · \(summary.cacheAppCount.formatted()) cache apps")
                .font(.system(size: 12))
                .foregroundStyle(DiskMapTheme.mutedLabel)

            Color.clear
                .frame(height: 10)
                .overlay {
                    GeometryReader { geo in
                        let total = max(1, summary.totalBytes)
                        HStack(spacing: 2) {
                            seg(summary.cacheBytes, total, geo.size.width, DiskMapTheme.safe)
                            seg(summary.buildBytes, total, geo.size.width, DiskMapTheme.review)
                            seg(summary.packageBytes, total, geo.size.width, Color(red: 0.35, green: 0.55, blue: 0.90))
                            seg(summary.otherBytes, total, geo.size.width, DiskMapTheme.mutedLabel.opacity(0.5))
                        }
                    }
                }

            HStack(spacing: 14) {
                legend("Caches", summary.cacheBytes, DiskMapTheme.safe)
                legend("Build", summary.buildBytes, DiskMapTheme.review)
                legend("Packages", summary.packageBytes, Color(red: 0.35, green: 0.55, blue: 0.90))
                legend("Other", summary.otherBytes, DiskMapTheme.mutedLabel)
                Spacer()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DiskMapTheme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                )
        )
    }

    private func seg(_ bytes: Int64, _ total: Int64, _ width: CGFloat, _ color: Color) -> some View {
        let w = width * CGFloat(Double(bytes) / Double(total))
        return RoundedRectangle(cornerRadius: 3)
            .fill(color)
            .frame(width: max(bytes > 0 ? 4 : 0, w))
    }

    private func legend(_ title: String, _ bytes: Int64, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(title) · \(ByteFormat.string(bytes))")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DiskMapTheme.ink)
        }
    }

    private var quickWins: some View {
        HStack(spacing: 10) {
            quickCard(
                title: "Caches",
                bytes: summary.cacheBytes,
                subtitle: "\(summary.cacheAppCount) apps · Generally regenerable",
                tint: DiskMapTheme.safe
            ) { onOpenCaches() }
            quickCard(
                title: "Build artifacts",
                bytes: summary.buildBytes,
                subtitle: "Generated output · Review first",
                tint: DiskMapTheme.review
            ) {
                selectedID = visible.first(where: { $0.category == .buildArtifacts })?.id
            }
            quickCard(
                title: "Package caches",
                bytes: summary.packageBytes,
                subtitle: "npm · Cargo · Gradle…",
                tint: Color(red: 0.35, green: 0.55, blue: 0.90)
            ) {
                selectedID = visible.first(where: { $0.category == .packageCaches })?.id
            }
        }
    }

    private func quickCard(title: String, bytes: Int64, subtitle: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.ink)
                Text(ByteFormat.string(bytes))
                    .font(.system(size: 18, weight: .semibold).monospacedDigit())
                    .foregroundStyle(tint)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .lineLimit(2)
                Text("Review →")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.ink)
                    .padding(.top, 4)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DiskMapTheme.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var listControls: some View {
        HStack {
            Text("Recommended cleanup")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DiskMapTheme.ink)
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                TextField("Search…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 160)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DiskMapTheme.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                    )
            )
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(visible) { t in
                    row(t)
                    Rectangle()
                        .fill(DiskMapTheme.cardStroke.opacity(0.55))
                        .frame(height: 1)
                        .padding(.leading, 48)
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func row(_ t: ReviewableTarget) -> some View {
        let on = checked.contains(t.id)
        let selected = t.id == selectedID
        return HStack(spacing: 10) {
            Button {
                if on { checked.remove(t.id) } else { checked.insert(t.id) }
            } label: {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(on ? DiskMapTheme.ink : DiskMapTheme.mutedLabel)
            }
            .buttonStyle(.plain)

            Button {
                selectedID = t.id
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: t.symbolName)
                        .font(.system(size: 14))
                        .foregroundStyle(DiskMapTheme.ink)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(DiskMapTheme.navSelected))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DiskMapTheme.ink)
                        Text("\(t.detail) · \(t.category.title)")
                            .font(.system(size: 11))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    safetyPill(t.safety.level)
                    Text(ByteFormat.string(t.bytes))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(DiskMapTheme.ink)
                        .frame(width: 84, alignment: .trailing)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selected ? DiskMapTheme.ink.opacity(0.06) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
    }

    private func safetyPill(_ level: SafetyLevel) -> some View {
        Text(level == .safe ? "Generally safe" : level.title)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color(level))
            .background(Capsule().fill(color(level).opacity(0.14)))
            .frame(width: 110, alignment: .leading)
    }

    private func color(_ level: SafetyLevel) -> Color {
        switch level {
        case .safe: return DiskMapTheme.safe
        case .review: return DiskMapTheme.review
        case .protected: return DiskMapTheme.danger
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "leaf")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Text("Nothing to clean up")
                .font(DiskMapType.section)
            Text("DiskMap didn’t find high-confidence cleanup candidates in this scan.")
                .font(DiskMapType.body)
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(DiskMapTheme.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var selectionBar: some View {
        HStack {
            if checked.isEmpty {
                Text("\(visible.count.formatted()) items")
                    .font(.system(size: 12))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            } else {
                Text("\(checked.count.formatted()) selected · \(ByteFormat.string(selectedBytes))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.ink)
            }
            Spacer()
            if checked.isEmpty {
                Button("Select generally safe") {
                    checked = Set(visible.filter(\.isGenerallySafe).map(\.id))
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DiskMapTheme.ink)
            } else {
                Button("Clear") { checked.removeAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                Button("Review selected →") {
                    Task { await stageChecked() }
                }
                .buttonStyle(InkButtonStyle(filled: true))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(DiskMapTheme.cardFill)
        .overlay(alignment: .top) { Divider().overlay(DiskMapTheme.cardStroke) }
    }

    private var inspector: some View {
        Group {
            if let t = active {
                ReviewableInspector(model: model, target: t, onOpenCleanup: onOpenCleanup) {
                    Task { await stageOne(t) }
                }
            } else {
                VStack {
                    Text("Select an item")
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DiskMapTheme.cardFill)
    }

    private func stageChecked() async {
        let items = visible.filter { checked.contains($0.id) && !$0.isProtected }
        var ok = 0
        for t in items {
            ok += await stageTarget(t) ? 1 : 0
        }
        await model.refreshQueue()
        model.showToast(ok > 0 ? "Added \(ok) to Cleanup" : "Nothing added")
        if ok > 0 { onOpenCleanup() }
    }

    private func stageOne(_ t: ReviewableTarget) async {
        let ok = await stageTarget(t)
        await model.refreshQueue()
        model.showToast(ok ? "Added to Cleanup" : "Blocked or already added")
        if ok { onOpenCleanup() }
    }

    private func stageTarget(_ t: ReviewableTarget) async -> Bool {
        guard !t.isProtected, !t.paths.isEmpty else { return false }
        var any = false
        let totals = model.selectedTotals
        for (idx, path) in t.paths.enumerated() {
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            if model.isStaged(url) { any = true; continue }
            var size = t.bytes / Int64(max(1, t.paths.count))
            if idx < t.nodeIDs.count {
                let nid = Int(t.nodeIDs[idx])
                if nid < totals.count { size = totals[nid] }
            }
            if await model.cleanupQueue.stage(url, size: size, reason: "Safe to review: " + t.displayName) {
                any = true
            }
        }
        return any
    }
}
