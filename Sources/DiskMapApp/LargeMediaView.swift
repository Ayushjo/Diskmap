import AppKit
import DiskMapCore
import SwiftUI

/// Clean → Large Media: media-storage intelligence workspace (not Biggest Files).
struct LargeMediaView: View {
    @ObservedObject var model: ScanModel
    @Environment(\.diskMapContentWidth) private var contentWidth
    var onOpenCleanup: () -> Void
    var pickFolder: () -> Void

    @State private var selectedID: Int32?
    @State private var checked: Set<Int32> = []
    @State private var query = ""
    @State private var typeFilter: MediaTypeFilter = .all
    @State private var sizeFilter: MediaSizeFilter = .any
    @State private var ageFilter: MediaAgeFilter = .all
    @State private var locationFilter: MediaLocationFilter = .any
    @State private var sort: MediaSort = .largest

    private var catalog: MediaCatalogResult { model.cachedLargeMedia }
    private var summary: MediaSummary { catalog.summary }

    private var visible: [MediaCandidate] {
        let filtered = MediaCatalog.filter(
            catalog.candidates,
            type: typeFilter,
            size: sizeFilter,
            age: ageFilter,
            location: locationFilter,
            query: query
        )
        return MediaCatalog.sorted(filtered, by: sort)
    }

    private var active: MediaCandidate? {
        if let selectedID,
           let hit = visible.first(where: { $0.nodeID == selectedID })
            ?? catalog.candidates.first(where: { $0.nodeID == selectedID }) {
            return hit
        }
        return visible.first
    }

    private var checkedItems: [MediaCandidate] {
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
                AdaptiveInspectorSplit(windowWidth: contentWidth, inspectionToken: selectedID.map(String.init), main: mainColumn, inspector: inspector)
            }
        }
        .background(DiskMapTheme.cream)
        .task {
            if model.cachedLargeMedia.candidates.isEmpty, model.tree != nil {
                model.refreshLargeMediaCache()
            }
        }
    }

    private var emptyScan: some View {
        VStack(spacing: 12) {
            Text("Scan to find videos, photos, audio, and media projects.")
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
                    breakdowns
                    opportunities
                    filters
                    tableHeader
                    if visible.isEmpty {
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
            Image(systemName: "film.stack")
                .font(.system(size: 28))
                .foregroundStyle(DiskMapTheme.info)
                .frame(width: 48, height: 48)
                .background(DiskMapTheme.info.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text("Large Media")
                    .font(DiskMapType.title)
                    .foregroundStyle(DiskMapTheme.ink)
                Text("Find the videos, photos, audio and media projects using the most space on your Mac. Nothing is deleted automatically.")
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Cleanup") { onOpenCleanup() }
                .buttonStyle(InkButtonStyle(filled: false))
        }
    }

    private var summaryCards: some View {
        HStack(spacing: 10) {
            metricCard(icon: "externaldrive.fill", tint: DiskMapTheme.info,
                       value: ByteFormat.string(summary.totalBytes),
                       title: "Media storage",
                       subtitle: "\(summary.totalCount) files")
            metricCard(icon: "line.3.horizontal.decrease.circle", tint: DiskMapTheme.review,
                       value: ByteFormat.string(visible.reduce(0) { $0 + $1.bytes }),
                       title: "Matching media",
                       subtitle: "Current filters")
            metricCard(icon: "photo.on.rectangle.angled", tint: DiskMapTheme.developer,
                       value: "\(visible.count.formatted())",
                       title: "Files shown",
                       subtitle: "Videos, images, audio and projects")
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

    private var breakdowns: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Media overview")
                .font(DiskMapType.section)
                .foregroundStyle(DiskMapTheme.ink)
            HStack(alignment: .top, spacing: 18) {
            breakdownPanel(title: "By type", buckets: summary.typeBuckets) { bucket in
                if let t = MediaTypeFilter(rawValue: bucket.id) { typeFilter = t }
            }
            breakdownPanel(title: "By location", buckets: summary.locationBuckets) { bucket in
                if let loc = MediaLocationFilter(rawValue: bucket.id) { locationFilter = loc }
            }
            breakdownPanel(title: "By age", buckets: summary.ageBuckets) { bucket in
                switch bucket.id {
                case "a30": ageFilter = .all; sizeFilter = .any
                case "a90": ageFilter = .days30
                case "a365": ageFilter = .days90
                case "a730", "a2p": ageFilter = .year1
                default: break
                }
            }
            }
        }
        .padding(12)
        .background(cardBG)
    }

    private func breakdownPanel(title: String, buckets: [MediaBucket], onSelect: @escaping (MediaBucket) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DiskMapTheme.ink)
            if buckets.isEmpty {
                Text("No data yet")
                    .font(.system(size: 11))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            } else {
                ForEach(buckets) { bucket in
                    Button {
                        onSelect(bucket)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(bucket.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(DiskMapTheme.ink)
                                Spacer()
                                Text(ByteFormat.string(bucket.bytes))
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(DiskMapTheme.mutedLabel)
                                if bucket.fraction > 0 {
                                    Text(String(format: "%.0f%%", bucket.fraction * 100))
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(DiskMapTheme.mutedLabel)
                                        .frame(width: 36, alignment: .trailing)
                                }
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(DiskMapTheme.navSelected)
                                    Capsule()
                                        .fill(barTint(for: bucket.id))
                                        .frame(width: max(4, geo.size.width * bucket.fraction))
                                }
                            }
                            .frame(height: 6)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func barTint(for id: String) -> Color {
        switch id {
        case "video", "a365": return DiskMapTheme.info
        case "image", "a90": return DiskMapTheme.review
        case "audio", "a30": return DiskMapTheme.developer
        case "project", "a730": return DiskMapTheme.safe
        case "downloads": return DiskMapTheme.info
        case "desktop": return DiskMapTheme.review
        default: return DiskMapTheme.ink.opacity(0.35)
        }
    }

    private var opportunities: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Biggest media files")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("View all media") {
                    typeFilter = .all
                    sizeFilter = .any
                    ageFilter = .all
                    locationFilter = .any
                    sort = .largest
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DiskMapTheme.info)
                .buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(catalog.opportunities) { item in
                        opportunityCard(item)
                    }
                }
            }
        }
    }

    private func opportunityCard(_ item: MediaCandidate) -> some View {
        Button {
            selectedID = item.nodeID
            typeFilter = .all
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                MediaThumbnailView(
                    url: URL(fileURLWithPath: item.absolutePath),
                    size: CGSize(width: 160, height: 90),
                    fallbackSymbol: item.kind.symbolName,
                    showPlayBadge: item.kind == .video
                )
                Text(item.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.ink)
                    .lineLimit(2)
                    .frame(height: 30, alignment: .topLeading)
                    .frame(width: 160, alignment: .leading)
                Text("\(ByteFormat.string(item.bytes)) · \(item.location.title)")
                    .font(.system(size: 10))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                Text(MediaCatalog.ageLabel(item.ageDays) + " old")
                    .font(.system(size: 10))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
            .padding(10)
            .background(cardBG)
        }
        .buttonStyle(.plain)
    }

    private var filters: some View {
        HStack(spacing: 8) {
            DiskMapSearchField(placeholder: "Search media…", text: $query)
            .frame(maxWidth: 220)
            DiskMapMenu(label: "Type", options: MediaTypeFilter.allCases, selection: $typeFilter, title: { $0.title })
            DiskMapMenu(label: "Size", options: MediaSizeFilter.allCases, selection: $sizeFilter, title: { $0.title })
            DiskMapMenu(label: "Age", options: MediaAgeFilter.allCases, selection: $ageFilter, title: { $0.title })
            DiskMapMenu(label: "Location", options: MediaLocationFilter.allCases, selection: $locationFilter, title: { $0.title })
            Spacer()
            DiskMapMenu(label: "Sort", options: MediaSort.allCases, selection: $sort, title: { $0.title })
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
            Text("").frame(width: 36)
            Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
            Text("TYPE").frame(width: 70, alignment: .leading)
            Text("LOCATION").frame(width: 88, alignment: .leading)
            Text("SIZE").frame(width: 72, alignment: .trailing)
            Text("AGE").frame(width: 52, alignment: .leading)
            Text("STATUS").frame(width: 100, alignment: .leading)
            Text("").frame(width: 24)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(DiskMapTheme.mutedLabel)
        .padding(.horizontal, 4)
    }

    private var fileRows: some View {
        VStack(spacing: 0) {
            ForEach(visible.prefix(300)) { item in
                row(item)
                Divider().overlay(DiskMapTheme.cardStroke.opacity(0.55))
            }
            if visible.count > 300 {
                Text("Showing first 300 of \(visible.count). Refine filters to narrow.")
                    .font(.system(size: 11))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .padding(.top, 8)
            }
        }
        .padding(10)
        .background(cardBG)
    }

    private func row(_ item: MediaCandidate) -> some View {
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

            MediaThumbnailView(
                url: URL(fileURLWithPath: item.absolutePath),
                size: CGSize(width: 36, height: 28),
                fallbackSymbol: item.kind.symbolName,
                showPlayBadge: false
            )

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
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.kind.shortTitle)
                .font(.system(size: 11))
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .frame(width: 70, alignment: .leading)

            Text(item.location.title)
                .font(.system(size: 11))
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .frame(width: 88, alignment: .leading)
                .lineLimit(1)

            Text(ByteFormat.string(item.bytes))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .frame(width: 72, alignment: .trailing)

            Text(MediaCatalog.ageLabel(item.ageDays))
                .font(.system(size: 11))
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .frame(width: 52, alignment: .leading)

            statusPill(item.status)
                .frame(width: 100, alignment: .leading)

            Menu {
                Button("Reveal in Finder") { reveal(item) }
                Button("Open containing folder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: (item.absolutePath as NSString).deletingLastPathComponent)
                }
                Button("Add to Cleanup") { Task { await stage([item]) } }
                Button("View in Visualize") {
                    model.folderFilterPath = (item.absolutePath as NSString).deletingLastPathComponent
                    model.destination = .visualize
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .frame(width: 24, height: 24)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? DiskMapTheme.navSelected : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedID = item.nodeID }
    }

    private func statusPill(_ status: MediaStatus) -> some View {
        ClassificationBadge(kind: status == .reviewFirst ? .review : .safe)
    }

    private var emptyResults: some View {
        VStack(spacing: 10) {
            Text(catalog.candidates.isEmpty ? "No large media found" : "No media matches these filters")
                .font(.system(size: 14, weight: .semibold))
            Text(catalog.candidates.isEmpty
                 ? "DiskMap couldn’t find media above the size threshold in this scan."
                 : "Try clearing filters or broadening search.")
                .font(.system(size: 12))
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .multilineTextAlignment(.center)
            if !catalog.candidates.isEmpty {
                Button("Clear filters") {
                    query = ""
                    typeFilter = .all
                    sizeFilter = .any
                    ageFilter = .all
                    locationFilter = .any
                }
                .buttonStyle(InkButtonStyle(filled: false))
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
            Text(checked.isEmpty
                 ? (active != nil ? "Inspecting · check boxes to multi-select" : "Check boxes to select for Cleanup")
                 : "\(checkedItems.count) selected · \(ByteFormat.string(checkedBytes))")
                .font(.system(size: 11))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Spacer()
            Button("Add to Cleanup") {
                if let active { Task { await stage([active]) } }
            }
            .buttonStyle(PrimaryCTAStyle())
            .disabled(active == nil)
            Text("\(visible.count) files · \(ByteFormat.string(visible.reduce(Int64(0)) { $0 + $1.bytes }))")
                .font(.system(size: 11))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Button("Rescan") { model.refreshLargeMediaCache() }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DiskMapTheme.info)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .frame(height: DiskMapMetric.statusBarHeight)
        .background(DiskMapTheme.cardFill)
        .overlay(alignment: .top) { Divider().overlay(DiskMapTheme.cardStroke) }
    }

    private var inspector: some View {
        Group {
            if let item = active {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        MediaThumbnailView(
                            url: URL(fileURLWithPath: item.absolutePath),
                            size: CGSize(width: 244, height: 138),
                            fallbackSymbol: item.kind.symbolName,
                            showPlayBadge: item.kind == .video
                        )
                        .frame(maxWidth: .infinity)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name)
                                .font(.system(size: 15, weight: .semibold))
                            Text(ByteFormat.string(item.bytes))
                                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                            Text("\(item.kind.shortTitle) · \(extLabel(item.name))")
                                .font(.system(size: 11))
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                            statusPill(item.status)
                        }

                        HStack {
                            Text(parentDisplay(item.displayPath))
                                .font(.system(size: 11))
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                                .lineLimit(2)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.absolutePath, forType: .string)
                                model.showToast("Path copied")
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(10)
                        .background(cardBG)

                        VStack(alignment: .leading, spacing: 6) {
                            StatRow(label: "Size", value: "\(ByteFormat.string(item.bytes)) (\(item.bytes) bytes)")
                            StatRow(label: "Modified", value: MediaCatalog.ageLabel(item.ageDays) + " ago")
                            StatRow(label: "Location", value: item.location.title)
                            StatRow(label: "Type", value: item.kind.title)
                            if let d = item.durationLabel { StatRow(label: "Duration", value: d) }
                            if let d = item.dimensionsLabel { StatRow(label: "Dimensions", value: d) }
                        }

                        WhyCard(title: "Why is this here?", bodyText: item.whyHere)

                        SafetyCard(assessment: item.safety)

                        VStack(spacing: 8) {
                            let staged = model.isStaged(URL(fileURLWithPath: item.absolutePath))
                            Button(staged ? "In Cleanup" : "Add to Cleanup") {
                                if staged { onOpenCleanup() }
                                else { Task { await stage([item]) } }
                            }
                            .buttonStyle(PrimaryCTAStyle(fullWidth: true))
                            HStack(spacing: 8) {
                                Button("Quick Look") { quickLook(item) }
                                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                                Button("Reveal") { reveal(item) }
                                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                            }
                            Menu("More") {
                                Button("Open containing folder") {
                                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: (item.absolutePath as NSString).deletingLastPathComponent)
                                }
                                Button("Find duplicates") { model.destination = .duplicates }
                                Button("View in Visualize") {
                                    model.folderFilterPath = (item.absolutePath as NSString).deletingLastPathComponent
                                    model.destination = .visualize
                                }
                                Button("Copy Path") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(item.absolutePath, forType: .string)
                                    model.showToast("Path copied")
                                }
                            }
                            .menuStyle(.borderlessButton)
                        }
                    }
                    .padding(DiskMapMetric.inspectorPadding)
                }
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

    private func extLabel(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "File" : "\(ext) \(active?.kind.shortTitle ?? "Media")"
    }

    private func reveal(_ item: MediaCandidate) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.absolutePath)])
    }

    private func quickLook(_ item: MediaCandidate) {
        let url = URL(fileURLWithPath: item.absolutePath)
        DiskMapQuickLook.shared.show(url)
    }

    private func stage(_ items: [MediaCandidate]) async {
        let result = await model.stageForCleanup(items.map {
            CleanupStageRequest(
                url: URL(fileURLWithPath: $0.absolutePath),
                size: $0.bytes,
                reason: "Large media: \($0.kind.shortTitle)"
            )
        })
        let rejected = Set(result.rejectedURLs.map(\.path))
        checked = Set(items.filter { rejected.contains($0.absolutePath) }.map(\.nodeID))
        model.showToast(result.added > 0 ? "Added \(result.added) to Cleanup" : "Nothing new added")
    }

}
