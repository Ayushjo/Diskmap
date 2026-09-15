import AppKit
import DiskMapCore
import SwiftUI

/// Clean → Old Downloads: curated review of large/older Downloads files.
struct OldDownloadsView: View {
    @ObservedObject var model: ScanModel
    @Environment(\.diskMapContentWidth) private var contentWidth
    var onOpenCleanup: () -> Void
    var pickFolder: () -> Void

    @State private var selectedID: Int32?
    @State private var checked: Set<Int32> = []
    @State private var query = ""
    @State private var ageFilter: OldDownloadsAgeFilter = .days30
    @State private var sizeFilter: OldDownloadsSizeFilter = .any
    @State private var typeFilter: OldDownloadsTypeFilter = .all
    @State private var sort: OldDownloadsSort = .largest

    private var catalog: OldDownloadsCatalogResult { model.cachedOldDownloads }
    private var summary: OldDownloadsSummary { catalog.summary }

    private var visible: [OldDownloadsCandidate] {
        let filtered = OldDownloadsCatalog.filter(
            catalog.candidates,
            age: ageFilter,
            size: sizeFilter,
            type: typeFilter,
            query: query
        )
        return OldDownloadsCatalog.sorted(filtered, by: sort)
    }

    private var active: OldDownloadsCandidate? {
        if let selectedID, let hit = visible.first(where: { $0.nodeID == selectedID })
            ?? catalog.candidates.first(where: { $0.nodeID == selectedID }) {
            return hit
        }
        return visible.first
    }

    private var checkedItems: [OldDownloadsCandidate] {
        catalog.candidates.filter { checked.contains($0.nodeID) }
    }

    private var checkedBytes: Int64 {
        checkedItems.reduce(Int64(0)) { $0 + $1.bytes }
    }

    var body: some View {
        Group {
            if model.tree == nil {
                emptyScan
            } else {
                HStack(spacing: 0) {
                    mainColumn
                    Divider().overlay(DiskMapTheme.cardStroke)
                    inspector
                        .frame(width: DiskMapLayout.inspectorWidth(for: contentWidth))
                }
            }
        }
        .background(DiskMapTheme.cream)
        .task {
            if model.cachedOldDownloads.candidates.isEmpty, model.tree != nil {
                model.refreshOldDownloadsCache()
            }
            if selectedID == nil { selectedID = visible.first?.nodeID }
        }
    }

    private var emptyScan: some View {
        VStack(spacing: 12) {
            Text("Scan to find older files in Downloads.")
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Button("Choose Folder…", action: pickFolder).buttonStyle(InkButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    summaryCards
                    insightRow
                    filters
                    tableHeader
                    if model.isScanning {
                        ProgressView("Analyzing Downloads…")
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else if visible.isEmpty {
                        emptyResults
                    } else {
                        fileRows
                    }
                }
                .padding(20)
            }
            if !checked.isEmpty {
                selectionBar
            } else {
                footerBar
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(DiskMapTheme.info)
                .frame(width: 48, height: 48)
                .background(DiskMapTheme.info.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text("Old Downloads")
                    .font(DiskMapType.title)
                    .foregroundStyle(DiskMapTheme.ink)
                Text("Large or older files in Downloads that may no longer be needed. Review them before deciding what to do. Nothing is deleted automatically.")
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var summaryCards: some View {
        HStack(spacing: 10) {
            metricCard(icon: "folder.fill", tint: DiskMapTheme.info,
                       value: ByteFormat.string(summary.totalBytes),
                       title: "Old downloads",
                       subtitle: "all candidates · \(summary.totalCount) files")
            metricCard(icon: "calendar", tint: DiskMapTheme.danger,
                       value: ByteFormat.string(summary.bytes30),
                       title: "30+ days old",
                       subtitle: "in \(summary.count30) files")
            metricCard(icon: "calendar", tint: DiskMapTheme.review,
                       value: ByteFormat.string(summary.bytes90),
                       title: "90+ days old",
                       subtitle: "in \(summary.count90) files")
            metricCard(icon: "doc.text", tint: DiskMapTheme.developer,
                       value: "\(summary.reviewCount)",
                       title: "Worth reviewing",
                       subtitle: "(> 1 MB)")
        }
    }

    private func metricCard(icon: String, tint: Color, value: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DiskMapTheme.ink)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.ink)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBG)
    }

    private var insightRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "leaf.fill")
                        .foregroundStyle(DiskMapTheme.safe)
                    Text("Insights")
                        .font(.system(size: 12, weight: .semibold))
                }
                ForEach(summary.insightLines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundStyle(DiskMapTheme.ink.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Review files (\(visible.count))") {
                        checked = Set(visible.prefix(24).map(\.nodeID))
                    }
                    .buttonStyle(PrimaryCTAStyle())
                    Button("Reveal Downloads in Finder") {
                        revealDownloads()
                    }
                    .buttonStyle(InkButtonStyle(filled: false))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBG)

            VStack(alignment: .leading, spacing: 12) {
                Text("Age distribution")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                distributionBars(summary.ageBuckets.map { ($0.title, $0.bytes) })
                Text("File type breakdown")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .padding(.top, 4)
                ForEach(summary.typeBuckets.prefix(5)) { bucket in
                    Button {
                        typeFilter = typeFilterFor(bucket.kind)
                    } label: {
                        HStack {
                            Text(bucket.kind.title)
                                .font(.system(size: 11))
                                .foregroundStyle(DiskMapTheme.ink)
                            Spacer()
                            Text(ByteFormat.string(bucket.bytes))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .frame(width: 280, alignment: .leading)
            .background(cardBG)
        }
    }

    private func distributionBars(_ items: [(String, Int64)]) -> some View {
        let maxB = max(1, items.map(\.1).max() ?? 1)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 8) {
                    Text(item.0)
                        .font(.system(size: 10))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .frame(width: 72, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(DiskMapTheme.info.opacity(0.75))
                            .frame(width: max(item.1 > 0 ? 4 : 0, geo.size.width * CGFloat(item.1) / CGFloat(maxB)))
                    }
                    .frame(height: 8)
                    Text(ByteFormat.string(item.1))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                    TextField("Search files in Downloads…", text: $query)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DiskMapTheme.cardFill)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DiskMapTheme.cardStroke))
                )
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                filterMenu("Age", ageFilter.title) {
                    ForEach(OldDownloadsAgeFilter.allCases) { f in
                        Button(f.title) { ageFilter = f }
                    }
                }
                filterMenu("Size", sizeFilter.title) {
                    ForEach(OldDownloadsSizeFilter.allCases) { f in
                        Button(f.title) { sizeFilter = f }
                    }
                }
                filterMenu("Type", typeFilter.title) {
                    ForEach(OldDownloadsTypeFilter.allCases) { f in
                        Button(f.title) { typeFilter = f }
                    }
                }
                filterMenu("Sort", sort.title) {
                    ForEach(OldDownloadsSort.allCases) { s in
                        Button(s.title) { sort = s }
                    }
                }
                Spacer()
                Text("Based on last modified date.")
                    .font(.system(size: 10))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
        }
    }

    private func filterMenu<Content: View>(_ label: String, _ value: String, @ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            Text("\(label): \(value)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DiskMapTheme.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DiskMapTheme.cardFill)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DiskMapTheme.cardStroke))
                )
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 8) {
            Button {
                let allOn = !visible.isEmpty && visible.allSatisfy { checked.contains($0.nodeID) }
                if allOn { checked.subtract(visible.map(\.nodeID)) }
                else { checked.formUnion(visible.map(\.nodeID)) }
            } label: {
                let allOn = !visible.isEmpty && visible.allSatisfy { checked.contains($0.nodeID) }
                Image(systemName: allOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle(allOn ? DiskMapTheme.info : DiskMapTheme.mutedLabel)
            }
            .buttonStyle(.plain)
            .frame(width: 22)
            Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
            Text("SIZE").frame(width: 80, alignment: .trailing)
            Text("AGE").frame(width: 64, alignment: .leading)
            Text("TYPE").frame(width: 72, alignment: .leading)
            Text("STATUS").frame(width: 100, alignment: .leading)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(DiskMapTheme.mutedLabel)
        .padding(.horizontal, 4)
    }

    private var fileRows: some View {
        VStack(spacing: 0) {
            ForEach(visible.prefix(200)) { item in
                row(item)
                Divider().overlay(DiskMapTheme.cardStroke.opacity(0.55))
            }
        }
        .padding(10)
        .background(cardBG)
    }

    private func row(_ item: OldDownloadsCandidate) -> some View {
        let selected = selectedID == item.nodeID
        return HStack(spacing: 8) {
            Button {
                if checked.contains(item.nodeID) {
                    checked.remove(item.nodeID)
                } else {
                    checked.insert(item.nodeID)
                    selectedID = item.nodeID
                }
            } label: {
                Image(systemName: checked.contains(item.nodeID) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle(checked.contains(item.nodeID) ? DiskMapTheme.info : DiskMapTheme.mutedLabel)
            }
            .buttonStyle(.plain)
            .frame(width: 22)
            .contentShape(Rectangle())

            HStack(spacing: 10) {
                Image(systemName: item.kind.symbolName)
                    .font(.system(size: 14))
                    .foregroundStyle(DiskMapTheme.info)
                    .frame(width: 28, height: 28)
                    .background(DiskMapTheme.navSelected, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                        .lineLimit(1)
                    Text(parentDisplay(item.displayPath))
                        .font(.system(size: 10))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(ByteFormat.string(item.bytes))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .frame(width: 80, alignment: .trailing)

            Text(OldDownloadsCatalog.ageLabel(item.ageDays))
                .font(.system(size: 11))
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .frame(width: 64, alignment: .leading)

            Text(item.kind.title)
                .font(.system(size: 11))
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .frame(width: 72, alignment: .leading)
                .lineLimit(1)

            statusPill(item.status)
                .frame(width: 100, alignment: .leading)

            Menu {
                Button("Reveal in Finder") { reveal(item) }
                Button("Add to Cleanup Review") { Task { await stage([item]) } }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .frame(width: 22, height: 22)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? DiskMapTheme.navSelected : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedID = item.nodeID }
    }

    private func statusPill(_ status: OldDownloadsStatus) -> some View {
        ClassificationBadge(kind: status == .reviewFirst ? .review : .safe)
    }


    private var emptyResults: some View {
        VStack(spacing: 8) {
            Text(catalog.candidates.isEmpty ? "Nothing old enough to review" : "No files match these filters")
                .font(.system(size: 14, weight: .semibold))
            Text(catalog.candidates.isEmpty
                 ? "Your Downloads folder doesn’t currently contain files matching this view. That’s a good thing."
                 : "Try another age, size, or type filter.")
                .font(.system(size: 12))
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .multilineTextAlignment(.center)
            if catalog.candidates.isEmpty {
                Button("Reveal Downloads in Finder") { revealDownloads() }
                    .buttonStyle(InkButtonStyle(filled: false))
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(cardBG)
    }

    private var selectionBar: some View {
        SelectionToolbar(
            selectedCount: checkedItems.count,
            selectedBytes: checkedBytes,
            onPrimary: { Task { await stage(checkedItems) } },
            onClear: { checked.removeAll() },
            onReveal: {
                NSWorkspace.shared.activateFileViewerSelecting(checkedItems.map { URL(fileURLWithPath: $0.absolutePath) })
            }
        )
    }

    private var footerBar: some View {
        HStack {
            Group {
                if checked.isEmpty {
                    if active != nil {
                        Text("Inspecting · check boxes to multi-select")
                    } else {
                        Text("Check boxes to select for Cleanup")
                    }
                } else {
                    Text("\(checkedItems.count) selected · \(ByteFormat.string(checkedBytes))")
                }
            }
                .font(.system(size: 11))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Spacer()
            Text("Showing \(visible.count) of \(catalog.candidates.count) · \(ByteFormat.string(visible.reduce(Int64(0)) { $0 + $1.bytes }))")
                .font(.system(size: 11))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Button("Rescan") {
                model.refreshOldDownloadsCache()
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DiskMapTheme.info)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(DiskMapTheme.cardFill.opacity(0.8))
        .overlay(alignment: .top) { Divider().overlay(DiskMapTheme.cardStroke) }
    }

    private var inspector: some View {
        Group {
            if let item = active {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            Image(systemName: item.kind.symbolName)
                                .font(.system(size: 28))
                                .foregroundStyle(DiskMapTheme.info)
                                .frame(width: 64, height: 64)
                                .background(DiskMapTheme.navSelected, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(DiskMapTheme.ink)
                                Text(ByteFormat.string(item.bytes))
                                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                                Text("\(item.kind.title)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(DiskMapTheme.mutedLabel)
                                statusPill(item.status)
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            StatRow(label: "Path", value: parentDisplay(item.displayPath))
                            StatRow(label: "Modified", value: OldDownloadsCatalog.ageLabel(item.ageDays))
                            StatRow(label: "Age (days)", value: "\(item.ageDays)")
                        }
                        .padding(12)
                        .background(cardBG)

                        WhyCard(title: "Why is this here?", bodyText: item.whyHere)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Cleanup recommendation")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                            Text(item.recommendation)
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .background(cardBG)

                        VStack(spacing: 8) {
                            Button("Reveal in Finder") { reveal(item) }
                                .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                            Button("Open containing folder") {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: (item.absolutePath as NSString).deletingLastPathComponent)
                            }
                            .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                            let staged = model.isStaged(URL(fileURLWithPath: item.absolutePath))
                            Button(staged ? "In Cleanup Review" : "Add to Cleanup Review") {
                                Task { await stage([item]) }
                            }
                            .buttonStyle(PrimaryCTAStyle(fullWidth: true))
                            Button("View in Visualize") {
                                model.destination = .visualize
                            }
                            .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                        }

                        Text("This is a personal Downloads file. DiskMap can’t determine if you still need it. Review before removing.")
                            .font(.system(size: 10))
                            .foregroundStyle(DiskMapTheme.info)
                            .padding(10)
                            .background(DiskMapTheme.info.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .padding(16)
                }
            } else {
                VStack(spacing: 8) {
                    Text("Select a file")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Pick a Downloads file to see why it’s here and what you can do.")
                        .font(.system(size: 12))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DiskMapTheme.inspectorFill)
    }

    private var cardBG: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(DiskMapTheme.cardFill)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
            )
    }

    private func parentDisplay(_ path: String) -> String {
        if let slash = path.lastIndex(of: "/") {
            return String(path[...slash])
        }
        return path
    }

    private func typeFilterFor(_ kind: FileKind) -> OldDownloadsTypeFilter {
        switch kind {
        case .video: return .video
        case .archive: return .archive
        case .diskImage: return .installer
        case .document: return .document
        default: return .other
        }
    }

    private func reveal(_ item: OldDownloadsCandidate) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.absolutePath)])
    }

    private func revealDownloads() {
        let home = NSHomeDirectory() + "/Downloads"
        NSWorkspace.shared.open(URL(fileURLWithPath: home, isDirectory: true))
    }

    private func stage(_ items: [OldDownloadsCandidate]) async {
        var ok = 0
        for item in items {
            let url = URL(fileURLWithPath: item.absolutePath)
            if model.isStaged(url) { continue }
            let success = await model.cleanupQueue.stage(
                url,
                size: item.bytes,
                reason: "Old Downloads: \(item.name)"
            )
            if success { ok += 1 }
        }
        await model.refreshQueue()
        checked.removeAll()
        model.showToast(ok > 0 ? "Added \(ok) to cleanup review" : "Nothing new staged")
        if ok > 0 { onOpenCleanup() }
    }
}
