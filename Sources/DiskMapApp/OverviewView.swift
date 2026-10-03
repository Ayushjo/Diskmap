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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if model.tree == nil {
                FirstScanHero(
                    model: model,
                    pickFolder: pickFolder,
                    onScanMac: {
                        let home = FileManager.default.homeDirectoryForCurrentUser
                        Task { await model.scan(home) }
                    }
                )
            } else {
                loaded
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DiskMapTheme.cream)
    }

    private var snap: AnalysisSnapshot { model.analysis }

    private var loaded: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard
                    unreadableNotice
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
                                .font(DiskMapType.captionStrong)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .foregroundStyle(DiskMapTheme.danger)
                                .background(Capsule().fill(DiskMapTheme.danger.opacity(0.12)))
                        }
                    }
                    if let reconciliation = snap.reconciliation {
                        reconciliationRow(reconciliation)
                    }
                    cloneRow
                    SegmentedStorageBar(segments: categorySegments(total: categorySum))
                        .padding(.top, 4)
                    categoryLegend
                    scanKindRow
                } else {
                    Text("\(ByteFormat.string(snap.scannedBytes)) in this scan")
                        .font(DiskMapType.body)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                    SegmentedStorageBar(segments: categorySegments(total: categorySum))
                    categoryLegend
                    scanKindRow
                }
            }
        }
    }

    /// TASK-077: what counting each clone family once changed — or, when it
    /// is off on an APFS volume, that clones may be counted more than once.
    @ViewBuilder
    private var cloneRow: some View {
        let correction = snap.sharingCorrection
        if snap.hasSharingInfo {
            if let text = Self.cloneText(correction) {
                Label {
                    Text(text)
                        .font(DiskMapType.caption)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "square.on.square")
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("clone-accounting")
            }
        } else if model.rootURL.map({ StorageSharing.isAPFS($0.path) }) == true {
            HStack(spacing: 8) {
                Image(systemName: "square.on.square")
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .accessibilityHidden(true)
                Text("Cloned files are counted once per copy, so these totals can be higher than the disk really uses.")
                    .font(DiskMapType.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsLink {
                    Text("Count clones once…")
                }
                .buttonStyle(.link)
                .font(DiskMapType.captionStrong)
            }
            .accessibilityIdentifier("clone-accounting-off")
        }
    }

    static func cloneText(_ correction: FileTree.SharingCorrection) -> String? {
        var parts: [String] = []
        if correction.cloneCount > 0 {
            parts.append("\(correction.cloneCount.formatted()) cloned cop\(correction.cloneCount == 1 ? "y" : "ies") in \(correction.familyCount.formatted()) group\(correction.familyCount == 1 ? "" : "s") share \(ByteFormat.string(correction.bytes)) with their originals — counted once.")
        }
        if correction.partialCount > 0 {
            parts.append("\(ByteFormat.string(correction.partialSharedBytes)) in \(correction.partialCount.formatted()) edited cop\(correction.partialCount == 1 ? "y" : "ies") is shared with files DiskMap can’t name, and counted in full.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// TASK-061: say whether these numbers come from a full walk or a quick
    /// update of the last one, and offer the full walk.
    @ViewBuilder
    private var scanKindRow: some View {
        if let kind = model.lastScanKind {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .accessibilityHidden(true)
                Text(Self.scanKindText(kind))
                    .font(DiskMapType.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
                if case .quick = kind, let root = model.rootURL {
                    Button("Full Rescan") { Task { await model.scan(root, mode: .full) } }
                        .buttonStyle(.link)
                        .font(DiskMapType.captionStrong)
                        .disabled(model.isScanning)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("scan-kind")
        }
    }

    static func scanKindText(_ kind: ScanModel.ScanKind) -> String {
        switch kind {
        case let .quick(seconds, changed, walked):
            if changed == 0 && walked == 0 {
                return "Updated from your last scan in \(String(format: "%.1f", seconds)) s — nothing changed; a sample of folders was re-read to confirm."
            }
            let walkedText = walked > 0 ? ", \(walked) new folder\(walked == 1 ? "" : "s") walked" : ""
            return "Updated from your last scan in \(String(format: "%.1f", seconds)) s — "
                + "\(changed) changed folder\(changed == 1 ? "" : "s") re-read\(walkedText), unchanged ones spot-checked."
        case let .full(seconds, reason):
            let base = "Full scan in \(String(format: "%.1f", seconds)) s."
            return reason.map { base + " (Walked in full: \($0).)" } ?? base
        }
    }

    /// TASK-040: the gap between "used" and what the scan found is the most
    /// common "where did my disk go?" confusion. Name every cause that can
    /// apply rather than implying there is one.
    private func reconciliationRow(_ rec: AnalysisSnapshot.VolumeReconciliation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(reconciliationHeadline(rec))
                .font(DiskMapType.body)
                .foregroundStyle(DiskMapTheme.ink)
            if let detail = reconciliationDetail(rec) {
                Text(detail)
                    .font(DiskMapType.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("volume-reconciliation")
    }

    private func reconciliationHeadline(_ rec: AnalysisSnapshot.VolumeReconciliation) -> String {
        let scanned = ByteFormat.string(rec.scannedBytes)
        let used = ByteFormat.string(rec.usedBytes)
        if rec.scannedExceedsUsed {
            return "This scan found \(scanned), more than the \(used) in use."
        }
        if rec.coverageFraction >= 0.98 {
            return "This scan accounts for all \(used) in use."
        }
        return "This scan accounts for \(scanned) of the \(used) in use."
    }

    private func reconciliationDetail(_ rec: AnalysisSnapshot.VolumeReconciliation) -> String? {
        if rec.scannedExceedsUsed {
            return "Cloned files share the same blocks on disk but are listed once per copy, so the scan total can exceed what is actually used."
        }
        guard rec.coverageFraction < 0.98 else { return nil }
        var causes: [String] = []
        if snap.scanRootPath != "/" {
            let display = CanonicalPath.displayPath(absolutePath: snap.scanRootPath)
            let place = display == "~"
                ? "your home folder"
                : "“\(URL(fileURLWithPath: snap.scanRootPath).lastPathComponent)”"
            causes.append("outside \(place) (macOS, apps and other users)")
        }
        causes.append("held by local Time Machine snapshots or purgeable space")
        let denied = model.deniedDirectoryIDs.count
        if denied > 0 {
            causes.append("inside \(denied.formatted()) folder\(denied == 1 ? "" : "s") DiskMap couldn’t read")
        }
        let list = causes.count > 1
            ? causes.dropLast().joined(separator: ", ") + ", or " + (causes.last ?? "")
            : causes.first ?? ""
        return "The other \(ByteFormat.string(rec.unaccountedBytes)) is \(list)."
    }

    /// TASK-039: say when the totals are short because folders were unreadable.
    @ViewBuilder
    private var unreadableNotice: some View {
        let count = model.deniedDirectoryIDs.count
        if count > 0 {
            DiskMapNoticeBanner(
                symbol: "lock.trianglebadge.exclamationmark",
                tint: DiskMapTheme.review,
                title: "\(count.formatted()) folder\(count == 1 ? "" : "s") couldn’t be read",
                detail: "DiskMap doesn’t have permission to open \(count == 1 ? "it" : "them"), so every size above \(count == 1 ? "it" : "them") is missing whatever \(count == 1 ? "it holds" : "they hold"). Grant Full Disk Access, then rescan, for complete numbers.",
                examples: model.deniedDirectoryExamples(),
                actionTitle: "Open Full Disk Access Settings",
                action: { model.openFullDiskAccessSettings() }
            )
            .accessibilityIdentifier("unreadable-folders-notice")
        }
    }

    private var categoryLegend: some View {
        HStack(spacing: 12) {
            ForEach(snap.categories.prefix(6)) { cat in
                HStack(spacing: 4) {
                    Circle().fill(color(of: cat)).frame(width: 8, height: 8)
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
                    .font(DiskMapType.callout)
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
                .fill(DiskMapTheme.inverseSurface)
        )
    }

    private var whereGoingTitle: String {
        guard snap.categoryMode == .folder else { return "Where is your storage going?" }
        let name = model.rootURL?.lastPathComponent ?? ""
        return name.isEmpty ? "What’s in this folder?" : "What’s in \(name)?"
    }

    private var whereGoingCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(whereGoingTitle)
                        .font(DiskMapType.section)
                        .foregroundStyle(DiskMapTheme.ink)
                    Spacer()
                }
                if snap.categoryMode == .folder {
                    Text("By file type — folder names only mean something at the top of a home folder or a disk.")
                        .font(DiskMapType.caption)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(snap.categories) { cat in
                    categoryRow(cat)
                }
                Button("View in Visualizations →", action: onOpenVisualize)
                    .buttonStyle(.plain)
                    .font(DiskMapType.smallStrong)
                    .foregroundStyle(DiskMapTheme.info)
                    .padding(.top, 4)
            }
        }
    }

    private func categoryRow(_ cat: StorageCategory) -> some View {
        let denom = categorySum
        let tint = color(of: cat)
        return Button { open(cat) } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.2))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: cat.fileKind != nil ? "doc.fill" : "folder.fill")
                            .font(DiskMapType.small)
                            .foregroundStyle(tint)
                    )
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(cat.title).font(DiskMapType.bodyMedium).foregroundStyle(DiskMapTheme.ink)
                        Spacer()
                        Text(ByteFormat.string(cat.bytes))
                            .font(DiskMapType.bodyStrong.monospacedDigit())
                            .foregroundStyle(DiskMapTheme.ink)
                    }
                    ProportionBar(fraction: Double(cat.bytes) / Double(denom), tint: tint)
                }
                Text(pct(Double(cat.bytes) / Double(denom)))
                    .font(DiskMapType.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .frame(width: 40, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(openHelp(cat))
        .accessibilityLabel("\(cat.title), \(ByteFormat.string(cat.bytes)), \(pct(Double(cat.bytes) / Double(denom)))")
        .accessibilityHint(openHelp(cat))
    }

    /// A file type opens Find on that kind; "Other" opens Biggest Files; a
    /// folder category opens Visualize at its folder.
    private func open(_ cat: StorageCategory) {
        if let kind = cat.fileKind {
            model.findQuery = "kind:\(kind)"
            model.destination = .find
        } else if let node = cat.nodeID {
            model.currentNode = node
            model.selectedNode = node
            onOpenVisualize()
        } else {
            onOpenBiggestFiles()
        }
    }

    private func openHelp(_ cat: StorageCategory) -> String {
        if cat.fileKind != nil { return "List every \(cat.title.lowercased()) file in Find" }
        return cat.nodeID != nil ? "Show this folder in Visualize" : "Show the biggest files"
    }

    private func color(of cat: StorageCategory) -> Color {
        cat.colorHex.map(DiskMapTheme.hex) ?? DiskMapTheme.categoryColor(cat.colorHint)
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
                        .font(DiskMapType.smallStrong)
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
                                    .font(DiskMapType.bodyMedium)
                                    .foregroundStyle(DiskMapTheme.ink)
                                    .lineLimit(1)
                                Text(file.relativePath)
                                    .font(DiskMapType.caption)
                                    .foregroundStyle(DiskMapTheme.mutedLabel)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(ByteFormat.string(file.bytes))
                                .font(DiskMapType.smallStrong.monospacedDigit())
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
                        .stroke(DiskMapTheme.cardStroke, lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: snap.volume?.usedFraction ?? 0)
                        .stroke(healthColor, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 2) {
                        Text(pct(snap.volume?.usedFraction ?? 0))
                            .font(DiskMapType.callout.monospacedDigit())
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
                    .font(DiskMapType.smallStrong)
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
                        .font(DiskMapType.callout)
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
                                .font(DiskMapType.small.monospacedDigit())
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
                                    .font(DiskMapType.small.monospacedDigit())
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
                    .font(DiskMapType.micro)
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
            (color(of: cat), Double(cat.bytes) / Double(t))
        }
    }

    private func pct(_ f: Double) -> String {
        if f > 0 && f < 0.005 { return "<1%" }
        return String(format: "%.0f%%", min(100, max(0, f * 100)))
    }
}
