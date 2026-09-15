import DiskMapCore
import SwiftUI

/// Home — answer "Why is my Mac full?" in ~5 seconds. Matches DiskMap2 hierarchy.
struct OverviewView: View {
    @ObservedObject var model: ScanModel
    var pickFolder: () -> Void
    var onReviewCleanup: () -> Void
    var onExplain: () -> Void
    var onOpenVisualize: () -> Void
    var onSelectFile: (Int32) -> Void
    var onOpenBiggestFiles: () -> Void = {}

    @State private var showScanReady = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if model.isScanning || model.tree == nil || showScanReady {
                FirstScanHero(
                    model: model,
                    pickFolder: pickFolder,
                    onScanMac: {
                        let home = FileManager.default.homeDirectoryForCurrentUser
                        Task { await model.scan(home) }
                    },
                    showReady: $showScanReady
                )
            } else {
                loaded
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DiskMapTheme.cream)
        .onChange(of: model.isScanning) { wasScanning, nowScanning in
            if wasScanning, !nowScanning, model.tree != nil {
                showScanReady = true
                if reduceMotion {
                    showScanReady = false
                    return
                }
                Task {
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                    await MainActor.run { showScanReady = false }
                }
            }
        }
    }

    private var snap: AnalysisSnapshot { model.analysis }

    private var loaded: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard
                    explainBanner
                    whereGoingCard
                    biggestFilesCard
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 12) {
                    healthCard
                    insightCard
                    findingsCard
                    recoverCard
                }
                .frame(width: 280)
            }
            .padding(20)
        }
    }

    private var headerCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your Mac")
                    .font(DiskMapType.title)
                    .foregroundStyle(DiskMapTheme.ink)
                if let vol = snap.volume {
                    Text("\(ByteFormat.string(Int64(vol.usedBytes))) used of \(ByteFormat.string(Int64(vol.totalBytes)))")
                        .font(DiskMapType.body)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                    HStack(spacing: 10) {
                        Text("\(ByteFormat.string(Int64(vol.freeBytes))) free (\(pct(1 - vol.usedFraction)) available)")
                            .font(DiskMapType.body)
                            .foregroundStyle(DiskMapTheme.ink)
                        if snap.health == .low || snap.health == .critical {
                            Text(snap.health.title)
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .foregroundStyle(DiskMapTheme.danger)
                                .background(Capsule().fill(DiskMapTheme.danger.opacity(0.12)))
                        }
                    }
                    SegmentedStorageBar(segments: categorySegments(total: categorySum))
                        .padding(.top, 4)
                    categoryLegend
                } else {
                    Text("\(ByteFormat.string(snap.scannedBytes)) in this scan")
                        .font(DiskMapType.body)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                    SegmentedStorageBar(segments: categorySegments(total: categorySum))
                    categoryLegend
                }
            }
        }
    }

    private var categoryLegend: some View {
        HStack(spacing: 12) {
            ForEach(snap.categories.prefix(6)) { cat in
                HStack(spacing: 4) {
                    Circle().fill(DiskMapTheme.categoryColor(cat.colorHint)).frame(width: 8, height: 8)
                    Text("\(cat.title) \(ByteFormat.string(cat.bytes))")
                        .font(DiskMapType.caption)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .lineLimit(1)
                }
            }
        }
    }

    private var explainBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .foregroundStyle(DiskMapTheme.developer)
            VStack(alignment: .leading, spacing: 4) {
                Text("Not sure where to start?")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white)
                Text("Diskmap can explain what's taking up space and point you toward things worth reviewing.")
                    .font(DiskMapType.caption)
                    .foregroundStyle(Color.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Explain my storage →", action: onExplain)
                .buttonStyle(InkButtonStyle(filled: false))
                .colorScheme(.dark)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.18, green: 0.18, blue: 0.22))
        )
    }

    private var whereGoingCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Where is your storage going?")
                        .font(DiskMapType.section)
                        .foregroundStyle(DiskMapTheme.ink)
                    Spacer()
                }
                ForEach(snap.categories) { cat in
                    let denom = categorySum
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DiskMapTheme.categoryColor(cat.colorHint).opacity(0.2))
                            .frame(width: 28, height: 28)
                            .overlay(
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(DiskMapTheme.categoryColor(cat.colorHint))
                            )
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(cat.title).font(.system(size: 13, weight: .medium)).foregroundStyle(DiskMapTheme.ink)
                                Spacer()
                                Text(ByteFormat.string(cat.bytes))
                                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(DiskMapTheme.ink)
                            }
                            ProportionBar(fraction: Double(cat.bytes) / Double(denom), tint: DiskMapTheme.categoryColor(cat.colorHint))
                        }
                        Text(pct(Double(cat.bytes) / Double(denom)))
                            .font(DiskMapType.caption)
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Button("View in Visualizations →", action: onOpenVisualize)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.info)
                    .padding(.top, 4)
            }
        }
    }

    private var biggestFilesCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Biggest files")
                        .font(DiskMapType.section)
                        .foregroundStyle(DiskMapTheme.ink)
                    Spacer()
                    Button("View all →", action: onOpenBiggestFiles)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.info)
                }
                ForEach(snap.topFiles.prefix(5)) { file in
                    Button {
                        onSelectFile(file.nodeID)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.fill")
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(DiskMapTheme.ink)
                                    .lineLimit(1)
                                Text(file.relativePath)
                                    .font(DiskMapType.caption)
                                    .foregroundStyle(DiskMapTheme.mutedLabel)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(ByteFormat.string(file.bytes))
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(DiskMapTheme.ink)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var healthCard: some View {
        PanelCard {
            VStack(spacing: 10) {
                Text("Storage Health")
                    .font(DiskMapType.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ZStack {
                    Circle()
                        .stroke(DiskMapTheme.cardStroke, lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: snap.volume?.usedFraction ?? 0)
                        .stroke(healthColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 2) {
                        Text(pct(snap.volume?.usedFraction ?? 0))
                            .font(.system(size: 14, weight: .semibold).monospacedDigit())
                            .foregroundStyle(DiskMapTheme.ink)
                    }
                }
                .frame(width: 72, height: 72)
                .frame(maxWidth: .infinity)
                if let vol = snap.volume {
                    Text("\(ByteFormat.string(Int64(vol.freeBytes))) free")
                        .font(DiskMapType.body)
                        .foregroundStyle(DiskMapTheme.ink)
                }
                Text(snap.health.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(healthColor)
            }
        }
    }

    private var insightCard: some View {
        let top = StorageNarrator.recommendations(from: snap).first
        return PanelCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Quick insight")
                    .font(DiskMapType.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                if let top {
                    Text(top.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                    Text("\(top.detail) · \(ByteFormat.string(top.bytes))")
                        .font(DiskMapType.body)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("You have \(ByteFormat.string(snap.reviewableBytes)) worth of files that may be worth reviewing.")
                        .font(DiskMapType.body)
                        .foregroundStyle(DiskMapTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Review cleanup →", action: onReviewCleanup)
                    .buttonStyle(PrimaryCTAStyle())
                    .padding(.top, 4)
            }
        }
    }

    private var findingsCard: some View {
        let stories = StorageNarrator.stories(from: snap, limit: 3)
        return PanelCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Worth looking at")
                    .font(DiskMapType.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                if stories.isEmpty {
                    ForEach(snap.categories.prefix(3)) { cat in
                        HStack {
                            Text(cat.title).font(DiskMapType.body).foregroundStyle(DiskMapTheme.ink)
                            Spacer()
                            Text(ByteFormat.string(cat.bytes))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                        }
                    }
                } else {
                    ForEach(stories) { story in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(story.title)
                                    .font(DiskMapType.body)
                                    .foregroundStyle(DiskMapTheme.ink)
                                    .lineLimit(1)
                                Spacer()
                                Text(ByteFormat.string(story.bytes))
                                    .font(.system(size: 12).monospacedDigit())
                                    .foregroundStyle(DiskMapTheme.mutedLabel)
                            }
                            Text(story.detail)
                                .font(DiskMapType.caption)
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private var recoverCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "leaf.fill")
                .foregroundStyle(DiskMapTheme.safe)
            VStack(alignment: .leading, spacing: 2) {
                Text("Potential reclaimable space")
                    .font(DiskMapType.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                Text("~" + ByteFormat.string(snap.reviewableBytes))
                    .font(.system(size: 18, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DiskMapTheme.safe)
                Text("Estimated — review before deleting.")
                    .font(.system(size: 10))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DiskMapTheme.safe.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(DiskMapTheme.safe.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private var healthColor: Color {
        switch snap.health {
        case .healthy: return DiskMapTheme.safe
        case .tight: return DiskMapTheme.review
        case .low, .critical: return DiskMapTheme.danger
        }
    }

    private var categorySum: Int64 {
        max(1, snap.categories.reduce(Int64(0)) { $0 + $1.bytes })
    }

    private func categorySegments(total: Int64) -> [(color: Color, fraction: Double)] {
        let t = max(1, total)
        return snap.categories.map { cat in
            (DiskMapTheme.categoryColor(cat.colorHint), Double(cat.bytes) / Double(t))
        }
    }

    private func pct(_ f: Double) -> String {
        String(format: "%.0f%%", min(100, max(0, f * 100)))
    }
}
