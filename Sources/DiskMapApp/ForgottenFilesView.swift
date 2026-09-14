import AppKit
import DiskMapCore
import SwiftUI

/// Find → Forgotten Files. Uses ScanModel.cachedForgotten (computed once per scan).
struct ForgottenFilesView: View {
    @ObservedObject var model: ScanModel
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
            case .excluded: return "Old but important"
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
    @State private var checked: Set<Int32> = []
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

    private var selectedBytes: Int64 {
        let ids = checked
        return visible.reduce(Int64(0)) { partial, c in
            ids.contains(c.id) ? partial + c.bytes : partial
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            mainColumn
            Divider().overlay(DiskMapTheme.cardStroke)
            inspectorColumn
                .frame(width: 320)
        }
        .background(DiskMapTheme.cream)
        .task {
            if model.cachedForgotten.isEmpty, model.tree != nil {
                model.refreshForgottenCache()
            }
            if selectedID == nil {
                selectedID = visible.first?.id
            }
        }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            summaryCards
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            ageBar
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            filterPills
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            controls
            listHeader
            Divider().overlay(DiskMapTheme.cardStroke)
            if model.isScanning {
                ProgressView("Finding files you may have forgotten…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                emptyState
            } else {
                list
            }
            selectionBar
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Forgotten Files")
                    .font(DiskMapType.title)
                    .foregroundStyle(DiskMapTheme.ink)
                Text("Find things you may no longer need. Older personal files are prioritized; system and app-managed data is excluded.")
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                Text("Based on last-modified date")
                    .font(.system(size: 11))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(DiskMapTheme.navSelected))
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var summaryCards: some View {
        HStack(spacing: 10) {
            card("Potentially reviewable", summary.reviewableBytes, summary.reviewableCount, "tray.full", DiskMapTheme.ink, filterTab == .all) {
                filterTab = .all; ageFilter = nil
            }
            card("Likely forgotten", summary.likelyBytes, summary.likelyCount, "leaf", DiskMapTheme.safe, filterTab == .likely) {
                filterTab = .likely
            }
            card("Worth reviewing", summary.worthBytes, summary.worthCount, "eye", DiskMapTheme.review, filterTab == .worth) {
                filterTab = .worth
            }
            card("Old but important", summary.excludedBytes, summary.excludedCount, "shield", DiskMapTheme.mutedLabel, filterTab == .excluded) {
                filterTab = .excluded
            }
        }
    }

    private func card(
        _ title: String,
        _ bytes: Int64,
        _ count: Int,
        _ symbol: String,
        _ tint: Color,
        _ selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                    Spacer()
                }
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .lineLimit(1)
                Text(ByteFormat.string(bytes))
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DiskMapTheme.ink)
                Text("\(count.formatted()) files" + (title.contains("important") ? " · excluded" : ""))
                    .font(.system(size: 10))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DiskMapTheme.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(selected ? tint.opacity(0.6) : DiskMapTheme.cardStroke, lineWidth: selected ? 1.5 : 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    /// Single segmented bar (reference style) — not separate columns.
    private var ageBar: some View {
        let dist = summary.ageDistribution
        let total = max(1, ForgottenAgeBucket.allCases.reduce(Int64(0)) { $0 + (dist[$1] ?? 0) })
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Forgotten files by age")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.ink)
                Spacer()
                Text("Show: Forgotten candidates")
                    .font(.system(size: 11))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(ForgottenAgeBucket.allCases) { bucket in
                        let bytes = dist[bucket] ?? 0
                        let w = geo.size.width * CGFloat(Double(bytes) / Double(total))
                        if bytes > 0 {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(ageTint(bucket).opacity(ageFilter == nil || ageFilter == bucket ? 1 : 0.35))
                                .frame(width: max(4, w))
                                .help("\(bucket.title): \(ByteFormat.string(bytes))")
                                .onTapGesture {
                                    ageFilter = (ageFilter == bucket) ? nil : bucket
                                }
                        }
                    }
                }
            }
            .frame(height: 18)
            HStack(spacing: 14) {
                ForEach(ForgottenAgeBucket.allCases) { bucket in
                    let bytes = dist[bucket] ?? 0
                    if bytes > 0 {
                        Button {
                            ageFilter = (ageFilter == bucket) ? nil : bucket
                        } label: {
                            HStack(spacing: 5) {
                                Circle().fill(ageTint(bucket)).frame(width: 7, height: 7)
                                Text("\(bucket.shortTitle) · \(ByteFormat.string(bytes))")
                                    .font(.system(size: 10, weight: ageFilter == bucket ? .bold : .medium))
                                    .foregroundStyle(DiskMapTheme.ink)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
                if ageFilter != nil {
                    Button("Clear") { ageFilter = nil }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DiskMapTheme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                )
        )
    }

    private func ageTint(_ bucket: ForgottenAgeBucket) -> Color {
        switch bucket {
        case .oneToTwoYears: return Color(red: 0.35, green: 0.72, blue: 0.55)
        case .twoToThreeYears: return Color(red: 0.92, green: 0.72, blue: 0.28)
        case .threeToFiveYears: return Color(red: 0.92, green: 0.55, blue: 0.28)
        case .overFiveYears: return Color(red: 0.85, green: 0.38, blue: 0.38)
        }
    }

    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pill("All (\(summary.reviewableCount))", filterTab == .all && !onlyLarge && !onlyDownloads && !onlyMedia) {
                    filterTab = .all; onlyLarge = false; onlyDownloads = false; onlyMedia = false
                }
                pill("Likely forgotten (\(summary.likelyCount))", filterTab == .likely) {
                    filterTab = .likely
                }
                pill("Worth reviewing (\(summary.worthCount))", filterTab == .worth) {
                    filterTab = .worth
                }
                pill("Large (>1 GB)", onlyLarge) { onlyLarge.toggle() }
                pill("Downloads", onlyDownloads) { onlyDownloads.toggle() }
                pill("Media", onlyMedia) { onlyMedia.toggle() }
            }
        }
    }

    private func pill(_ title: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .foregroundStyle(on ? Color.white : DiskMapTheme.ink)
                .background(Capsule().fill(on ? DiskMapTheme.ink : DiskMapTheme.navSelected))
        }
        .buttonStyle(.plain)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                TextField("Search forgotten files…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(DiskMapTheme.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                    )
            )
            Menu {
                ForEach(SortMode.allCases) { mode in
                    Button(mode.title) { sortMode = mode }
                }
            } label: {
                HStack {
                    Text("Sort: " + sortMode.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(width: 190)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(DiskMapTheme.cardFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                        )
                )
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var listHeader: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 22)
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Location").frame(width: 140, alignment: .leading)
            Text("Size").frame(width: 72, alignment: .trailing)
            Text("Modified").frame(width: 88, alignment: .trailing)
            Text("Reason").frame(width: 118, alignment: .leading)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(DiskMapTheme.mutedLabel)
        .padding(.horizontal, 28)
        .padding(.vertical, 6)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
                ForEach(visible) { c in
                    ForgottenRow(
                        candidate: c,
                        selected: c.id == selectedID,
                        checked: checked.contains(c.id),
                        onSelect: {
                            selectedID = c.id
                            model.selectedNode = c.id
                        },
                        onToggleCheck: {
                            if checked.contains(c.id) { checked.remove(c.id) }
                            else { checked.insert(c.id) }
                        }
                    )
                    Rectangle()
                        .fill(DiskMapTheme.cardStroke.opacity(0.55))
                        .frame(height: 1)
                        .padding(.leading, 48)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            if summary.excludedCount > 0 && summary.reviewableCount == 0 && filterTab != .excluded {
                Text("Nothing worth reviewing yet")
                    .font(DiskMapType.section)
                Text("Old files were found, but most belong to apps, package managers, or macOS — so they aren’t recommended here.")
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                Button("Show excluded") { filterTab = .excluded }
                    .buttonStyle(InkButtonStyle(filled: false))
            } else {
                Text(filterTab == .excluded ? "No excluded old files" : "No forgotten files found")
                    .font(DiskMapType.section)
                Text("Try another filter, or clear search.")
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
        }
        .foregroundStyle(DiskMapTheme.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var selectionBar: some View {
        HStack {
            if checked.isEmpty {
                Text("\(visible.count.formatted()) shown")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            } else {
                Text("\(checked.count.formatted()) selected · \(ByteFormat.string(selectedBytes))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.ink)
            }
            Spacer()
            if checked.isEmpty {
                Button("Select visible") {
                    checked = Set(visible.filter(\.isReviewable).prefix(200).map(\.id))
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DiskMapTheme.ink)
                .disabled(visible.allSatisfy { !$0.isReviewable })
            } else {
                Button("Clear") { checked.removeAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                Button("Review selected →") {
                    Task { await stageSelected() }
                }
                .buttonStyle(InkButtonStyle(filled: true))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(DiskMapTheme.cardFill)
        .overlay(alignment: .top) { Divider().overlay(DiskMapTheme.cardStroke) }
    }

    private var inspectorColumn: some View {
        Group {
            if let c = active {
                ForgottenInspectorPanel(model: model, candidate: c, onOpenCleanup: onOpenCleanup) {
                    Task { await stageOne(c) }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                    Text("Select a file")
                        .font(DiskMapType.body)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DiskMapTheme.cardFill)
    }

    private func stageSelected() async {
        let items = visible.filter { checked.contains($0.id) && $0.isReviewable }
        var okCount = 0
        for c in items {
            let url = URL(fileURLWithPath: c.absolutePath).standardizedFileURL
            if model.isStaged(url) { okCount += 1; continue }
            if c.safety.level == .protected { continue }
            if await model.cleanupQueue.stage(url, size: c.bytes, reason: "Forgotten: " + c.confidence.title) {
                okCount += 1
            }
        }
        await model.refreshQueue()
        model.showToast(okCount > 0 ? "Added \(okCount) to cleanup review" : "Nothing could be staged")
        if okCount > 0 { onOpenCleanup() }
    }

    private func stageOne(_ c: ForgottenCandidate) async {
        guard c.isReviewable, c.safety.level != .protected else {
            model.showToast("Not recommended for cleanup")
            return
        }
        let url = URL(fileURLWithPath: c.absolutePath).standardizedFileURL
        if model.isStaged(url) {
            model.showToast("Already in cleanup list")
            onOpenCleanup()
            return
        }
        let ok = await model.cleanupQueue.stage(url, size: c.bytes, reason: "Forgotten: " + c.confidence.title)
        await model.refreshQueue()
        if ok {
            model.showToast("Added to cleanup review")
            onOpenCleanup()
        } else {
            model.showToast("Blocked by safety rules")
        }
    }
}

// MARK: - Row (separate type so selection doesn’t rebuild heavy closures inline)

private struct ForgottenRow: View {
    let candidate: ForgottenCandidate
    let selected: Bool
    let checked: Bool
    let onSelect: () -> Void
    let onToggleCheck: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleCheck) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(checked ? DiskMapTheme.ink : DiskMapTheme.mutedLabel)
            }
            .buttonStyle(.plain)
            .frame(width: 22)

            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Image(systemName: candidate.kind.symbolName)
                        .font(.system(size: 13))
                        .foregroundStyle(kindTint)
                        .frame(width: 18)
                    Text(candidate.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(candidate.parentDisplay)
                        .font(.system(size: 11))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 140, alignment: .leading)
                    Text(ByteFormat.string(candidate.bytes))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(DiskMapTheme.ink)
                        .frame(width: 72, alignment: .trailing)
                    Text(ForgottenAgeFormat.string(candidate.ageDays))
                        .font(.system(size: 11))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .frame(width: 88, alignment: .trailing)
                    Text(candidate.confidence.title)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .foregroundStyle(confColor)
                        .background(Capsule().fill(confColor.opacity(0.14)))
                        .frame(width: 118, alignment: .leading)
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? DiskMapTheme.ink.opacity(0.06) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
    }

    private var confColor: Color {
        switch candidate.confidence {
        case .likelyForgotten: return DiskMapTheme.safe
        case .worthReviewing: return DiskMapTheme.review
        case .oldImportant: return DiskMapTheme.mutedLabel
        }
    }

    private var kindTint: Color {
        switch candidate.kind {
        case .video: return Color(red: 0.55, green: 0.35, blue: 0.85)
        case .diskImage: return Color(red: 0.25, green: 0.45, blue: 0.90)
        case .archive: return Color(red: 0.92, green: 0.50, blue: 0.20)
        default: return DiskMapTheme.mutedLabel
        }
    }
}

enum ForgottenAgeFormat {
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

private struct ForgottenInspectorPanel: View {
    @ObservedObject var model: ScanModel
    let candidate: ForgottenCandidate
    var onOpenCleanup: () -> Void
    var onStageOne: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: candidate.kind.symbolName)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(DiskMapTheme.ink)
                        .frame(width: 56, height: 56)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(DiskMapTheme.ink.opacity(0.08))
                        )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidate.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DiskMapTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Text(ByteFormat.string(candidate.bytes))
                            .font(.system(size: 26, weight: .semibold).monospacedDigit())
                            .foregroundStyle(DiskMapTheme.ink)
                        Text(candidate.kind.title + " · " + ForgottenAgeFormat.string(candidate.ageDays))
                            .font(.system(size: 11))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                meta("Location", candidate.displayPath)
                meta("Type", candidate.kind.title)
                meta("Size", "\(candidate.bytes.formatted()) bytes")

                VStack(alignment: .leading, spacing: 6) {
                    Text("Why was this flagged?")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                    ForEach(candidate.reasons, id: \.self) { reason in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•").foregroundStyle(DiskMapTheme.mutedLabel)
                            Text(reason)
                                .font(.system(size: 12))
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(red: 0.93, green: 0.95, blue: 0.99))
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text("Our recommendation")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                    Text(candidate.confidence.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(confColor)
                    Text(recommendationCopy)
                        .font(.system(size: 12))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(confColor.opacity(0.10))
                )

                VStack(spacing: 8) {
                    if candidate.isReviewable && candidate.safety.level != .protected {
                        Button {
                            onStageOne()
                        } label: {
                            Label("Add to Cleanup", systemImage: "trash")
                        }
                        .buttonStyle(PrimaryCTAStyle(fullWidth: true))
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: candidate.absolutePath)])
                    }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                    Button("Open Containing Folder") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: candidate.absolutePath).deletingLastPathComponent())
                    }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(candidate.displayPath, forType: .string)
                        model.showToast("Path copied")
                    }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                    if candidate.isReviewable {
                        Button("View in Biggest Files →") {
                            model.folderFilterPath = URL(fileURLWithPath: candidate.absolutePath)
                                .deletingLastPathComponent().path
                            model.destination = .biggestFiles
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                    }
                }

                Text("Based primarily on last-modified date. macOS doesn’t always provide a reliable last-opened date.")
                    .font(.system(size: 10))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
    }

    private var confColor: Color {
        switch candidate.confidence {
        case .likelyForgotten: return DiskMapTheme.safe
        case .worthReviewing: return DiskMapTheme.review
        case .oldImportant: return DiskMapTheme.mutedLabel
        }
    }

    private var recommendationCopy: String {
        switch candidate.confidence {
        case .likelyForgotten:
            return "Large personal file that hasn’t been modified in a long time. Review before removing — nothing is deleted until you confirm in Cleanup."
        case .worthReviewing:
            return "Worth a careful look. Confirm you recognize it before adding it to Cleanup."
        case .oldImportant:
            return "Although old, this isn’t recommended for Forgotten cleanup. It looks like app, package-manager, or system-related data."
        }
    }

    private func meta(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DiskMapTheme.ink)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
        }
    }
}
