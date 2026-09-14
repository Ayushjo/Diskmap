import AppKit
import DiskMapCore
import SwiftUI

/// Find → Forgotten Files: discovery + review (not a raw age sort).
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
            case .all: return "Worth reviewing"
            case .likely: return "Likely forgotten"
            case .worth: return "Worth a look"
            case .excluded: return "Old but important"
            }
        }
    }

    enum SortMode: String, CaseIterable, Identifiable {
        case reviewValue, largest, oldest, name
        var id: String { rawValue }
        var title: String {
            switch self {
            case .reviewValue: return "Most worth reviewing"
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

    private var totals: [Int64] { model.selectedTotals }

    private var allCandidates: [ForgottenCandidate] {
        guard totals.count == tree.count else { return [] }
        return ForgottenFiles.candidates(
            tree: tree,
            root: rootURL,
            totals: totals,
            limit: 500
        )
    }

    private var summary: ForgottenSummary {
        ForgottenFiles.summary(from: allCandidates)
    }

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
        if !q.isEmpty {
            list = list.filter {
                $0.name.lowercased().contains(q)
                    || $0.displayPath.lowercased().contains(q)
                    || $0.kind.title.lowercased().contains(q)
            }
        }
        switch sortMode {
        case .reviewValue:
            list.sort { $0.score > $1.score }
        case .largest:
            list.sort { $0.bytes > $1.bytes }
        case .oldest:
            list.sort { $0.ageDays > $1.ageDays }
        case .name:
            list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return list
    }

    private var activeSelection: ForgottenCandidate? {
        if let selectedID, let hit = visible.first(where: { $0.id == selectedID }) {
            return hit
        }
        return visible.first
    }

    private var selectedBytes: Int64 {
        visible.filter { checked.contains($0.id) }.reduce(Int64(0)) { $0 + $1.bytes }
    }

    var body: some View {
        HStack(spacing: 0) {
            mainColumn
            Divider().overlay(DiskMapTheme.cardStroke)
            inspector
                .frame(width: 320)
        }
        .background(DiskMapTheme.cream)
        .onAppear {
            if selectedID == nil { selectedID = visible.first?.id }
        }
        .onChange(of: filterTab) { _, _ in
            selectedID = visible.first?.id
        }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            summaryCards
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            ageChart
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            controls
            Divider().overlay(DiskMapTheme.cardStroke)
            if model.isScanning {
                ProgressView("Finding files you may have forgotten…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                emptyState
            } else {
                list
                selectionBar
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Forgotten Files")
                    .font(DiskMapType.title)
                    .foregroundStyle(DiskMapTheme.ink)
                Text("Find things you may no longer need. Older personal files are prioritized; system and app-managed data is excluded from recommendations.")
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 2) {
                Text("Potentially reviewable")
                    .font(DiskMapType.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                Text(ByteFormat.string(summary.reviewableBytes))
                    .font(.system(size: 18, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DiskMapTheme.ink)
                Text("\(summary.reviewableCount.formatted()) files")
                    .font(DiskMapType.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var summaryCards: some View {
        HStack(spacing: 10) {
            summaryCard(
                title: "Likely forgotten",
                bytes: summary.likelyBytes,
                count: summary.likelyCount,
                tint: DiskMapTheme.safe,
                selected: filterTab == .likely
            ) { filterTab = .likely }

            summaryCard(
                title: "Worth a look",
                bytes: summary.worthBytes,
                count: summary.worthCount,
                tint: DiskMapTheme.review,
                selected: filterTab == .worth
            ) { filterTab = .worth }

            summaryCard(
                title: "Excluded",
                bytes: summary.excludedBytes,
                count: summary.excludedCount,
                tint: DiskMapTheme.mutedLabel,
                selected: filterTab == .excluded
            ) { filterTab = .excluded }

            summaryCard(
                title: "All reviewable",
                bytes: summary.reviewableBytes,
                count: summary.reviewableCount,
                tint: DiskMapTheme.ink,
                selected: filterTab == .all
            ) { filterTab = .all; ageFilter = nil }
        }
    }

    private func summaryCard(
        title: String,
        bytes: Int64,
        count: Int,
        tint: Color,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(ByteFormat.string(bytes))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DiskMapTheme.ink)
                Text("\(count.formatted()) files")
                    .font(.system(size: 10))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DiskMapTheme.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(selected ? tint.opacity(0.55) : DiskMapTheme.cardStroke, lineWidth: selected ? 1.5 : 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var ageChart: some View {
        let dist = summary.ageDistribution
        let total = max(1, ForgottenAgeBucket.allCases.reduce(Int64(0)) { $0 + (dist[$1] ?? 0) })
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Forgotten files by age")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.ink)
                Spacer()
                Text("Candidates only · not all disk files")
                    .font(.system(size: 10))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
            GeometryReader { geo in
                HStack(spacing: 3) {
                    ForEach(ForgottenAgeBucket.allCases) { bucket in
                        let bytes = dist[bucket] ?? 0
                        let frac = CGFloat(Double(bytes) / Double(total))
                        let width = max(bytes > 0 ? 28 : 0, geo.size.width * frac)
                        if bytes > 0 {
                            Button {
                                ageFilter = (ageFilter == bucket) ? nil : bucket
                            } label: {
                                VStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(ageTint(bucket).opacity(ageFilter == nil || ageFilter == bucket ? 0.85 : 0.35))
                                        .frame(width: width, height: 28)
                                    Text(bucket.shortTitle)
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(DiskMapTheme.mutedLabel)
                                    Text(ByteFormat.string(bytes))
                                        .font(.system(size: 9).monospacedDigit())
                                        .foregroundStyle(DiskMapTheme.ink)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(bucket.title), \(ByteFormat.string(bytes))")
                        }
                    }
                }
            }
            .frame(height: 70)
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
        case .oneToTwoYears: return Color(red: 0.45, green: 0.62, blue: 0.90)
        case .twoToThreeYears: return Color(red: 0.55, green: 0.55, blue: 0.88)
        case .threeToFiveYears: return Color(red: 0.70, green: 0.50, blue: 0.80)
        case .overFiveYears: return Color(red: 0.75, green: 0.45, blue: 0.55)
        }
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
            .frame(width: 210)

            if ageFilter != nil {
                Button("Clear age filter") { ageFilter = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            if filterTab == .excluded {
                Text("No excluded old files in this scan")
                    .font(DiskMapType.section)
                    .foregroundStyle(DiskMapTheme.ink)
            } else if summary.excludedCount > 0 && summary.reviewableCount == 0 {
                Text("Nothing worth reviewing yet")
                    .font(DiskMapType.section)
                    .foregroundStyle(DiskMapTheme.ink)
                Text("DiskMap found old files, but most appear to belong to macOS or installed apps. No cleanup candidates were recommended.")
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            } else {
                Text("No forgotten files found")
                    .font(DiskMapType.section)
                    .foregroundStyle(DiskMapTheme.ink)
                Text("Nothing large and old enough to be worth reviewing matched this filter.")
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(visible) { candidate in
                    row(candidate)
                    Rectangle()
                        .fill(DiskMapTheme.cardStroke.opacity(0.65))
                        .frame(height: 1)
                        .padding(.leading, 52)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private func row(_ c: ForgottenCandidate) -> some View {
        let selected = c.id == (selectedID ?? activeSelection?.id)
        let isChecked = checked.contains(c.id)
        return HStack(spacing: 10) {
            Button {
                if isChecked { checked.remove(c.id) } else { checked.insert(c.id) }
            } label: {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle(isChecked ? DiskMapTheme.ink : DiskMapTheme.mutedLabel)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isChecked ? "Deselect \(c.name)" : "Select \(c.name)")

            Button {
                selectedID = c.id
                model.selectedNode = c.id
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: c.kind.symbolName)
                        .font(.system(size: 14))
                        .foregroundStyle(kindTint(c.kind))
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(c.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DiskMapTheme.ink)
                            .lineLimit(1)
                        Text(c.parentDisplay + " · " + relativeAge(c.ageDays))
                            .font(.system(size: 11))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    confidencePill(c.confidence)
                    Text(ByteFormat.string(c.bytes))
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

    private func confidencePill(_ c: ForgottenConfidence) -> some View {
        Text(c.title)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(confidenceColor(c))
            .background(Capsule().fill(confidenceColor(c).opacity(0.14)))
            .frame(width: 120, alignment: .leading)
    }

    private func confidenceColor(_ c: ForgottenConfidence) -> Color {
        switch c {
        case .likelyForgotten: return DiskMapTheme.safe
        case .worthReviewing: return DiskMapTheme.review
        case .oldImportant: return DiskMapTheme.mutedLabel
        }
    }

    private var selectionBar: some View {
        HStack {
            Text(checked.isEmpty
                 ? "\(visible.count.formatted()) shown"
                 : "\(checked.count.formatted()) selected · \(ByteFormat.string(selectedBytes))")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Spacer()
            if !checked.isEmpty {
                Button("Clear selection") { checked.removeAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                Button("Review selected →") {
                    Task { await stageSelected() }
                }
                .buttonStyle(InkButtonStyle(filled: true))
            } else {
                Button("Select visible") {
                    checked = Set(visible.filter(\.isReviewable).map(\.id))
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DiskMapTheme.ink)
                .disabled(visible.allSatisfy { !$0.isReviewable })
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(DiskMapTheme.cardFill)
        .overlay(alignment: .top) { Divider().overlay(DiskMapTheme.cardStroke) }
    }

    private var inspector: some View {
        Group {
            if let c = activeSelection {
                ForgottenInspectorPanel(
                    model: model,
                    candidate: c,
                    onOpenCleanup: onOpenCleanup,
                    onStageOne: { Task { await stageOne(c) } }
                )
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
        guard !items.isEmpty else { return }
        var okCount = 0
        for c in items {
            let url = URL(fileURLWithPath: c.absolutePath).standardizedFileURL
            if model.isStaged(url) { okCount += 1; continue }
            if c.safety.level == .protected { continue }
            let ok = await model.cleanupQueue.stage(
                url,
                size: c.bytes,
                reason: "Forgotten: " + c.confidence.title
            )
            if ok { okCount += 1 }
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
        let ok = await model.cleanupQueue.stage(
            url,
            size: c.bytes,
            reason: "Forgotten: " + c.confidence.title
        )
        await model.refreshQueue()
        if ok {
            model.showToast("Added to cleanup review")
            onOpenCleanup()
        } else {
            model.showToast("Blocked by safety rules")
        }
    }

    private func relativeAge(_ ageDays: Int32) -> String {
        if ageDays < 60 { return "\(ageDays) days ago" }
        if ageDays < 365 {
            let months = max(1, ageDays / 30)
            return months == 1 ? "1 month ago" : "\(months) months ago"
        }
        let years = max(1, ageDays / 365)
        return years == 1 ? "1 year ago" : "\(years) years ago"
    }

    private func kindTint(_ kind: FileKind) -> Color {
        switch kind {
        case .video: return Color(red: 0.55, green: 0.35, blue: 0.85)
        case .diskImage: return Color(red: 0.25, green: 0.45, blue: 0.90)
        case .archive: return Color(red: 0.92, green: 0.50, blue: 0.20)
        case .application: return Color(red: 0.20, green: 0.55, blue: 0.85)
        case .document: return Color(red: 0.85, green: 0.65, blue: 0.15)
        case .virtualDisk: return Color(red: 0.50, green: 0.35, blue: 0.80)
        case .deviceBackup: return Color(red: 0.20, green: 0.65, blue: 0.45)
        case .database: return Color(red: 0.40, green: 0.50, blue: 0.60)
        case .other: return DiskMapTheme.mutedLabel
        }
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
                        Text(candidate.kind.title + " · " + relativeAge(candidate.ageDays))
                            .font(.system(size: 11))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                metaBlock(label: "Location", value: candidate.displayPath)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Why was this flagged?")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                    ForEach(candidate.reasons, id: \.self) { reason in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•")
                                .foregroundStyle(DiskMapTheme.mutedLabel)
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
                    Text(candidate.confidence.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(confidenceColor(candidate.confidence))
                    Text(recommendationCopy)
                        .font(.system(size: 12))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(candidate.safety.level.title + " — " + candidate.safety.reason)
                        .font(.system(size: 11))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 8) {
                    if candidate.isReviewable && candidate.safety.level != .protected {
                        Button("Add to Cleanup") { onStageOne() }
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
                }
                .padding(.top, 4)

                Text("Based primarily on last-modified date. macOS doesn’t always provide a reliable last-opened date.")
                    .font(.system(size: 10))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            .padding(18)
        }
    }

    private var recommendationCopy: String {
        switch candidate.confidence {
        case .likelyForgotten:
            return "This looks like personal data you may have forgotten about. Review before removing — nothing is deleted until you confirm in Cleanup."
        case .worthReviewing:
            return "Worth a careful look. Confirm you recognize it before adding it to Cleanup."
        case .oldImportant:
            return "Although this file is old, DiskMap does not recommend removing it. It appears to belong to macOS, an app, or a development tool."
        }
    }

    private func metaBlock(label: String, value: String) -> some View {
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

    private func confidenceColor(_ c: ForgottenConfidence) -> Color {
        switch c {
        case .likelyForgotten: return DiskMapTheme.safe
        case .worthReviewing: return DiskMapTheme.review
        case .oldImportant: return DiskMapTheme.mutedLabel
        }
    }

    private func relativeAge(_ ageDays: Int32) -> String {
        let years = max(1, ageDays / 365)
        return years == 1 ? "1 year ago" : "\(years) years ago"
    }
}
