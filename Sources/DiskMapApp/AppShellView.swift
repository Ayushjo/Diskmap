import AppKit
import DiskMapCore
import SwiftUI

/// Task-oriented shell (Overview / Find / Clean / Explore) matching DiskMap1/2 IA.
struct AppShellView: View {
    @ObservedObject var model: ScanModel
    @State private var showExplain = false
    @State private var showPalette = false
    @State private var showCompactSidebar = false
    @State private var searchText = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasCompletedScan: Bool { model.tree != nil }

    static let comfortablePageHeight: CGFloat = 720
    /// Destinations whose list lives in its own scroll view under a fixed
    /// header. Pages that already scroll as a whole are not listed.
    static let pageScrollsWhenShort: Set<AppDestination> = [
        .find, .biggestFiles, .biggestFolders, .forgottenFiles, .duplicates,
        .cleanSafe, .cleanCaches, .fileBrowser, .visualize, .applications,
    ]

    var body: some View {
        GeometryReader { window in
            let compactSidebar = window.size.width < 1_000
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    topBar(compactSidebar: compactSidebar)
                    Hairline()
                    HStack(spacing: 0) {
                        if !compactSidebar {
                            sidebar
                                .frame(width: DiskMapMetric.sidebarWidth)
                            Rectangle().fill(DiskMapTheme.line).frame(width: 1)
                        }
                        GeometryReader { geo in
                            let page = destinationBody
                                .environment(
                                    \.diskMapContentWidth,
                                    geo.size.width + (compactSidebar ? 0 : DiskMapMetric.sidebarWidth + 1)
                                )
                            // Screens built as "fixed header + inner list" squeezed the
                            // list to nothing in a short window (Safe to Review's list
                            // measured 56 pt at 600 pt tall, Caches' 0). Below a
                            // comfortable height they lay out at that height inside a
                            // page scroll instead, so everything stays reachable.
                            if Self.pageScrollsWhenShort.contains(model.destination), geo.size.height < Self.comfortablePageHeight {
                                ScrollView(.vertical) {
                                    page.frame(width: geo.size.width, height: Self.comfortablePageHeight)
                                }
                            } else {
                                page.frame(width: geo.size.width, height: geo.size.height)
                            }
                        }
                    }
                }

                if compactSidebar, showCompactSidebar {
                    Color.black.opacity(0.18)
                        .padding(.top, DiskMapMetric.topBarHeight + 1)
                        .ignoresSafeArea(edges: [.horizontal, .bottom])
                        .onTapGesture { showCompactSidebar = false }
                    sidebar
                        .frame(width: DiskMapMetric.sidebarWidth)
                        .padding(.top, DiskMapMetric.topBarHeight + 1)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .shadow(color: .black.opacity(0.14), radius: 16, x: 5, y: 0)
                        .onExitCommand { showCompactSidebar = false }
                }

                if let toast = model.toastMessage {
                    Text(toast)
                        .font(DiskMapType.bodyEmphasis)
                        .foregroundStyle(DiskMapTheme.ink)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(
                            Capsule().fill(DiskMapTheme.raised)
                                .overlay(Capsule().stroke(DiskMapTheme.line, lineWidth: 1))
                                .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
                        )
                        .padding(.top, DiskMapMetric.topBarHeight + 12)
                        .frame(maxWidth: .infinity)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(10)
                }

            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showCompactSidebar)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.toastMessage)
        .background(DiskMapTheme.canvas)
        .frame(minWidth: 880, minHeight: 600)
        .onChange(of: model.destination) { _, _ in model.clearMultiSelection() }
        .sheet(isPresented: $model.isCleanupQueuePresented) {
            CleanupQueueView(model: model)
                .frame(minWidth: 640, minHeight: 480)
        }
        .sheet(isPresented: $showExplain) {
            ExplainStorageSheet(model: model)
                .frame(minWidth: 520, minHeight: 420)
        }
        .overlay {
            if showPalette {
                ZStack {
                    Color.black.opacity(reduceMotion ? 0.35 : 0.25)
                        .ignoresSafeArea()
                        .onTapGesture { showPalette = false }
                        .accessibilityLabel("Dismiss command palette")
                        .accessibilityAddTraits(.isButton)
                    CommandPalette(
                        model: model,
                        isPresented: $showPalette,
                        initialQuery: searchText,
                        onReviewCleanup: { showPalette = false; model.isCleanupQueuePresented = true },
                        onExplain: { showPalette = false; showExplain = true }
                    )
                }
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .onChange(of: showPalette) { _, open in if !open { searchText = "" } }
        .onReceive(NotificationCenter.default.publisher(for: .diskMapOpenPalette)) { _ in
            if hasCompletedScan { showPalette = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .diskMapOpenExplain)) { note in
            // `object: false` closes it (the harness, after capturing).
            if hasCompletedScan { showExplain = (note.object as? Bool) ?? true }
        }
    }

    private func topBar(compactSidebar: Bool) -> some View {
        HStack(spacing: 10) {
            if compactSidebar {
                Button {
                    showCompactSidebar.toggle()
                } label: {
                    Label(showCompactSidebar ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")
                }
                .buttonStyle(IconButtonStyle())
                .help(showCompactSidebar ? "Hide Sidebar" : "Show Sidebar")
            }
            // One search field: typing opens the palette (⌘K anywhere).
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: DiskMapType.scaled(11.5), weight: .medium))
                    .foregroundStyle(DiskMapTheme.ink3)
                    .accessibilityHidden(true)
                TextField("Search files, folders and actions", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(DiskMapType.body)
                    .accessibilityLabel("Search storage")
                    .disabled(!hasCompletedScan)
                    .onSubmit {
                        guard hasCompletedScan else { return }
                        showPalette = true
                    }
                    // Typing opens the palette with what was typed so far.
                    .onChange(of: searchText) { _, text in
                        if hasCompletedScan, !text.isEmpty, !showPalette { showPalette = true }
                    }
                Button {
                    guard hasCompletedScan else { return }
                    showPalette = true
                } label: {
                    Kbd("⌘K")
                }
                .buttonStyle(.plain)
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!hasCompletedScan)
                .help(hasCompletedScan ? "Command palette" : "Scan first to search")
                .accessibilityLabel("Command palette")
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: 460)
            .frame(height: DiskMapMetric.searchHeight)
            .background(
                RoundedRectangle(cornerRadius: DiskMapRadius.control, style: .continuous)
                    .fill(DiskMapTheme.raised.opacity(0.55))
                    .overlay(RoundedRectangle(cornerRadius: DiskMapRadius.control, style: .continuous)
                        .stroke(DiskMapTheme.line, lineWidth: 1))
            )
            .opacity(hasCompletedScan ? 1 : 0.5)
            Spacer()
            if model.isScanning, model.tree != nil {
                // The first scan shows its own counter on the page.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(model.scanPhase == .checkingChanges ? "Checking changes" : "Rescanning · \(model.scannedCount.formatted())")
                        .font(DiskMapType.figureSmall)
                        .foregroundStyle(DiskMapTheme.ink2)
                        .lineLimit(1)
                }
                .layoutPriority(1)
                .accessibilityElement(children: .combine)
            }
            Button {
                model.isCleanupQueuePresented = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                    Text("Cleanup")
                    if !model.stagedItems.isEmpty {
                        Text("\(model.stagedItems.count)")
                            .font(DiskMapType.figureSmall)
                            .foregroundStyle(DiskMapTheme.onInk)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 16)
                            .background(Capsule().fill(DiskMapTheme.accent))
                    }
                }
            }
            .buttonStyle(QuietButtonStyle(tint: model.stagedItems.isEmpty ? DiskMapTheme.ink2 : DiskMapTheme.ink))
            .disabled(!hasCompletedScan)
            .help(!hasCompletedScan
                  ? "Scan first to stage cleanup"
                  : (model.stagedItems.isEmpty
                     ? "Review items staged for Trash"
                     : "\(countLabel(model.stagedItems.count, "item")) · \(ByteFormat.string(model.reclaimableBytes)) reclaimable"))
            .accessibilityLabel(model.stagedItems.isEmpty ? "Cleanup" : "Cleanup, \(countLabel(model.stagedItems.count, "item"))")
            if hasCompletedScan {
                Menu {
                    Button("Quick Update — re-read what changed") {
                        if let root = model.rootURL { Task { await model.scan(root) } }
                    }
                    Button("Full Rescan — walk every folder") {
                        if let root = model.rootURL { Task { await model.scan(root, mode: .full) } }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: DiskMapType.scaled(12.5), weight: .medium))
                        .foregroundStyle(DiskMapTheme.ink2)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                } primaryAction: {
                    if let root = model.rootURL { Task { await model.scan(root) } } else { pickFolder() }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.isScanning)
                .help("Rescan — re-reads only what changed. Hold for a full rescan.")
                .accessibilityLabel("Rescan")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: DiskMapMetric.topBarHeight)
        .background(DiskMapTheme.canvas)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            DiskMapWordmark(height: DiskMapType.scaled(30))
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(AppNavSection.allCases) { section in
                        VStack(alignment: .leading, spacing: 1) {
                            MonoLabel(section.rawValue)
                                .padding(.horizontal, 18)
                                .padding(.bottom, 5)
                            ForEach(section.items) { dest in
                                navRow(dest)
                            }
                        }
                        // TASK-081: saved Find queries, outside the numbered list.
                        if section == .find {
                            SavedSearchSection(model: model, enabled: hasCompletedScan)
                        }
                    }
                }
                .padding(.bottom, 12)
            }

            Spacer(minLength: 0)
            volumeFooter
        }
        .background(DiskMapTheme.canvas)
    }

    /// A quiet figure beside a nav item, read from catalogs already built —
    /// never builds one (catalogs stay lazy, TASK-043).
    private func navFigure(_ dest: AppDestination) -> String? {
        func bytes(_ value: Int64) -> String? { value > 0 ? ByteFormat.string(value) : nil }
        switch dest {
        case .cleanSafe: return model.isCatalogReady(.reviewables) ? bytes(model.cachedReviewableSummary.totalBytes) : nil
        case .cleanCaches: return model.isCatalogReady(.reviewables) ? bytes(model.cachedReviewableSummary.cacheBytes) : nil
        case .cleanDownloads: return model.isCatalogReady(.oldDownloads) ? bytes(model.cachedOldDownloads.summary.totalBytes) : nil
        case .cleanMedia: return model.isCatalogReady(.largeMedia) ? bytes(model.cachedLargeMedia.summary.totalBytes) : nil
        case .forgottenFiles: return model.isCatalogReady(.forgotten) ? bytes(model.cachedForgottenSummary.reviewableBytes) : nil
        case .developerStorage: return model.isCatalogReady(.developer) ? bytes(model.cachedDeveloper.summary.reclaimableBytes) : nil
        case .duplicates: return model.duplicateDidRun && !model.duplicateGroups.isEmpty ? "\(model.duplicateGroups.count)" : nil
        default: return nil
        }
    }

    private func navRow(_ dest: AppDestination) -> some View {
        let locked = dest.requiresScan && !hasCompletedScan
        let selected = model.destination == dest && !locked
        return Button {
            guard !locked else { return }
            showCompactSidebar = false
            model.destination = dest
            if dest == .visualize { model.topNav = .explore }
            if dest == .duplicates { model.topNav = .duplicates }
            if dest == .applications { model.topNav = .applications }
            if dest == .snapshots { model.topNav = .snapshots }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: dest.symbol)
                    .font(.system(size: DiskMapType.scaled(11.5), weight: .regular))
                    .foregroundStyle(selected ? DiskMapTheme.accent : DiskMapTheme.ink3)
                    .frame(width: 16)
                let label = Text(dest.label)
                    .font(selected ? DiskMapType.bodyEmphasis : DiskMapType.body)
                    .foregroundStyle(locked ? DiskMapTheme.ink3 : selected ? DiskMapTheme.ink : DiskMapTheme.ink2)
                    .lineLimit(1)
                // The figure gives way when the name needs the room.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        label.fixedSize()
                        Spacer(minLength: 4)
                        if !locked, let figure = navFigure(dest) {
                            Text(figure)
                                .font(DiskMapType.figureSmall)
                                .foregroundStyle(DiskMapTheme.ink3)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    HStack(spacing: 0) {
                        label
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: DiskMapRadius.control, style: .continuous)
                    .fill(selected ? DiskMapTheme.accentSoft : Color.clear)
            )
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .help(locked ? "Scan your Mac first." : dest.label)
        .accessibilityLabel(locked ? "\(dest.label), scan first" : navFigure(dest).map { "\(dest.label), \($0)" } ?? dest.label)
        .accessibilityAddTraits(model.destination == dest ? .isSelected : [])
    }

    /// The disk at the foot of the sidebar: name, a 2 pt bar, free space.
    private var volumeFooter: some View {
        let vol = model.analysis.volume
        return VStack(alignment: .leading, spacing: 7) {
            Hairline()
                .padding(.bottom, 5)
            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                    .font(.system(size: DiskMapType.scaled(11), weight: .regular))
                    .foregroundStyle(DiskMapTheme.ink3)
                Text(vol?.volumeName ?? "Macintosh HD")
                    .font(DiskMapType.secondary)
                    .foregroundStyle(DiskMapTheme.ink2)
                    .lineLimit(1)
            }
            ProportionBar(fraction: vol?.usedFraction ?? 0, tint: DiskMapTheme.ink.opacity(0.4), height: 2)
            Text(vol.map { "\(ByteFormat.string(Int64($0.freeBytes))) free of \(ByteFormat.string(Int64($0.totalBytes)))" } ?? "Scan to see capacity")
                .font(DiskMapType.figureSmall)
                .foregroundStyle(DiskMapTheme.ink3)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(vol.map { "\($0.volumeName), \(ByteFormat.string(Int64($0.freeBytes))) free" } ?? "Volume capacity unavailable until scan")
    }

    @ViewBuilder
    private var destinationBody: some View {
        switch model.destination {
        case .overview:
            OverviewView(
                model: model,
                pickFolder: pickFolder,
                onReviewCleanup: { model.isCleanupQueuePresented = true },
                onExplain: { showExplain = true },
                onOpenVisualize: { model.destination = .visualize },
                onSelectFile: { id in
                    model.selectedNode = id
                    model.destination = .biggestFiles
                },
                onOpenBiggestFiles: { model.destination = .biggestFiles }
            )
        case .find:
            if let tree = model.tree, let root = model.rootURL {
                FindView(model: model, tree: tree, rootURL: root)
            } else { needsScan }
        case .fileBrowser:
            if let tree = model.tree, let root = model.rootURL {
                FileBrowserView(model: model, tree: tree, rootURL: root)
            } else { needsScan }
        case .visualize:
            VisualizeView(model: model, pickFolder: pickFolder)
        case .biggestFiles:
            if let tree = model.tree, let root = model.rootURL {
                BiggestFilesView(model: model, tree: tree, rootURL: root, onOpenCleanup: { model.isCleanupQueuePresented = true })
            } else { needsScan }
        case .biggestFolders:
            if let tree = model.tree, let root = model.rootURL {
                BiggestFoldersView(model: model, tree: tree, rootURL: root, onOpenCleanup: { model.isCleanupQueuePresented = true })
            } else { needsScan }
        case .forgottenFiles:
            if let tree = model.tree, let root = model.rootURL {
                ForgottenFilesView(model: model, tree: tree, rootURL: root, onOpenCleanup: { model.isCleanupQueuePresented = true })
            } else { needsScan }
        case .duplicates:
            if let tree = model.tree, let root = model.rootURL {
                DuplicatesView(model: model, tree: tree, rootURL: root)
            } else { needsScan }
        case .cleanSafe:
            SafeToReviewView(
                model: model,
                onOpenCaches: { model.destination = .cleanCaches }
            )
        case .cleanCaches:
            CachesReviewView(
                model: model
            )
        case .cleanDownloads:
            OldDownloadsView(
                model: model,
                pickFolder: pickFolder
            )
        case .cleanMedia:
            LargeMediaView(
                model: model,
                pickFolder: pickFolder
            )
        case .developerStorage:
            DeveloperStorageView(
                model: model,
                pickFolder: pickFolder
            )
        case .applications:
            AppsView(model: model)
        case .snapshots:
            SnapshotsView(model: model)
        }
    }

    private var needsScan: some View {
        FirstScanHero(
            model: model,
            pickFolder: pickFolder,
            onScanMac: {
                model.destination = .overview
                let home = FileManager.default.homeDirectoryForCurrentUser
                Task { await model.scan(home) }
            }
        )
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.scan(url) }
    }
}

struct ExplainStorageSheet: View {
    @ObservedObject var model: ScanModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DustyPreference.key) private var showDusty = true

    var body: some View {
        let snap = model.analysis
        let stories = StorageNarrator.stories(from: snap)
        let recs = StorageNarrator.recommendations(from: snap)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: DiskMapSpace.sm) {
                if showDusty {
                    Dusty(pose: .smallCurious, width: DiskMapType.scaled(40))
                }
                VStack(alignment: .leading, spacing: 4) {
                    MonoLabel("From your last scan")
                    Text("Explain my storage")
                        .font(DiskMapType.title)
                        .foregroundStyle(DiskMapTheme.ink)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Group {
                        if let vol = snap.volume {
                            Text("Your Mac has \(ByteFormat.string(Int64(vol.freeBytes))) free of \(ByteFormat.string(Int64(vol.totalBytes))) — \(snap.health.title.lowercased()).")
                        } else {
                            Text("This covers \(ByteFormat.string(snap.scannedBytes)) from your last scan.")
                        }
                    }
                    .font(DiskMapType.heading)
                    .foregroundStyle(DiskMapTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(label: "What’s going on")
                        ForEach(stories) { story in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(story.title)
                                    .font(DiskMapType.bodyEmphasis)
                                    .foregroundStyle(DiskMapTheme.ink)
                                Text(story.detail)
                                    .font(DiskMapType.secondary)
                                    .foregroundStyle(DiskMapTheme.ink2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        SectionHeader(label: "Next steps")
                        ForEach(recs) { rec in
                            NextStepRow(rec: rec) {
                                model.destination = rec.destination
                                dismiss()
                            }
                        }
                    }

                    Text("Every figure here comes from your last local scan — nothing is estimated beyond it.")
                        .font(DiskMapType.figureSmall)
                        .foregroundStyle(DiskMapTheme.ink3)
                }
                .padding(24)
            }
        }
        .frame(minWidth: 520, minHeight: 440)
        .background(DiskMapTheme.canvas)
    }
}

/// A next step that opens the page reviewing it.
private struct NextStepRow: View {
    let rec: StorageRecommendation
    var open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Circle().fill(rec.safety == .safe ? DiskMapTheme.safe : DiskMapTheme.review).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rec.title)
                        .font(DiskMapType.bodyEmphasis)
                        .foregroundStyle(DiskMapTheme.ink)
                    Text(rec.detail)
                        .font(DiskMapType.secondary)
                        .foregroundStyle(DiskMapTheme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(ByteFormat.string(rec.bytes))
                    .font(DiskMapType.figure)
                    .foregroundStyle(DiskMapTheme.ink)
                Text("Review")
                    .font(DiskMapType.secondary)
                    .foregroundStyle(DiskMapTheme.accent)
                Image(systemName: "chevron.right")
                    .font(.system(size: DiskMapType.scaled(10), weight: .semibold))
                    .foregroundStyle(DiskMapTheme.accent)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RowBackground(selected: false, hovering: hovering))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, -10)
        .accessibilityLabel("\(rec.title), \(ByteFormat.string(rec.bytes)). Review")
    }
}

extension Notification.Name {
    /// Opens the command palette (the harness's `--palette`).
    static let diskMapOpenPalette = Notification.Name("DiskMapOpenPalette")
    /// Opens the Explain sheet (the harness's `--sheet explain`).
    static let diskMapOpenExplain = Notification.Name("DiskMapOpenExplain")
}
