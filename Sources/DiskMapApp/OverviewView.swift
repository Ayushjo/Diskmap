import DiskMapCore
import SwiftUI

/// Home — answer "Why is my Mac full?" in ~5 seconds: one reading column,
/// every figure once.
struct OverviewView: View {
    @ObservedObject var model: ScanModel
    var pickFolder: () -> Void
    var onReviewCleanup: () -> Void
    var onExplain: () -> Void
    var onOpenVisualize: () -> Void
    var onSelectFile: (Int32) -> Void
    var onOpenBiggestFiles: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showWhy = false

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
        .background(DiskMapTheme.canvas)
    }

    private var snap: AnalysisSnapshot { model.analysis }

    private var loaded: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DiskMapSpace.xl) {
                hero
                unreadableNotice
                whereGoing
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: DiskMapSpace.xl) {
                        worthReviewing.frame(maxWidth: .infinity, alignment: .topLeading)
                        sideList.frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(minWidth: 640)
                    VStack(alignment: .leading, spacing: DiskMapSpace.xl) {
                        worthReviewing
                        sideList
                    }
                }
                footer
            }
            .frame(maxWidth: DiskMapMetric.readingWidth, alignment: .leading)
            .padding(.horizontal, DiskMapSpace.page)
            .padding(.top, DiskMapSpace.pageTop + 8)
            .padding(.bottom, DiskMapSpace.xl)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: DiskMapSpace.sm) {
            if let vol = snap.volume {
                MonoLabel(vol.volumeName.uppercased())
                Text("\(ByteFormat.string(Int64(vol.freeBytes))) free")
                    .font(DiskMapType.display)
                    .foregroundStyle(DiskMapTheme.ink)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .accessibilityIdentifier("overview-free")
                HStack(spacing: DiskMapSpace.sm) {
                    Text("of \(ByteFormat.string(Int64(vol.totalBytes)))  ·  \(pct(vol.usedFraction)) used")
                        .font(DiskMapType.figure)
                        .foregroundStyle(DiskMapTheme.ink2)
                    if snap.health != .healthy {
                        SafetyLabel(level: nil, title: snap.health.title, tint: healthColor)
                    }
                }
                ProportionBar(fraction: vol.usedFraction,
                              tint: snap.health == .healthy ? DiskMapTheme.ink.opacity(0.55) : healthColor,
                              height: 6)
                    .frame(maxWidth: 520)
                    .padding(.vertical, 4)
                    .accessibilityHidden(true)
            } else {
                MonoLabel((model.rootURL?.lastPathComponent ?? "This scan").uppercased())
                Text(ByteFormat.string(snap.scannedBytes))
                    .font(DiskMapType.display)
                    .foregroundStyle(DiskMapTheme.ink)
                    .contentTransition(reduceMotion ? .identity : .numericText())
            }
            coverageLine
        }
    }

    /// One line on what the scan covers, with the causes behind "Why?".
    private var coverageLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: DiskMapSpace.xs) {
            Text(coverageText)
                .font(DiskMapType.secondary)
                .foregroundStyle(DiskMapTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("volume-reconciliation")
            if hasWhyDetail {
                Button("Why?") { showWhy.toggle() }
                    .buttonStyle(LinkButtonStyle())
                    .font(DiskMapType.secondary)
                    .popover(isPresented: $showWhy, arrowEdge: .bottom) { whyPopover }
                    .accessibilityHint("Explains the gap between this scan and the disk")
            }
        }
    }

    private var coverageText: String {
        if let rec = snap.reconciliation { return reconciliationHeadline(rec) }
        return "\(ByteFormat.string(snap.scannedBytes)) found in this scan."
    }

    private var hasWhyDetail: Bool {
        if let rec = snap.reconciliation, reconciliationDetail(rec) != nil { return true }
        if snap.hasSharingInfo { return Self.cloneText(snap.sharingCorrection) != nil }
        return model.rootURL.map { StorageSharing.isAPFS($0.path) } == true
    }

    private var whyPopover: some View {
        VStack(alignment: .leading, spacing: DiskMapSpace.md) {
            MonoLabel("Why the numbers differ")
            if let rec = snap.reconciliation, let detail = reconciliationDetail(rec) {
                Text(detail)
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            cloneNote
        }
        .padding(DiskMapSpace.lg)
        .frame(width: 340, alignment: .leading)
        .background(DiskMapTheme.raised)
    }

    /// TASK-077: what counting each clone family once changed — or, when it
    /// is off on an APFS volume, that clones may be counted more than once.
    @ViewBuilder
    private var cloneNote: some View {
        if snap.hasSharingInfo {
            if let text = Self.cloneText(snap.sharingCorrection) {
                Text(text)
                    .font(DiskMapType.secondary)
                    .foregroundStyle(DiskMapTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("clone-accounting")
            }
        } else if model.rootURL.map({ StorageSharing.isAPFS($0.path) }) == true {
            VStack(alignment: .leading, spacing: 6) {
                Text("Cloned files are counted once per copy, so these totals can be higher than the disk really uses.")
                    .font(DiskMapType.secondary)
                    .foregroundStyle(DiskMapTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsLink { Text("Count clones once…") }
                    .buttonStyle(LinkButtonStyle())
                    .font(DiskMapType.secondary)
            }
            .accessibilityIdentifier("clone-accounting-off")
        }
    }

    /// TASK-039: say when the totals are short because folders were unreadable.
    @ViewBuilder
    private var unreadableNotice: some View {
        let count = model.deniedDirectoryIDs.count
        if count > 0 {
            DiskMapNoticeBanner(
                symbol: "lock",
                tint: DiskMapTheme.review,
                title: "\(count.formatted()) folder\(count == 1 ? "" : "s") couldn’t be read",
                detail: "Totals are missing whatever \(count == 1 ? "it holds" : "they hold"). Grant Full Disk Access, then rescan.",
                examples: model.deniedDirectoryExamples(),
                actionTitle: "Grant access",
                action: { model.openFullDiskAccessSettings() }
            )
            .accessibilityIdentifier("unreadable-folders-notice")
        }
    }

    // MARK: Where it's going

    private var whereGoing: some View {
        VStack(alignment: .leading, spacing: DiskMapSpace.md) {
            SectionHeader(label: snap.categoryMode == .folder ? "What’s in this folder" : "Where it’s going",
                          detail: snap.categoryMode == .folder ? "by file type" : nil) {
                Button("Open in Visualize →", action: onOpenVisualize)
                    .buttonStyle(LinkButtonStyle())
                    .font(DiskMapType.secondary)
            }
            SegmentedStorageBar(segments: categorySegments(total: categorySum))
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                ForEach(snap.categories) { cat in
                    CategoryRow(title: cat.title, bytes: cat.bytes,
                                fraction: Double(cat.bytes) / Double(categorySum),
                                tint: color(of: cat), help: openHelp(cat)) { open(cat) }
                }
            }
        }
    }

    // MARK: Worth reviewing

    private struct ReviewItem: Identifiable {
        var id: String
        var title: String
        var detail: String
        var bytes: Int64?
        var level: SafetyLevel
        var open: () -> Void
    }

    private var reviewItems: [ReviewItem] {
        var items: [ReviewItem] = StorageNarrator.recommendations(from: snap).map { rec in
            let dest = rec.destination
            return ReviewItem(id: rec.id, title: rec.title, detail: rec.detail, bytes: rec.bytes,
                              level: rec.safety) { [model] in model.destination = dest }
        }
        if model.duplicateDidRun, !model.duplicateGroups.isEmpty {
            let groups = model.duplicateGroups.count
            items.append(ReviewItem(id: "rec-duplicates", title: "Review duplicates",
                                    detail: "\(groups) group\(groups == 1 ? "" : "s") of identical files.",
                                    bytes: nil, level: .review) { [model] in
                model.destination = .duplicates
                model.topNav = .duplicates
            })
        }
        return items
    }

    private var worthReviewing: some View {
        VStack(alignment: .leading, spacing: DiskMapSpace.sm) {
            SectionHeader(label: "Worth reviewing",
                          detail: snap.reviewableBytes > 0 ? "~" + ByteFormat.string(snap.reviewableBytes) : nil) {
                Button("Explain my storage", action: onExplain)
                    .buttonStyle(LinkButtonStyle())
                    .font(DiskMapType.secondary)
            }
            let items = reviewItems
            if items.isEmpty {
                Text("Nothing stands out. Your biggest folders are on the left of Visualize.")
                    .font(DiskMapType.secondary)
                    .foregroundStyle(DiskMapTheme.ink3)
                    .padding(.vertical, DiskMapSpace.xs)
            }
            VStack(spacing: 0) {
                ForEach(items) { item in
                    LinkRow(title: item.title, subtitle: item.detail,
                            figure: item.bytes.map(ByteFormat.string), subtitleTruncation: .tail,
                            action: item.open) {
                        Circle()
                            .fill(item.level == .safe ? DiskMapTheme.safe : DiskMapTheme.review)
                            .frame(width: 6, height: 6)
                            .frame(width: 14)
                    }
                }
            }
        }
        .accessibilityIdentifier("worth-reviewing")
    }

    // MARK: What grew / biggest files

    @ViewBuilder
    private var sideList: some View {
        if let comparison = model.weekComparison {
            growth(comparison)
        } else {
            biggestFiles
        }
    }

    /// TASK-079: what grew since about a week ago, from the scan history.
    private func growth(_ comparison: StorageHistory.Comparison) -> some View {
        VStack(alignment: .leading, spacing: DiskMapSpace.sm) {
            SectionHeader(label: comparison.isWeek ? "What grew this week"
                          : "Since \(comparison.since.formatted(date: .abbreviated, time: .omitted))",
                          detail: Self.freeDeltaShort(comparison.freeDelta))
            if comparison.growers.isEmpty {
                Text("No folder grew by more than 100 MB.")
                    .font(DiskMapType.secondary)
                    .foregroundStyle(DiskMapTheme.ink3)
                    .padding(.vertical, DiskMapSpace.xs)
            }
            VStack(spacing: 0) {
                ForEach(comparison.growers, id: \.path) { growth in
                    LinkRow(title: URL(fileURLWithPath: growth.path).lastPathComponent,
                            subtitle: growth.path,
                            figure: "+" + ByteFormat.string(growth.delta),
                            action: { openGrown(growth.path) }) {
                        Image(systemName: "folder")
                            .font(.system(size: DiskMapType.scaled(12)))
                            .foregroundStyle(DiskMapTheme.ink3)
                            .frame(width: 14)
                    }
                    .help("Open in File Browser · \(ByteFormat.string(growth.before)) → \(ByteFormat.string(growth.after))")
                    .accessibilityLabel("\(growth.path) grew \(ByteFormat.string(growth.delta))")
                }
            }
            if comparison.deniedChanged {
                Text("Some folders were readable in one scan and not the other, so small changes may be the reading, not the disk.")
                    .font(DiskMapType.secondary)
                    .foregroundStyle(DiskMapTheme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("growth-card")
    }

    static func freeDeltaShort(_ delta: Int64) -> String {
        if abs(delta) < growthNoise { return "free space unchanged" }
        return delta < 0 ? "−\(ByteFormat.string(-delta)) free" : "+\(ByteFormat.string(delta)) free"
    }

    private var biggestFiles: some View {
        VStack(alignment: .leading, spacing: DiskMapSpace.sm) {
            SectionHeader(label: "Biggest files") {
                Button("View all →", action: onOpenBiggestFiles)
                    .buttonStyle(LinkButtonStyle())
                    .font(DiskMapType.secondary)
            }
            VStack(spacing: 0) {
                ForEach(snap.topFiles.prefix(5)) { file in
                    let root = model.rootURL ?? URL(fileURLWithPath: "/")
                    let abs = file.relativePath.hasPrefix("/") ? file.relativePath : root.appendingPathComponent(file.relativePath).path
                    let url = URL(fileURLWithPath: abs)
                    LinkRow(title: file.name, subtitle: relativeParent(of: abs, root: root),
                            figure: ByteFormat.string(file.bytes), action: { onSelectFile(file.nodeID) }) {
                        FileIdentityIcon(url: url, size: 20)
                    }
                }
            }
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if let kind = model.lastScanKind {
            HStack(alignment: .firstTextBaseline, spacing: DiskMapSpace.xs) {
                Text(Self.scanKindText(kind))
                    .font(DiskMapType.figureSmall)
                    .foregroundStyle(DiskMapTheme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                if case .quick = kind, let root = model.rootURL {
                    Button("Full Rescan") { Task { await model.scan(root, mode: .full) } }
                        .buttonStyle(LinkButtonStyle())
                        .font(DiskMapType.figureSmall)
                        .disabled(model.isScanning)
                }
            }
            .padding(.top, DiskMapSpace.xs)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("scan-kind")
        }
    }

    // MARK: Helpers

    private var healthColor: Color {
        switch snap.health {
        case .healthy: return DiskMapTheme.safe
        case .tight: return DiskMapTheme.review
        case .low, .critical: return DiskMapTheme.danger
        }
    }

    static let growthNoise: Int64 = 50_000_000

    static func freeDeltaText(_ delta: Int64) -> String {
        if abs(delta) < growthNoise { return "Free space is about the same." }
        return delta < 0 ? "\(ByteFormat.string(-delta)) less free space." : "\(ByteFormat.string(delta)) more free space."
    }

    private func openGrown(_ relativePath: String) {
        guard let tree = model.tree, let root = model.rootURL,
              case .found(let id) = FileQuery.node(atPath: root.path + "/" + relativePath, tree: tree, rootPath: root.path) else { return }
        model.currentNode = id
        model.selectedNode = id
        model.destination = .fileBrowser
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

/// A storage category: dot, name, a 3 pt bar, mono size and share.
private struct CategoryRow: View {
    var title: String
    var bytes: Int64
    var fraction: Double
    var tint: Color
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DiskMapSpace.sm) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(title)
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.ink)
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)
                ProportionBar(fraction: fraction, tint: tint)
                    .frame(maxWidth: .infinity)
                MonoColumn(text: ByteFormat.string(bytes), width: 76, emphasis: true)
                MonoColumn(text: Self.percent(fraction), width: 40)
            }
            .padding(.horizontal, 10)
            .frame(height: DiskMapSpace.row)
            .background(RowBackground(selected: false, hovering: hovering))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, -10)
        .help(help)
        .accessibilityLabel("\(title), \(ByteFormat.string(bytes)), \(Self.percent(fraction))")
        .accessibilityHint(help)
    }

    static func percent(_ f: Double) -> String {
        if f > 0 && f < 0.005 { return "<1%" }
        return String(format: "%.0f%%", min(100, max(0, f * 100)))
    }
}

/// A row that goes somewhere: leading mark, name over detail, mono figure, chevron.
private struct LinkRow<Leading: View>: View {
    var title: String
    var subtitle: String?
    var figure: String?
    var subtitleTruncation: Text.TruncationMode = .middle
    var action: () -> Void
    @ViewBuilder var leading: Leading
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DiskMapSpace.sm) {
                leading
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DiskMapType.bodyEmphasis)
                        .foregroundStyle(DiskMapTheme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(DiskMapType.secondary)
                            .foregroundStyle(DiskMapTheme.ink3)
                            .lineLimit(1)
                            .truncationMode(subtitleTruncation)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let figure {
                    Text(figure)
                        .font(DiskMapType.figure)
                        .foregroundStyle(DiskMapTheme.ink)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: DiskMapType.scaled(10), weight: .semibold))
                    .foregroundStyle(hovering ? DiskMapTheme.ink2 : DiskMapTheme.ink3.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .frame(minHeight: DiskMapSpace.rowTwoLine + 4)
            .background(RowBackground(selected: false, hovering: hovering))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, -10)
    }
}

extension StorageRecommendation {
    /// The page that reviews this recommendation (Overview and Explain).
    var destination: AppDestination {
        switch id {
        case "rec-quickwins": return .cleanSafe
        case "rec-downloads": return .cleanDownloads
        case "rec-forgotten": return .forgottenFiles
        case "rec-caches": return .cleanCaches
        default: return .cleanMedia
        }
    }
}
