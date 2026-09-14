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

    var body: some View {
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
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .onTapGesture { showPalette = false }
                    CommandPalette(model: model, isPresented: $showPalette, onReviewCleanup: { showPalette = false; showCleanup = true })
                }
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
            if dest == .fileBrowser { model.exploreMode = .folders }
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
                    model.currentNode = model.tree?.parent[Int(id)] ?? 0
                    model.destination = .visualize
                    model.exploreMode = .treemap
                }
            )
        case .visualize, .fileBrowser:
            ExploreShellView(model: model, pickFolder: pickFolder)
        case .biggestFiles:
            findWrapper(title: "Biggest Files", blurb: "Largest items in this scan. Select one to inspect or review.") { tree, root in
                TopSizesView(tree: tree, totals: model.selectedTotals, rootURL: root, selectedNode: $model.selectedNode)
            }
        case .biggestFolders:
            findWrapper(title: "Biggest Folders", blurb: "Browse the largest folders. Click to drill in.") { tree, root in
                FoldersView(tree: tree, totals: model.selectedTotals, rootURL: root, currentNode: $model.currentNode, selectedNode: $model.selectedNode)
            }
        case .forgottenFiles:
            findWrapper(title: "Forgotten Files", blurb: "Based on modification date — access time is not always reliable on macOS.") { tree, root in
                AgeMapView(model: model, tree: tree, totals: model.selectedTotals, rootURL: root)
            }
        case .duplicates:
            if let tree = model.tree, let root = model.rootURL {
                DuplicatesView(model: model, tree: tree, rootURL: root)
            } else { needsScan }
        case .cleanSafe, .cleanCaches, .cleanDownloads, .cleanMedia:
            CleanReviewView(model: model, mode: model.destination, showCleanup: $showCleanup, pickFolder: pickFolder)
        case .developerStorage:
            DeveloperStorageView(model: model, pickFolder: pickFolder)
        case .applications:
            AppsView(model: model)
        case .snapshots:
            if let tree = model.tree, let root = model.rootURL {
                SnapshotDiffView(tree: tree, rootURL: root, basis: model.sizeBasis)
            } else { needsScan }
        }
    }

    @ViewBuilder
    private func findWrapper<Content: View>(title: String, blurb: String, @ViewBuilder content: (FileTree, URL) -> Content) -> some View {
        if model.isScanning {
            ProgressView("Scanning… \(model.scannedCount)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let tree = model.tree, let root = model.rootURL, model.selectedTotals.count == tree.count {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(DiskMapType.title)
                        .foregroundStyle(DiskMapTheme.ink)
                    Text(blurb)
                        .font(DiskMapType.body)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
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
            Text("Pick a folder to see what's using space")
                .foregroundStyle(DiskMapTheme.mutedLabel)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Explain my storage")
                    .font(DiskMapType.title)
                Spacer()
                Button("Done") { dismiss() }
            }
            let snap = model.analysis
            if let vol = snap.volume {
                Text("Your Mac has \(ByteFormat.string(Int64(vol.freeBytes))) free of \(ByteFormat.string(Int64(vol.totalBytes))).")
                    .foregroundStyle(DiskMapTheme.ink)
            }
            Text("Largest storage consumers:")
                .font(DiskMapType.section)
            ForEach(Array(snap.categories.prefix(5).enumerated()), id: \.element.id) { idx, cat in
                Text("\(idx + 1). \(cat.title) — \(ByteFormat.string(cat.bytes))")
                    .foregroundStyle(DiskMapTheme.ink)
            }
            Text("Worth reviewing:")
                .font(DiskMapType.section)
                .padding(.top, 6)
            Text("• \(ByteFormat.string(snap.quickWinBytes)) in known regenerable locations (caches / build artifacts)")
            Text("• \(ByteFormat.string(snap.forgottenBytes)) in files not modified in over a year")
            Text("Every figure above comes from your last local scan — nothing was invented.")
                .font(DiskMapType.caption)
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .padding(.top, 8)
            Spacer()
        }
        .padding(24)
        .background(DiskMapTheme.cream)
    }
}
