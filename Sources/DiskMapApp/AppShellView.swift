import AppKit
import DiskMapCore
import SwiftUI

/// Task-oriented shell (Overview / Find / Clean / Explore) matching DiskMap1/2 IA.
struct AppShellView: View {
    @ObservedObject var model: ScanModel
    @State private var showCleanup = false
    @State private var showExplain = false
    @State private var showPalette = false
    @State private var searchText = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                topBar
                Divider().overlay(DiskMapTheme.cardStroke)
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: 220)
                    Divider().overlay(DiskMapTheme.cardStroke)
                    destinationBody
                }
            }
            if let toast = model.toastMessage {
                Text(toast)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(DiskMapTheme.ink.opacity(0.92)))
                    .padding(.top, 56)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.toastMessage)
        .background(DiskMapTheme.cream)
        .preferredColorScheme(.light)
        .frame(minWidth: 1180, minHeight: 740)
        .sheet(isPresented: $showCleanup) {
            CleanupQueueView(model: model)
                .frame(minWidth: 640, minHeight: 480)
                .preferredColorScheme(.light)
        }
        .sheet(isPresented: $showExplain) {
            ExplainStorageSheet(model: model)
                .frame(minWidth: 520, minHeight: 420)
                .preferredColorScheme(.light)
        }
        .overlay {
            if showPalette {
                ZStack {
                    Color.black.opacity(reduceMotion ? 0.35 : 0.25)
                        .ignoresSafeArea()
                        .onTapGesture { showPalette = false }
                        .accessibilityLabel("Dismiss command palette")
                        .accessibilityAddTraits(.isButton)
                    CommandPalette(model: model, isPresented: $showPalette, initialQuery: searchText, onReviewCleanup: { showPalette = false; showCleanup = true })
                }
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DiskMapTheme.mutedLabel)
            TextField("Search files, folders or ask anything… (⌘K)", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .accessibilityLabel("Search storage")
                .onSubmit { showPalette = true }
            Button {
                showPalette = true
            } label: {
                Text("⌘K")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(DiskMapTheme.navSelected))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)
            Spacer()
            Button {
                showCleanup = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                    Text(model.stagedItems.isEmpty ? "Cleanup" : "Cleanup (\(model.stagedItems.count))")
                }
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(InkButtonStyle(filled: !model.stagedItems.isEmpty))
            .help("Review items staged for Trash")
            Button {
                if let root = model.rootURL {
                    Task { await model.scan(root) }
                } else {
                    pickFolder()
                }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(InkButtonStyle(filled: false))
            .disabled(model.isScanning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(DiskMapTheme.cardFill)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DiskMapTheme.ink)
                    .frame(width: 28, height: 28)
                    .overlay(Text("D").font(.system(size: 13, weight: .bold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 1) {
                    Text("DiskMap")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                    Text("Understand your storage.")
                        .font(.system(size: 10))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(AppNavSection.allCases) { section in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.rawValue.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.8)
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 2)
                            ForEach(section.items) { dest in
                                navRow(dest)
                            }
                        }
                    }
                }
                .padding(.bottom, 12)
            }

            Spacer(minLength: 0)
            volumeChip
                .padding(12)
        }
        .background(DiskMapTheme.sidebarFill)
    }

    private func navRow(_ dest: AppDestination) -> some View {
        Button {
            model.destination = dest
            if dest == .visualize { model.topNav = .explore }
            if dest == .duplicates { model.topNav = .duplicates }
            if dest == .applications { model.topNav = .applications }
            if dest == .snapshots { model.topNav = .snapshots }
            if dest == .biggestFiles { model.exploreMode = .topSizes }
            if dest == .biggestFolders { model.exploreMode = .folders }
            if dest == .forgottenFiles { model.exploreMode = .ageMap }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: dest.symbol)
                    .font(.system(size: 12))
                    .frame(width: 18)
                Text(dest.label)
                    .font(.system(size: 13, weight: model.destination == dest ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(DiskMapTheme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(model.destination == dest ? DiskMapTheme.navSelected : Color.clear)
            )
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
            .accessibilityLabel(dest.label)
            .accessibilityAddTraits(model.destination == dest ? .isSelected : [])
    }

    private var volumeChip: some View {
        let vol = model.analysis.volume
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "internaldrive.fill")
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                Text(vol?.volumeName ?? "No volume")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.ink)
            }
            if let vol {
                ProportionBar(fraction: vol.usedFraction, tint: DiskMapTheme.ink.opacity(0.45))
                Text("\(ByteFormat.string(Int64(vol.totalBytes))) total · \(ByteFormat.string(Int64(vol.freeBytes))) free")
                    .font(.system(size: 10))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            } else {
                Text("Scan to see capacity")
                    .font(.system(size: 10))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DiskMapTheme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var destinationBody: some View {
        switch model.destination {
        case .overview:
            OverviewView(
                model: model,
                pickFolder: pickFolder,
                onReviewCleanup: { showCleanup = true },
                onExplain: { showExplain = true },
                onOpenVisualize: { model.destination = .visualize },
                onSelectFile: { id in
                    model.selectedNode = id
                    model.destination = .biggestFiles
                },
                onOpenBiggestFiles: { model.destination = .biggestFiles }
            )
        case .fileBrowser:
            if let tree = model.tree, let root = model.rootURL {
                FileBrowserView(model: model, tree: tree, rootURL: root, onOpenCleanup: { showCleanup = true })
            } else { needsScan }
        case .visualize:
            VisualizeView(model: model, pickFolder: pickFolder, onOpenCleanup: { showCleanup = true })
        case .biggestFiles:
            if let tree = model.tree, let root = model.rootURL {
                BiggestFilesView(model: model, tree: tree, rootURL: root, onOpenCleanup: { showCleanup = true })
            } else { needsScan }
        case .biggestFolders:
            if let tree = model.tree, let root = model.rootURL {
                BiggestFoldersView(model: model, tree: tree, rootURL: root, onOpenCleanup: { showCleanup = true })
            } else { needsScan }
        case .forgottenFiles:
            if let tree = model.tree, let root = model.rootURL {
                ForgottenFilesView(model: model, tree: tree, rootURL: root, onOpenCleanup: { showCleanup = true })
            } else { needsScan }
        case .duplicates:
            if let tree = model.tree, let root = model.rootURL {
                DuplicatesView(model: model, tree: tree, rootURL: root)
            } else { needsScan }
        case .cleanSafe:
            SafeToReviewView(
                model: model,
                onOpenCleanup: { showCleanup = true },
                onOpenCaches: { model.destination = .cleanCaches }
            )
        case .cleanCaches:
            CachesReviewView(
                model: model,
                onOpenCleanup: { showCleanup = true },
                onBack: { model.destination = .cleanSafe }
            )
        case .cleanDownloads:
            OldDownloadsView(
                model: model,
                onOpenCleanup: { showCleanup = true },
                pickFolder: pickFolder
            )
        case .cleanMedia:
            LargeMediaView(
                model: model,
                onOpenCleanup: { showCleanup = true },
                pickFolder: pickFolder
            )
        case .developerStorage:
            DeveloperStorageView(
                model: model,
                pickFolder: pickFolder,
                onOpenCleanup: { showCleanup = true }
            )
        case .applications:
            AppsView(
                model: model,
                onOpenCleanup: { showCleanup = true }
            )
        case .snapshots:
            SnapshotsView(model: model)
        }
    }

    private var forgottenBlurb: String {
        "Files not modified in over a year. Dates are last-modified — macOS often lacks a reliable last-opened stamp."
    }

    @ViewBuilder
    private var forgottenTrailing: some View {
        if model.tree != nil {
            if model.analysis.forgottenBytes > 0 {
                Text(ByteFormat.string(model.analysis.forgottenBytes) + " forgotten")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DiskMapTheme.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(DiskMapTheme.navSelected)
                    )
            }
        }
    }

    @ViewBuilder
    private func findWrapper<Content: View>(
        title: String,
        blurb: String,
        @ViewBuilder content: (FileTree, URL) -> Content
    ) -> some View {
        findWrapper(title: title, blurb: blurb, trailing: { EmptyView() }, content: content)
    }

    @ViewBuilder
    private func findWrapper<Content: View, Trailing: View>(
        title: String,
        blurb: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: (FileTree, URL) -> Content
    ) -> some View {
        if model.isScanning {
            ProgressView("Scanning… \(model.scannedCount)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let tree = model.tree, let root = model.rootURL, model.selectedTotals.count == tree.count {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(DiskMapType.title)
                            .foregroundStyle(DiskMapTheme.ink)
                        Text(blurb)
                            .font(DiskMapType.body)
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                    Spacer(minLength: 8)
                    trailing()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider().overlay(DiskMapTheme.cardStroke)
                content(tree, root)
            }
            .background(DiskMapTheme.cream)
        } else {
            needsScan
        }
    }

    private var needsScan: some View {
        VStack(spacing: 12) {
            Text("Scan first to see what's using space")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DiskMapTheme.ink)
            Text("Pick a folder (or your home directory) — DiskMap never invents filesystem facts.")
                .font(DiskMapType.body)
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Choose Folder…", action: pickFolder)
                .buttonStyle(InkButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    var body: some View {
        let snap = model.analysis
        let stories = StorageNarrator.stories(from: snap)
        let recs = StorageNarrator.recommendations(from: snap)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Explain my storage")
                        .font(DiskMapType.title)
                    Spacer()
                    Button("Done") { dismiss() }
                }
                if let vol = snap.volume {
                    Text("Your Mac has \(ByteFormat.string(Int64(vol.freeBytes))) free of \(ByteFormat.string(Int64(vol.totalBytes))) (\(snap.health.title.lowercased())).")
                        .foregroundStyle(DiskMapTheme.ink)
                } else {
                    Text("This explanation covers \(ByteFormat.string(snap.scannedBytes)) from your last local scan.")
                        .foregroundStyle(DiskMapTheme.ink)
                }
                Text("What's going on")
                    .font(DiskMapType.section)
                ForEach(stories) { story in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(story.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DiskMapTheme.ink)
                        Text(story.detail)
                            .font(DiskMapType.caption)
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
                Text("Suggested next steps")
                    .font(DiskMapType.section)
                    .padding(.top, 6)
                ForEach(recs) { rec in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rec.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(DiskMapTheme.ink)
                            Text(rec.detail)
                                .font(DiskMapType.caption)
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                        }
                        Spacer()
                        Text(ByteFormat.string(rec.bytes))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    }
                }
                Text("Every figure above comes from your last local scan — nothing was invented.")
                    .font(DiskMapType.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .padding(.top, 8)
            }
            .padding(24)
        }
        .frame(minWidth: 480, minHeight: 420)
        .background(DiskMapTheme.cream)
    }
}
