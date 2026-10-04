import AppKit
import CoreServices
import DiskMapCore
import SwiftUI

/// Explore → Applications: storage intelligence for installed apps.
struct AppsView: View {
    @ObservedObject var model: ScanModel
    @Environment(\.diskMapContentWidth) private var contentWidth

    @State private var apps: [ApplicationEntry] = []
    @State private var isLoading = true
    @State private var selectedID: String?
    @State private var checked: Set<String> = []
    @State private var filter: ApplicationFilter = .all
    @State private var sort: ApplicationsCatalog.Sort = .sizeDesc
    @State private var query = ""
    @State private var loadTask: Task<Void, Never>?

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
        AdaptiveInspectorSplit(windowWidth: contentWidth, inspectionToken: selectedID, main: mainColumn, inspector: inspector)
        .background(DiskMapTheme.canvas)
        .task { await reloadCatalog() }
        .onDisappear { loadTask?.cancel() }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(eyebrow: "Explore", title: "Applications",
                           subtitle: "What’s installed, how much space each app and its data use, and which may be worth a look.")
                FigureStrip(figures: [
                    Figure(label: "Installed", value: "\(summary.appCount)",
                           detail: "\(summary.appStoreCount) App Store · \(summary.otherCount) other"),
                    Figure(label: "Total size", value: isLoading && summary.totalBytes == 0 ? "…" : ByteFormat.string(summary.totalBytes),
                           detail: volumeShare(summary.totalBytes)),
                    Figure(label: "Worth reviewing", value: ByteFormat.string(summary.reviewableBytes),
                           detail: countLabel(summary.reviewCandidateCount, "app")),
                ])
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        DiskMapSearchField(placeholder: "Search applications", text: $query)
                            .frame(maxWidth: 300)
                        Spacer(minLength: 8)
                        DiskMapMenu(label: "Sort", options: ApplicationsCatalog.Sort.allCases, selection: $sort, title: { $0.title })
                    }
                    FlowLayout(spacing: 2) {
                        chip(.all, summary.appCount)
                        chip(.large, summary.largeCount)
                        chip(.notRecentlyUsed, summary.notRecentlyUsedCount)
                        chip(.appStore, summary.appStoreCount)
                        chip(.other, summary.otherCount)
                        chip(.system, summary.systemCount)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, DiskMapSpace.pageTop)
            .padding(.bottom, 12)
            Hairline()
            if isLoading && apps.isEmpty {
                DiskMapLoadingState(title: "Finding applications", detail: "Reading /Applications and ~/Applications.")
            } else if visible.isEmpty {
                DiskMapEmptyState(symbol: "app.dashed", title: "No applications found",
                                  message: apps.isEmpty ? "freedisk.space couldn’t find installed applications in the usual places."
                                      : "Try another name or filter.")
            } else {
                appList
            }
            ReviewFooter(
                checkedCount: checkedApps.count, checkedBytes: checkedBytes,
                hint: "Tick apps to remove, or",
                quickSelectTitle: "Select not recently used",
                quickSelectEnabled: visible.contains { $0.isNotRecentlyUsed && $0.canStageForCleanup },
                onQuickSelect: { checked = Set(visible.filter { $0.isNotRecentlyUsed && $0.canStageForCleanup }.map(\.id)) },
                onStage: { Task { await stageChecked() } },
                onClear: { checked.removeAll() },
                onReveal: { NSWorkspace.shared.activateFileViewerSelecting(checkedApps.map { URL(fileURLWithPath: $0.bundlePath) }) },
                paths: checkedApps.map(\.bundlePath)
            )
        }
    }

    private func chip(_ f: ApplicationFilter, _ count: Int) -> some View {
        Chip(title: f.title, count: "\(count)", isOn: filter == f) { filter = f }
    }

    private var appList: some View {
        // Worked out once per draw, not once per row.
        let items = visible
        let activeID = active?.id
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { app in
                    appRow(app, activeID: activeID)
                    RowSeparator(indent: 10 + 18 + 10 + 28 + 12)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 4)
        }
        .listKeyboard(
            ids: items.map(\.id), selection: $selectedID,
            path: { id in items.first { $0.id == id }?.bundlePath },
            stage: { id in
                if let app = items.first(where: { $0.id == id }) { Task { await stage(app) } }
            },
            selectAll: { checked = Set(items.filter(\.canStageForCleanup).map(\.id)) },
            clearSelection: { checked.removeAll() }
        )
    }

    private func appRow(_ app: ApplicationEntry, activeID: String?) -> some View {
        let isOn = checked.contains(app.id)
        return CheckRow {
            KitCheckbox(isOn: Binding(get: { isOn }, set: { on in
                if on { checked.insert(app.id) } else { checked.remove(app.id) }
            }), label: isOn ? "Unmark \(app.name)" : "Mark \(app.name)")
                .disabled(!app.canStageForCleanup)
            Button { selectedID = app.id } label: {
                KitRow(title: app.name, subtitle: Self.publisherName(app.publisher), selected: app.id == activeID, path: app.bundlePath,
                       onStage: app.canStageForCleanup ? { Task { await stage(app) } } : nil) {
                    AppIconView(path: app.bundlePath, size: 28)
                } trailing: {
                    statusLabel(app.status)
                        .frame(width: DiskMapType.scaled(96), alignment: .leading)
                    TextColumn(text: app.source.title, width: 76)
                    MonoColumn(text: lastUsedLabel(app.lastUsed), width: 64)
                    MonoColumn(text: app.sizePending ? "…" : ByteFormat.string(app.totalBytes), width: 74, emphasis: true)
                }
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded { open(app) })
            .accessibilityLabel("\(app.name), \(app.sizePending ? "size pending" : ByteFormat.string(app.totalBytes)), \(app.status.title)")
            .rowActions(path: app.bundlePath, stage: app.canStageForCleanup ? { Task { await stage(app) } } : nil)
        }
    }

    /// Dot + word; "Keep" is neutral, not a colour.
    private func statusLabel(_ status: ApplicationStatus) -> some View {
        SafetyLabel(level: nil, title: status.title, tint: statusColor(status))
    }

    private func statusColor(_ status: ApplicationStatus) -> Color {
        switch status {
        case .keep: return DiskMapTheme.ink3
        case .reviewFirst: return DiskMapTheme.review
        case .system: return DiskMapTheme.ink3.opacity(0.6)
        }
    }

    private var inspector: some View {
        Group {
            if let app = active {
                appInspector(app)
            } else {
                DiskMapEmptyState(symbol: "app.dashed", title: "Select an application",
                                  message: "See its size, related data and whether it’s safe to remove.")
            }
        }
        .background(DiskMapTheme.canvas)
    }

    private func appInspector(_ app: ApplicationEntry) -> some View {
        let staged = model.isStaged(URL(fileURLWithPath: app.bundlePath))
        let total = max(1, app.totalBytes)
        return InspectorColumn {
            InspectorHeader(name: app.name, size: app.sizePending ? "Measuring…" : ByteFormat.string(app.totalBytes),
                            detail: [Self.publisherName(app.publisher), app.version.map { "v\($0)" }].compactMap { $0 }.joined(separator: " · ")) {
                AppIconView(path: app.bundlePath, size: 44)
            }
            Hairline()
            VStack(alignment: .leading, spacing: 8) {
                MonoLabel("Size")
                SegmentedStorageBar(segments: [
                    (DiskMapTheme.data(0), Double(app.bundleBytes) / Double(total)),
                    (DiskMapTheme.data(4), Double(app.relatedBytes) / Double(total)),
                ])
                breakdownRow("App bundle", app.bundleBytes, DiskMapTheme.data(0))
                breakdownRow("Related data", app.relatedBytes, DiskMapTheme.data(4))
            }
            FactRow(label: "Last used", value: lastUsedLabel(app.lastUsed))
            FactRow(label: "Source", value: app.source.title + (app.installed.map { " · installed \(mediumDate($0))" } ?? ""))
            FactRow(label: "Location", value: shorten(app.bundlePath))
            if !app.related.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    MonoLabel("Related files")
                    ForEach(ApplicationsCatalog.relatedRollups(from: app.related).prefix(6), id: \.kind) { roll in
                        HStack {
                            Text(roll.kind.title)
                                .font(DiskMapType.secondary)
                                .foregroundStyle(DiskMapTheme.ink)
                            Spacer()
                            Text(ByteFormat.string(roll.bytes))
                                .font(DiskMapType.figureSmall)
                                .foregroundStyle(DiskMapTheme.ink2)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if app.related.contains(where: { $0.kind == .derivedData || $0.kind == .simulators || $0.kind == .archives }) {
                        Button("Developer Storage →") { model.destination = .developerStorage }
                            .buttonStyle(LinkButtonStyle())
                            .font(DiskMapType.secondary)
                    }
                }
            } else if app.sizePending {
                Note(label: "Related files", text: "Measuring related storage…")
            }
            Hairline()
            Note(label: "What it is", text: app.blurb)
            if app.totalBytes > 0 { Note(label: "Why it's large", text: app.whyLarge) }
            VStack(alignment: .leading, spacing: 4) {
                statusLabel(app.status)
                Text(app.removalGuidance)
                    .font(DiskMapType.secondary)
                    .foregroundStyle(DiskMapTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            InspectorActions(
                primaryTitle: staged ? "In Cleanup" : "Add to Cleanup",
                primaryDone: staged,
                primaryEnabled: app.canStageForCleanup,
                primary: { if staged { model.isCleanupQueuePresented = true } else { Task { await stage(app) } } },
                path: app.bundlePath
            ) {
                Button("Open \(app.name)") { open(app) }
            }
            .padding(.top, 4)
        }
    }

    /// Bundles carry a copyright line, not a publisher: "© 2026 Docker Inc.
    /// All rights reserved." → "Docker Inc."
    static func publisherName(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        for marker in ["all rights reserved", "alle rechte vorbehalten", "tous droits réservés"] {
            if let range = text.range(of: marker, options: .caseInsensitive) { text = String(text[..<range.lowerBound]) }
        }
        text = text.replacingOccurrences(of: "copyright", with: "", options: .caseInsensitive)
        let junk = CharacterSet(charactersIn: "©()–—-,.;: ").union(.decimalDigits).union(.whitespaces)
        text = String(text.drop { $0.unicodeScalars.allSatisfy(junk.contains) })
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:–—-"))
        // Keep the full stop of "Inc." / "Ltd." / "Co.", drop any other.
        if text.hasSuffix("."), !["Inc.", "Ltd.", "Co.", "Corp."].contains(where: { text.hasSuffix($0) }) {
            text.removeLast()
        }
        return text.isEmpty ? nil : text
    }

    private func breakdownRow(_ title: String, _ bytes: Int64, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(DiskMapType.secondary).foregroundStyle(DiskMapTheme.ink)
            Spacer()
            Text(ByteFormat.string(bytes)).font(DiskMapType.figureSmall).foregroundStyle(DiskMapTheme.ink2)
        }
        .accessibilityElement(children: .combine)
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
        apps = ApplicationsCatalog.sorted(stubs, by: sort)
        if let selectedID, !apps.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
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

    private func open(_ app: ApplicationEntry) {
        NSWorkspace.shared.open(URL(fileURLWithPath: app.bundlePath))
    }

    private func stage(_ app: ApplicationEntry) async {
        guard app.canStageForCleanup else { return }
        let result = await model.stageForCleanup([
            CleanupStageRequest(url: URL(fileURLWithPath: app.bundlePath), size: app.bundleBytes, reason: "Application: \(app.name)")
        ])
        model.showToast(result.added > 0 ? "Added \(app.name) to Cleanup — ⇧⌘⌫ to review"
                        : result.rejected > 0 ? "Blocked by safety rules" : "Already in Cleanup")
    }

    private func stageChecked() async {
        let apps = checkedApps
        let result = await model.stageForCleanup(apps.map {
            CleanupStageRequest(url: URL(fileURLWithPath: $0.bundlePath), size: $0.bundleBytes, reason: "Application: \($0.name)")
        })
        let rejected = Set(result.rejectedURLs.map(\.path))
        checked = Set(apps.filter { rejected.contains(URL(fileURLWithPath: $0.bundlePath).standardizedFileURL.path) }.map(\.id))
        model.showToast(result.added > 0 ? "Added \(countLabel(result.added, "app")) to Cleanup — ⇧⌘⌫ to review" : "Nothing new added")
    }

    // MARK: - Formatting

    private func lastUsedLabel(_ date: Date?) -> String {
        guard let date else { return "—" }
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days < 31 { return "\(days) d" }
        if days < 365 { return "\(days / 30) mo" }
        return "\(days / 365) y"
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
        let shortPublisher: String? = {
            if let team = bundle?.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String {
                let cleaned = cleanPublisher(team)
                if let cleaned, !cleaned.isEmpty { return cleaned }
            }
            return nil
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

    private static func cleanPublisher(_ raw: String) -> String? {
        var s = raw
        // Strip "Copyright © 2024 Company." boilerplate
        if let r = try? NSRegularExpression(pattern: #"(?i)copyright\s*(©|\(c\))?\s*\d{4}\s*"#) {
            s = r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if s.count > 48 { s = String(s.prefix(45)) + "…" }
        return s.isEmpty ? nil : s
    }
}
