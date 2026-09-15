import AppKit
import CoreServices
import DiskMapCore
import SwiftUI

/// Explore → Applications: storage intelligence for installed apps.
struct AppsView: View {
    @ObservedObject var model: ScanModel
    var onOpenCleanup: () -> Void = {}

    @State private var apps: [ApplicationEntry] = []
    @State private var isLoading = true
    @State private var selectedID: String?
    @State private var checked: Set<String> = []
    @State private var filter: ApplicationFilter = .all
    @State private var sort: ApplicationsCatalog.Sort = .sizeDesc
    @State private var query = ""
    @State private var inspectorTab: InspectorTab = .overview
    @State private var loadTask: Task<Void, Never>?

    private enum InspectorTab: String, CaseIterable, Identifiable {
        case overview, contents, insights
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: return "Overview"
            case .contents: return "Contents"
            case .insights: return "Insights"
            }
        }
    }

    private var summary: ApplicationSummary { ApplicationsCatalog.summarize(apps) }

    private var visible: [ApplicationEntry] {
        let filtered = ApplicationsCatalog.filter(apps, filter)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let searched: [ApplicationEntry]
        if q.isEmpty {
            searched = filtered
        } else {
            searched = filtered.filter {
                $0.name.lowercased().contains(q)
                    || ($0.publisher?.lowercased().contains(q) ?? false)
                    || ($0.bundleID?.lowercased().contains(q) ?? false)
                    || $0.bundlePath.lowercased().contains(q)
            }
        }
        return ApplicationsCatalog.sorted(searched, by: sort)
    }

    private var active: ApplicationEntry? {
        if let selectedID, let hit = apps.first(where: { $0.id == selectedID }) { return hit }
        return visible.first
    }

    private var checkedApps: [ApplicationEntry] {
        apps.filter { checked.contains($0.id) && $0.canStageForCleanup }
    }

    private var checkedBytes: Int64 {
        checkedApps.reduce(Int64(0)) { $0 + $1.totalBytes }
    }

    var body: some View {
        HStack(spacing: 0) {
            mainColumn
            Divider().overlay(DiskMapTheme.cardStroke)
            inspector
                .frame(width: 320)
        }
        .background(DiskMapTheme.cream)
        .task { await reloadCatalog() }
        .onDisappear { loadTask?.cancel() }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            summaryCards
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            filterRow
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            listToolbar
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            tableHeader
                .padding(.horizontal, 20)
            Divider().overlay(DiskMapTheme.cardStroke)
            Group {
                if isLoading && apps.isEmpty {
                    skeletonList
                } else if visible.isEmpty {
                    emptyState
                } else {
                    appList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if !checked.isEmpty {
                multiSelectBar
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Applications")
                    .font(DiskMapType.title)
                    .foregroundStyle(DiskMapTheme.ink)
                Text("See what’s installed, how much space each app uses, and which ones may be worth reviewing.")
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if checked.isEmpty {
                HStack(spacing: 8) {
                    if selectedID != nil {
                        Text("1 application selected")
                            .font(.system(size: 11))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                    Button("Open") { openSelected() }
                        .buttonStyle(InkButtonStyle(filled: false))
                        .disabled(active == nil)
                    Button("Reveal") { revealSelected() }
                        .buttonStyle(InkButtonStyle(filled: false))
                        .disabled(active == nil)
                    Menu {
                        Button("Open in File Browser") { openInFileBrowser() }
                        Button("View in Visualize") { openInVisualize() }
                        Button("Copy Path") { copyPath() }
                        if active?.canStageForCleanup == true {
                            Divider()
                            Button("Add to Cleanup") { Task { await stageSelected() } }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .background(DiskMapTheme.navSelected, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .disabled(active == nil)
                    Button {
                        Task { await stageSelected() }
                    } label: {
                        Text(active.map { model.isStaged(URL(fileURLWithPath: $0.bundlePath)) ? "In Cleanup" : "Add to Cleanup" } ?? "Add to Cleanup")
                    }
                    .buttonStyle(PrimaryCTAStyle())
                    .disabled(active == nil || active?.canStageForCleanup != true)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var summaryCards: some View {
        HStack(spacing: 12) {
            summaryCard(
                value: "\(summary.appCount)",
                title: "Applications installed",
                subtitle: "\(summary.appStoreCount) App Store · \(summary.otherCount) other"
            )
            summaryCard(
                value: isLoading && summary.totalBytes == 0 ? "…" : ByteFormat.string(summary.totalBytes),
                title: "Total size",
                subtitle: volumeShare(summary.totalBytes)
            )
            summaryCard(
                value: ByteFormat.string(summary.reviewableBytes),
                title: "Potentially reviewable",
                subtitle: "\(summary.reviewCandidateCount) unused or large apps",
                tint: DiskMapTheme.review
            )
        }
    }

    private func summaryCard(value: String, title: String, subtitle: String, tint: Color = DiskMapTheme.ink) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DiskMapTheme.ink)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DiskMapTheme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                )
        )
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(.all, summary.appCount)
                chip(.large, summary.largeCount)
                chip(.notRecentlyUsed, summary.notRecentlyUsedCount)
                chip(.system, summary.systemCount)
                chip(.appStore, summary.appStoreCount)
                chip(.other, summary.otherCount)
            }
        }
    }

    private func chip(_ f: ApplicationFilter, _ count: Int) -> some View {
        Button {
            filter = f
        } label: {
            Text("\(f.title) (\(count))")
                .font(.system(size: 11, weight: filter == f ? .semibold : .regular))
                .foregroundStyle(filter == f ? DiskMapTheme.ink : DiskMapTheme.mutedLabel)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(filter == f ? DiskMapTheme.navSelected : DiskMapTheme.cardFill)
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private var listToolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                TextField("Search applications…", text: $query)
                    .textFieldStyle(.plain)
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
            Spacer(minLength: 0)
            Menu {
                ForEach(ApplicationsCatalog.Sort.allCases) { option in
                    Button(option.title) { sort = option }
                }
            } label: {
                Label("Sort: \(sort.title)", systemImage: "arrow.up.arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.ink)
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
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 22)
            Text("#").frame(width: 28, alignment: .leading)
            Text("APPLICATION").frame(maxWidth: .infinity, alignment: .leading)
            Text("SIZE").frame(width: 88, alignment: .trailing)
            Text("LAST USED").frame(width: 100, alignment: .leading)
            Text("SOURCE").frame(width: 80, alignment: .leading)
            Text("STATUS").frame(width: 90, alignment: .leading)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(DiskMapTheme.mutedLabel)
        .padding(.vertical, 8)
    }

    private var appList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, app in
                    appRow(app, index: index + 1)
                    Divider().overlay(DiskMapTheme.cardStroke.opacity(0.55))
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func appRow(_ app: ApplicationEntry, index: Int) -> some View {
        let selected = selectedID == app.id
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { checked.contains(app.id) },
                set: { on in
                    if on { checked.insert(app.id) } else { checked.remove(app.id) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .frame(width: 22)

            Text("\(index)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .frame(width: 28, alignment: .leading)

            HStack(spacing: 10) {
                AppIconView(path: app.bundlePath, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                        .lineLimit(1)
                    if let publisher = app.publisher, !publisher.isEmpty {
                        Text(publisher)
                            .font(.system(size: 10))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if app.sizePending {
                    Text("…")
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                } else {
                    Text(ByteFormat.string(app.totalBytes))
                        .foregroundStyle(DiskMapTheme.ink)
                }
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .frame(width: 88, alignment: .trailing)

            Text(lastUsedLabel(app.lastUsed))
                .font(.system(size: 11))
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .frame(width: 100, alignment: .leading)
                .lineLimit(1)

            Text(app.source.title)
                .font(.system(size: 11))
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .frame(width: 80, alignment: .leading)

            statusPill(app.status)
                .frame(width: 90, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? DiskMapTheme.navSelected : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedID = app.id
            inspectorTab = .overview
        }
    }

    private func statusPill(_ status: ApplicationStatus) -> some View {
        Text(status.title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(statusColor(status))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(statusColor(status).opacity(0.12), in: Capsule())
    }

    private func statusColor(_ status: ApplicationStatus) -> Color {
        switch status {
        case .keep: return DiskMapTheme.info
        case .reviewFirst: return DiskMapTheme.review
        case .system: return DiskMapTheme.mutedLabel
        }
    }

    private var multiSelectBar: some View {
        HStack {
            Text("\(checkedApps.count) applications selected · \(ByteFormat.string(checkedBytes))")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DiskMapTheme.ink)
            Spacer()
            Button("Clear Selection") { checked.removeAll() }
                .buttonStyle(InkButtonStyle(filled: false))
            Button("Reveal") {
                let urls = checkedApps.map { URL(fileURLWithPath: $0.bundlePath) }
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
            .buttonStyle(InkButtonStyle(filled: false))
            .disabled(checkedApps.isEmpty)
            Button("Add to Cleanup") {
                Task { await stageChecked() }
            }
            .buttonStyle(PrimaryCTAStyle())
            .disabled(checkedApps.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(DiskMapTheme.cardFill)
        .overlay(alignment: .top) { Divider().overlay(DiskMapTheme.cardStroke) }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(apps.isEmpty ? "No applications found" : "No applications found")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DiskMapTheme.ink)
            Text(apps.isEmpty
                 ? "DiskMap couldn’t find installed applications in the scanned locations."
                 : "Try another name or change your filters.")
                .font(.system(size: 12))
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var skeletonList: some View {
        VStack(spacing: 10) {
            ForEach(0..<8, id: \.self) { _ in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8).fill(DiskMapTheme.navSelected).frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(DiskMapTheme.navSelected).frame(width: 140, height: 10)
                        RoundedRectangle(cornerRadius: 3).fill(DiskMapTheme.navSelected).frame(width: 90, height: 8)
                    }
                    Spacer()
                    RoundedRectangle(cornerRadius: 3).fill(DiskMapTheme.navSelected).frame(width: 60, height: 10)
                }
                .padding(.horizontal, 20)
            }
            Spacer()
        }
        .padding(.top, 12)
    }

    private var inspector: some View {
        Group {
            if let app = active {
                appInspector(app)
            } else {
                VStack(spacing: 8) {
                    Text("Select an application")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Pick an app to see size breakdown, related storage, and cleanup guidance.")
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

    private func appInspector(_ app: ApplicationEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        AppIconView(path: app.bundlePath, size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(DiskMapTheme.ink)
                            Text(app.sizePending ? "Measuring…" : ByteFormat.string(app.totalBytes))
                                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                            if let publisher = app.publisher {
                                Text(publisher)
                                    .font(.system(size: 11))
                                    .foregroundStyle(DiskMapTheme.mutedLabel)
                            }
                            statusPill(app.status)
                        }
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 8) {
                        Button("Open") { open(app) }
                            .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                        Button("Reveal in Finder") { reveal(app) }
                            .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                    }

                    HStack(spacing: 0) {
                        ForEach(InspectorTab.allCases) { tab in
                            Button {
                                inspectorTab = tab
                            } label: {
                                Text(tab.title)
                                    .font(.system(size: 11, weight: inspectorTab == tab ? .semibold : .regular))
                                    .foregroundStyle(inspectorTab == tab ? DiskMapTheme.ink : DiskMapTheme.mutedLabel)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .overlay(alignment: .bottom) {
                                        Rectangle()
                                            .fill(inspectorTab == tab ? DiskMapTheme.info : Color.clear)
                                            .frame(height: 2)
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    switch inspectorTab {
                    case .overview:
                        overviewSection(app)
                    case .contents:
                        contentsSection(app)
                    case .insights:
                        insightsSection(app)
                    }
                }
                .padding(16)
            }

            VStack(spacing: 8) {
                Button {
                    Task { await stage(app) }
                } label: {
                    Text(model.isStaged(URL(fileURLWithPath: app.bundlePath)) ? "In Cleanup" : "Add to Cleanup")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryCTAStyle(fullWidth: true))
                .disabled(!app.canStageForCleanup)
            }
            .padding(16)
            .background(DiskMapTheme.cardFill)
            .overlay(alignment: .top) { Divider().overlay(DiskMapTheme.cardStroke) }
        }
    }

    private func overviewSection(_ app: ApplicationEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            metaBlock(app)
            sizeBreakdown(app)
            explainBlock(title: "What is this?", body: app.blurb)
            explainBlock(title: "Can I remove it?", body: app.removalGuidance, badge: app.status.title)
            relatedBlock(app)
        }
    }

    private func contentsSection(_ app: ApplicationEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sizeBreakdown(app)
            ForEach(app.related.prefix(12)) { item in
                HStack {
                    Text(item.displayName)
                        .font(.system(size: 12))
                    Spacer()
                    Text(ByteFormat.string(item.bytes))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
            }
            if app.related.isEmpty && !app.sizePending {
                Text("No related Library files matched this app’s bundle ID or name.")
                    .font(.system(size: 12))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
        }
    }

    private func insightsSection(_ app: ApplicationEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            explainBlock(title: "Why is it large?", body: app.whyLarge)
            if app.isLarge {
                explainBlock(
                    title: "Large application",
                    body: "\(app.name) is one of the larger applications on this Mac (\(ByteFormat.string(app.totalBytes)))."
                )
            }
            if app.isNotRecentlyUsed {
                explainBlock(
                    title: "Not recently used",
                    body: "Last activity detected \(lastUsedLabel(app.lastUsed)). If you no longer need this application, you can review it for removal."
                )
            }
            if app.related.contains(where: { $0.kind == .derivedData || $0.kind == .simulators }) {
                Button("View in Developer Storage →") {
                    model.destination = .developerStorage
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DiskMapTheme.info)
                .buttonStyle(.plain)
            }
            Button("View what’s inside →") {
                openInFileBrowser(app)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DiskMapTheme.info)
            .buttonStyle(.plain)
        }
    }

    private func metaBlock(_ app: ApplicationEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let version = app.version { StatRow(label: "Version", value: version) }
            StatRow(label: "Source", value: app.source.title)
            if let installed = app.installed {
                StatRow(label: "Installed", value: mediumDate(installed))
            }
            StatRow(label: "Last Used", value: lastUsedLabel(app.lastUsed))
            StatRow(label: "Location", value: shorten(app.bundlePath))
        }
        .padding(12)
        .background(cardBG)
    }

    private func sizeBreakdown(_ app: ApplicationEntry) -> some View {
        let total = max(1, app.totalBytes)
        let bundleFrac = Double(app.bundleBytes) / Double(total)
        let relatedFrac = Double(app.relatedBytes) / Double(total)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Size breakdown")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(DiskMapTheme.info)
                        .frame(width: max(app.bundleBytes > 0 ? 4 : 0, geo.size.width * bundleFrac))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(DiskMapTheme.review)
                        .frame(width: max(app.relatedBytes > 0 ? 4 : 0, geo.size.width * relatedFrac))
                }
            }
            .frame(height: 10)
            StatRow(label: "App bundle", value: ByteFormat.string(app.bundleBytes))
            StatRow(label: "Related data", value: ByteFormat.string(app.relatedBytes), emphasize: app.relatedBytes > 0)
        }
        .padding(12)
        .background(cardBG)
    }

    private func relatedBlock(_ app: ApplicationEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Related files")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            if app.related.isEmpty {
                Text(app.sizePending ? "Measuring related storage…" : "No confident related files found.")
                    .font(.system(size: 12))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            } else {
                ForEach(ApplicationsCatalog.relatedRollups(from: app.related).prefix(6), id: \.kind) { roll in
                    HStack {
                        Text(roll.kind.title)
                            .font(.system(size: 12))
                        Spacer()
                        Text(ByteFormat.string(roll.bytes))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                }
                if app.related.contains(where: { $0.kind == .derivedData || $0.kind == .simulators || $0.kind == .archives }) {
                    Button("View in Developer Storage →") {
                        model.destination = .developerStorage
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.info)
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
        }
        .padding(12)
        .background(cardBG)
    }

    private func explainBlock(title: String, body: String, badge: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.review)
                }
            }
            Text(body)
                .font(.system(size: 12))
                .foregroundStyle(DiskMapTheme.ink.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBG)
    }

    private var cardBG: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DiskMapTheme.cardFill)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
            )
    }

    // MARK: - Load / enrich

    private func reloadCatalog() async {
        isLoading = true
        let urls = AppLeftoverFinder.applicationBundles(in: AppLeftoverFinder.defaultApplicationDirectories())
        var stubs: [ApplicationEntry] = []
        stubs.reserveCapacity(urls.count)
        for url in urls {
            let meta = AppMetadata.read(url)
            let leftovers = AppLeftovers(
                bundleID: meta.bundleID,
                appName: meta.name,
                bundlePath: url,
                bundleSize: 0,
                leftoverPaths: [],
                leftoverSize: 0
            )
            var entry = ApplicationsCatalog.makeEntry(
                leftovers: leftovers,
                publisher: meta.publisher,
                version: meta.version,
                lastUsed: meta.lastUsed,
                installed: meta.installed,
                sizePending: true
            )
            // Re-classify source with path even before sizing
            entry = ApplicationEntry(
                name: entry.name,
                publisher: entry.publisher,
                version: entry.version,
                bundleID: entry.bundleID,
                bundlePath: entry.bundlePath,
                bundleBytes: 0,
                relatedBytes: 0,
                source: ApplicationsCatalog.classifySource(bundlePath: url.path, bundleID: meta.bundleID),
                status: ApplicationsCatalog.classifyStatus(
                    source: ApplicationsCatalog.classifySource(bundlePath: url.path, bundleID: meta.bundleID),
                    totalBytes: 0,
                    lastUsed: meta.lastUsed,
                    bundleID: meta.bundleID
                ),
                lastUsed: entry.lastUsed,
                installed: entry.installed,
                related: [],
                blurb: entry.blurb,
                whyLarge: entry.whyLarge,
                removalGuidance: entry.removalGuidance,
                sizePending: true
            )
            stubs.append(entry)
        }
        apps = ApplicationsCatalog.sorted(stubs, by: .nameAsc)
        selectedID = apps.first?.id
        isLoading = false

        loadTask?.cancel()
        loadTask = Task {
            await withTaskGroup(of: ApplicationEntry?.self) { group in
                var inflight = 0
                var iterator = urls.makeIterator()
                func enqueue() {
                    while inflight < 3, let url = iterator.next() {
                        inflight += 1
                        group.addTask {
                            if Task.isCancelled { return nil }
                            let leftovers = AppLeftoverFinder.findLeftovers(for: url, measureRelated: true)
                            let meta = AppMetadata.read(url)
                            return ApplicationsCatalog.makeEntry(
                                leftovers: leftovers,
                                publisher: meta.publisher,
                                version: meta.version,
                                lastUsed: meta.lastUsed,
                                installed: meta.installed,
                                sizePending: false
                            )
                        }
                    }
                }
                enqueue()
                for await result in group {
                    inflight -= 1
                    if let entry = result {
                        await MainActor.run {
                            if let idx = apps.firstIndex(where: { $0.id == entry.id }) {
                                apps[idx] = entry
                            } else {
                                apps.append(entry)
                            }
                            apps = ApplicationsCatalog.sorted(apps, by: sort)
                        }
                    }
                    enqueue()
                }
            }
        }
    }

    // MARK: - Actions

    private func openSelected() {
        guard let active else { return }
        open(active)
    }

    private func revealSelected() {
        guard let active else { return }
        reveal(active)
    }

    private func open(_ app: ApplicationEntry) {
        NSWorkspace.shared.open(URL(fileURLWithPath: app.bundlePath))
    }

    private func reveal(_ app: ApplicationEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.bundlePath)])
    }

    private func copyPath() {
        guard let active else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(active.bundlePath, forType: .string)
        model.showToast("Path copied")
    }

    private func openInFileBrowser(_ app: ApplicationEntry? = nil) {
        let target = app ?? active
        guard let target else { return }
        // Prefer navigating to Applications folder parent; node may not be in scan tree.
        model.destination = .fileBrowser
        model.showToast("Open \(target.name) path in Finder if it’s outside the scan root")
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target.bundlePath)])
    }

    private func openInVisualize() {
        model.destination = .visualize
    }

    private func stageSelected() async {
        guard let active else { return }
        await stage(active)
    }

    private func stage(_ app: ApplicationEntry) async {
        guard app.canStageForCleanup else { return }
        let url = URL(fileURLWithPath: app.bundlePath)
        if model.isStaged(url) {
            model.showToast("Already in cleanup list")
            onOpenCleanup()
            return
        }
        let ok = await model.cleanupQueue.stage(url, size: app.bundleBytes, reason: "Application: \(app.name)")
        await model.refreshQueue()
        model.showToast(ok ? "Added to cleanup review" : "Blocked by safety rules")
        if ok { onOpenCleanup() }
    }

    private func stageChecked() async {
        var okCount = 0
        for app in checkedApps {
            let url = URL(fileURLWithPath: app.bundlePath)
            if model.isStaged(url) { continue }
            let ok = await model.cleanupQueue.stage(url, size: app.bundleBytes, reason: "Application: \(app.name)")
            if ok { okCount += 1 }
        }
        await model.refreshQueue()
        checked.removeAll()
        model.showToast(okCount > 0 ? "Added \(okCount) apps to cleanup" : "Nothing new staged")
        if okCount > 0 { onOpenCleanup() }
    }

    // MARK: - Formatting

    private func lastUsedLabel(_ date: Date?) -> String {
        guard let date else { return "Unknown" }
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days < 7 { return "\(days) days ago" }
        if days < 30 { return "\(days / 7) wk ago" }
        if days < 365 { return "\(days / 30) mo ago" }
        return "\(days / 365) yr ago"
    }

    private func mediumDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    private func shorten(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + String(path.dropFirst(home.count)) }
        return path
    }

    private func volumeShare(_ bytes: Int64) -> String {
        if let vol = VolumeStats.forPath("/"), vol.totalBytes > 0 {
            let pct = Double(bytes) / Double(vol.totalBytes) * 100
            return String(format: "%.1f%% of disk", pct)
        }
        return "Across installed apps"
    }
}

// MARK: - Icon

private struct AppIconView: View {
    let path: String
    var size: CGFloat = 36

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

// MARK: - Metadata

private enum AppMetadata {
    struct Info {
        var name: String
        var bundleID: String?
        var publisher: String?
        var version: String?
        var lastUsed: Date?
        var installed: Date?
    }

    static func read(_ url: URL) -> Info {
        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let publisher = bundle?.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
        let shortPublisher: String? = {
            if let p = publisher, p.count < 80 { return p }
            return bundle?.object(forInfoDictionaryKey: "CFBundleGetInfoString") as? String
        }()
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        var lastUsed: Date?
        var installed: Date?
        if let values = try? url.resourceValues(forKeys: [.contentAccessDateKey, .creationDateKey, .contentModificationDateKey]) {
            lastUsed = values.contentAccessDate
            installed = values.creationDate
        }
        // Spotlight last-used when available
        if let item = MDItemCreate(nil, url.path as CFString),
           let spot = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date {
            lastUsed = spot
        }
        return Info(
            name: name,
            bundleID: bundle?.bundleIdentifier,
            publisher: shortPublisher,
            version: version,
            lastUsed: lastUsed,
            installed: installed
        )
    }
}
