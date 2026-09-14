import AppKit
import DiskMapCore
import SwiftUI

/// Persistent 3-panel Explore shell. View-modes swap only the center canvas.
struct ExploreShellView: View {
    @ObservedObject var model: ScanModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var pickFolder: () -> Void
    @State private var showCleanup = false

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                ExploreSidebar(model: model, pickFolder: pickFolder)
                    .frame(width: 280)
                Divider().background(DiskMapTheme.cardStroke)
                center
                Divider().background(DiskMapTheme.cardStroke)
                ExploreInspector(model: model, showCleanup: $showCleanup)
                    .frame(width: 300)
                    .background(DiskMapTheme.inspectorFill)
            }
            if let toast = model.toastMessage {
                Text(toast)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(DiskMapTheme.ink.opacity(0.92)))
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.toastMessage)
        .background(DiskMapTheme.cream)
        .sheet(isPresented: $showCleanup) {
            CleanupQueueView(model: model)
                .frame(minWidth: 640, minHeight: 480)
                .preferredColorScheme(.light)
        }
    }

    @ViewBuilder
    private var center: some View {
        if model.isScanning {
            VStack(spacing: 12) {
                ProgressView()
                Text("Scanning… \(model.scannedCount) items")
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let tree = model.tree, let root = model.rootURL,
                  model.selectedTotals.count == tree.count {
            VStack(spacing: 0) {
                canvasHeader(tree: tree, root: root)
                viewPickerRow
                Divider().overlay(DiskMapTheme.cardStroke)
                ExploreCanvas(
                    model: model,
                    tree: tree,
                    totals: model.selectedTotals,
                    rootURL: root
                )
                if model.exploreMode.showsLayoutControls || model.exploreMode == .folders {
                    LargestItemsStrip(model: model, tree: tree, root: root)
                        .frame(height: 160)
                }
            }
        } else {
            VStack(spacing: 14) {
                Text("Scan first to explore")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.ink)
                Text("Where is the space? What have I forgotten? Pick a folder to open Treemap, Age Map, and the other views.")
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Scan Full Mac") {
                    Task { await model.scan(URL(fileURLWithPath: "/", isDirectory: true)) }
                }
                .buttonStyle(InkButtonStyle())
                Button("Choose Folder…", action: pickFolder)
                    .buttonStyle(InkButtonStyle(filled: false))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }


    private func canvasHeader(tree: FileTree, root: URL) -> some View {
        let node = model.currentNode
        let idx = Int(node)
        let files = model.descendantFileCounts.indices.contains(idx) ? model.descendantFileCounts[idx] : 0
        let folders = model.descendantFolderCounts.indices.contains(idx) ? model.descendantFolderCounts[idx] : 0
        let size = model.selectedTotals.indices.contains(idx) ? model.selectedTotals[idx] : 0
        let scanTotal = model.selectedTotals.first ?? 0
        let ofDisk = scanTotal > 0 ? Double(size) / Double(scanTotal) : 0
        let crumbs = tree.ancestorIDs(of: node)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Array(crumbs.enumerated()), id: \.element) { i, id in
                    if i > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                    Button {
                        model.currentNode = id
                        model.selectedNode = id
                    } label: {
                        Text(id == 0 ? (VolumeStats.forPath(root.path)?.volumeName ?? tree.name(of: id)) : tree.name(of: id))
                            .font(.system(size: 12, weight: id == node ? .semibold : .regular))
                            .foregroundStyle(id == node ? DiskMapTheme.ink : DiskMapTheme.info)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 8)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Visualize Storage")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.ink)
                Text("This folder uses \(ByteFormat.string(size)) (\(String(format: "%.1f%%", ofDisk * 100)) of scan)")
                    .font(.system(size: 12))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                Spacer(minLength: 8)
                Text("\(files.formatted()) files · \(folders.formatted()) folders")
                    .font(.system(size: 11))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var viewPickerRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(ExploreViewMode.allCases) { mode in
                    Button {
                        model.exploreMode = mode
                    } label: {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(model.exploreMode == mode ? Color.white : DiskMapTheme.ink.opacity(0.7))
                            .frame(width: 32, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(model.exploreMode == mode ? DiskMapTheme.ink : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("\(mode.rawValue) — \(mode.blurb)")
                    .accessibilityIdentifier("explore-mode-\(mode.rawValue)")
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DiskMapTheme.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                    )
            )

            HStack(spacing: 6) {
                Text(model.exploreMode.rawValue)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.ink)
                Text("·")
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                Text(model.exploreMode.blurb)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if model.exploreMode.showsLayoutControls {
                Picker("", selection: $model.colorMode) {
                    ForEach(ExploreColorMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)

                HStack(spacing: 8) {
                    Image(systemName: "square.3.layers.3d")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                    Slider(value: $model.depthLevel, in: 1...12, step: 1)
                        .frame(width: 110)
                    Text("\(Int(model.depthLevel))")
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(DiskMapTheme.ink)
                        .frame(width: 22, alignment: .trailing)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}


struct ExploreSidebar: View {
    @ObservedObject var model: ScanModel
    var pickFolder: () -> Void

    private var volume: VolumeStats? {
        VolumeStats.forPath(model.rootURL?.path ?? NSHomeDirectory())
    }


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button("Scan Full Mac") {
                    Task { await model.scan(URL(fileURLWithPath: "/", isDirectory: true)) }
                }
                .buttonStyle(InkButtonStyle())
                .frame(maxWidth: .infinity)

                HStack(spacing: 8) {
                    Button("Home") {
                        Task { await model.scan(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) }
                    }
                    .buttonStyle(.bordered)
                    Button("Folder…", action: pickFolder)
                        .buttonStyle(.bordered)
                }

                sectionRecent
                sectionDisk
                sectionCurrent
                sectionQuickWins
                sectionFileTypes
            }
            .padding(14)
        }
        .background(DiskMapTheme.cream)
    }

    private var sectionRecent: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: "Recent")
            if model.recentRoots.isEmpty {
                Text("No recent scans")
                    .font(.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            } else {
                ForEach(model.recentRoots.prefix(6), id: \.path) { url in
                    Button {
                        Task { await model.scan(url) }
                    } label: {
                        Label(url.lastPathComponent, systemImage: "clock")
                            .font(.system(size: 12))
                            .foregroundStyle(DiskMapTheme.ink)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var sectionDisk: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Disk Storage")
            if let volume {
                PanelCard {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .stroke(DiskMapTheme.cardStroke, lineWidth: 8)
                            Circle()
                                .trim(from: 0, to: volume.usedFraction)
                                .stroke(DiskMapTheme.ink, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text(String(format: "%.0f%%", volume.usedFraction * 100))
                                .font(.system(size: 11, weight: .bold))
                        }
                        .frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(volume.volumeName).font(.system(size: 13, weight: .semibold))
                            Text("Total \(byte(volume.totalBytes))")
                            Text("Used \(byte(volume.usedBytes))")
                            Text("Free \(byte(volume.freeBytes))")
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(DiskMapTheme.ink)
                    }
                }
            }
        }
    }

    private var sectionCurrent: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: "Current View")
            PanelCard {
                VStack(alignment: .leading, spacing: 4) {
                    if let tree = model.tree, model.currentNode < tree.count {
                        Text(tree.name(of: model.currentNode))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DiskMapTheme.ink)
                        if let root = model.rootURL {
                            Text(tree.path(of: model.currentNode, root: root).path)
                                .font(.system(size: 10))
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                                .lineLimit(2)
                        }
                    } else {
                        Text("No scan yet").foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                    if let secs = model.lastScanSeconds {
                        Text(String(format: "Last scan %.1fs", secs))
                            .font(.caption)
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                }
            }
        }
    }

    private var sectionQuickWins: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: "Quick Wins")
            let hits = model.cachedQuickWins
            if hits.isEmpty {
                Text("Scan to see regenerable folders")
                    .font(.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            } else {
                ForEach(hits.prefix(8), id: \.id) { hit in
                    Button {
                        model.selectedNode = hit.id
                        model.currentNode = model.tree?.parent[Int(hit.id)] ?? 0
                    } label: {
                        HStack {
                            Image(systemName: "bolt.fill").foregroundStyle(DiskMapTheme.ink.opacity(0.7))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(hit.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(DiskMapTheme.ink)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if model.tree != nil, Int(hit.id) < model.allocatedTotals.count {
                                Text(byte(UInt64(max(0, model.allocatedTotals[Int(hit.id)]))))
                                    .font(.system(size: 11).monospacedDigit())
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var sectionFileTypes: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: "File Types")
            let rows = model.cachedFileTypes
            if rows.isEmpty {
                Text("Scan to classify files")
                    .font(.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            } else {
                let total = max(1, rows.reduce(Int64(0)) { $0 + $1.bytes })
                PanelCard {
                    VStack(alignment: .leading, spacing: 8) {
                        GeometryReader { geo in
                            HStack(spacing: 1) {
                                ForEach(rows, id: \.categoryID) { row in
                                    DiskMapTheme.hex(row.colorHex)
                                        .frame(width: geo.size.width * CGFloat(row.bytes) / CGFloat(total))
                                }
                            }
                        }
                        .frame(height: 10)
                        .clipShape(Capsule())
                        ForEach(rows, id: \.categoryID) { row in
                            HStack(spacing: 8) {
                                Circle().fill(DiskMapTheme.hex(row.colorHex)).frame(width: 8, height: 8)
                                Text(row.label)
                                    .font(.system(size: 11))
                                    .foregroundStyle(DiskMapTheme.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(byte(UInt64(row.bytes)))
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(DiskMapTheme.mutedLabel)
                            }
                        }
                    }
                }
            }
        }
    }

    private func byte(_ v: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .file)
    }
}

struct ExploreInspector: View {
    @ObservedObject var model: ScanModel
    @Binding var showCleanup: Bool
    @State private var confirmCleanup = false

    var body: some View {
        Group {
            if let tree = model.tree, let root = model.rootURL,
               model.selectedTotals.count == tree.count,
               model.selectedNode >= 0, Int(model.selectedNode) < tree.count {
                inspector(tree: tree, root: root, id: model.selectedNode)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Storage context")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DiskMapTheme.ink)
                        Text("Select a file or folder to see what it is, why it’s large, and whether it’s safe to review.")
                            .font(.system(size: 12))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                        if model.analysis.reviewableBytes > 0 {
                            Text("\(ByteFormat.string(model.analysis.reviewableBytes)) worth reviewing in this scan.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(DiskMapTheme.safe)
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    private func inspector(tree: FileTree, root: URL, id: Int32) -> some View {
        let idx = Int(id)
        let logical = model.logicalTotals.indices.contains(idx) ? model.logicalTotals[idx] : 0
        let onDisk = model.allocatedTotals.indices.contains(idx) ? model.allocatedTotals[idx] : 0
        let active = model.sizeBasis == .logical ? logical : onDisk
        let compressed = max(0, logical - onDisk)
        let scanTotal = model.selectedTotals.first ?? 0
        let parentID = tree.parent[idx]
        let parentSize = parentID >= 0 && Int(parentID) < model.selectedTotals.count ? model.selectedTotals[Int(parentID)] : scanTotal
        let ofParent = parentSize > 0 ? Double(active) / Double(parentSize) : 0
        let ofScan = scanTotal > 0 ? Double(active) / Double(scanTotal) : 0
        let children = tree.children(of: id, totals: model.selectedTotals).sorted { $0.size > $1.size }
        let fileCount = model.descendantFileCounts.indices.contains(idx) ? model.descendantFileCounts[idx] : 0
        let folderCount = model.descendantFolderCounts.indices.contains(idx) ? model.descendantFolderCounts[idx] : 0
        let day = tree.modifiedDay[idx]
        let created = tree.createdDay[idx]
        let itemURL = tree.path(of: id, root: root)
        let alreadyStaged = model.isStaged(itemURL)
        let safety = SafetyClassifier.assess(
            path: itemURL.path,
            name: tree.name(of: id),
            isDirectory: tree.isDirectory[idx]
        )

        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: tree.isDirectory[idx] ? "folder.fill" : "doc")
                        .font(.title2)
                        .foregroundStyle(DiskMapTheme.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tree.name(of: id))
                            .font(.headline)
                            .foregroundStyle(DiskMapTheme.ink)
                        Text(tree.isDirectory[idx] ? "Folder" : "File")
                            .font(.caption)
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                        Text(tree.path(of: id, root: root).path)
                            .font(.system(size: 10))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                            .textSelection(.enabled)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(byte(active))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(DiskMapTheme.ink)
                    Text(id == 0 ? String(format: "%.1f%% of scan", ofScan * 100) : String(format: "%.1f%% of parent", ofParent * 100))
                        .font(.caption)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }

                PanelCard {
                    VStack(spacing: 6) {
                        StatRow(label: "Size on disk", value: byte(onDisk))
                        StatRow(label: "Logical size", value: byte(logical))
                        StatRow(label: "Compressed by", value: byte(compressed), emphasize: compressed > 0)
                        StatRow(label: "Files", value: "\(fileCount)")
                        StatRow(label: "Folders", value: "\(folderCount)")
                        if id != 0 {
                            StatRow(label: "Of parent", value: String(format: "%.1f%%", ofParent * 100))
                        }
                        StatRow(label: "Modified", value: relativeDay(day))
                        StatRow(label: "Created", value: relativeDay(created))
                    }
                }

                PanelCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What is this?")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DiskMapTheme.ink)
                        Text(safety.title == tree.name(of: id) ? (tree.isDirectory[idx] ? "Folder in your scan." : "File in your scan.") : safety.title)
                            .font(.system(size: 12))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                        HStack {
                            Text(safety.level.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(safety.level == .safe ? DiskMapTheme.safe : (safety.level == .protected ? DiskMapTheme.danger : DiskMapTheme.review))
                            Spacer()
                        }
                        Text(safety.reason)
                            .font(.system(size: 11))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if tree.isDirectory[idx], let top = children.first {
                    PanelCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Why is it large?")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(DiskMapTheme.ink)
                            ForEach(Array(children.prefix(3).enumerated()), id: \.element.id) { _, child in
                                HStack {
                                    Text(tree.name(of: child.id))
                                        .font(.system(size: 12))
                                        .foregroundStyle(DiskMapTheme.ink)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(byte(child.size))
                                        .font(.system(size: 11).monospacedDigit())
                                        .foregroundStyle(DiskMapTheme.mutedLabel)
                                }
                            }
                            Text("Dominant contributor: \(tree.name(of: top.id))")
                                .font(.system(size: 11))
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("What's inside?")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                    PanelCard {
                        VStack(spacing: 8) {
                            ForEach(Array(children.prefix(8).enumerated()), id: \.element.id) { _, child in
                                let frac = active > 0 ? Double(child.size) / Double(active) : 0
                                Button {
                                    model.selectedNode = child.id
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(tree.name(of: child.id))
                                                .font(.system(size: 12))
                                                .foregroundStyle(DiskMapTheme.ink)
                                                .lineLimit(1)
                                            Spacer()
                                            Text(byte(child.size))
                                                .font(.system(size: 11).monospacedDigit())
                                                .foregroundStyle(DiskMapTheme.mutedLabel)
                                        }
                                        ProportionBar(fraction: frac)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            if children.isEmpty {
                                Text("No children").font(.caption).foregroundStyle(DiskMapTheme.mutedLabel)
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    actionButton("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([tree.path(of: id, root: root)])
                    }
                    actionButton("Quick Look") {
                        QuickLookPresenter.shared.present(tree.path(of: id, root: root))
                    }
                    actionButton("Focus") {
                        if tree.isDirectory[idx] {
                            model.currentNode = id
                            model.selectedNode = id
                        }
                    }
                    actionButton("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(tree.path(of: id, root: root).path, forType: .string)
                    }
                }

                Button {
                    confirmCleanup = true
                } label: {
                    Text(alreadyStaged ? "Already in review" : "Review cleanup")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(alreadyStaged ? DiskMapTheme.mutedLabel : .white)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(alreadyStaged ? DiskMapTheme.cardStroke : DiskMapTheme.ink)
                        )
                }
                .buttonStyle(.plain)
                .disabled(alreadyStaged)
                .confirmationDialog(
                    "Add to cleanup review?",
                    isPresented: $confirmCleanup,
                    titleVisibility: .visible
                ) {
                    Button("Add to review") {
                        let size = model.allocatedTotals[idx]
                        let name = tree.name(of: id)
                        Task {
                            let ok = await model.cleanupQueue.stage(itemURL, size: size, reason: "review cleanup")
                            await model.refreshQueue()
                            model.showToast(ok ? "Added “\(name)” to Cleanup" : "Couldn’t add — excluded or already queued")
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(tree.path(of: id, root: root).path)
                }

                Button("Open Cleanup Queue") { showCleanup = true }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DiskMapTheme.ink)
            }
            .padding(14)
        }
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DiskMapTheme.ink)
            .buttonStyle(.bordered)
            .tint(DiskMapTheme.ink)
    }

    private func byte(_ v: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: v, countStyle: .file)
    }

    private func relativeDay(_ day: Int32) -> String {
        guard day > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: TimeInterval(day) * 86400)
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

}

struct ExploreCanvas: View {
    @ObservedObject var model: ScanModel
    let tree: FileTree
    let totals: [Int64]
    let rootURL: URL

    private var otherFraction: Double {
        // Map depth slider 1…12 onto a collapse fraction (shallower → more Other).
        let t = (12 - model.depthLevel) / 11
        return max(0.001, 0.002 + t * 0.04)
    }

    var body: some View {
        Group {
            switch model.exploreMode {
            case .treemap:
                ExploreTreemapView(
                    tree: tree,
                    totals: totals,
                    currentNode: $model.currentNode,
                    selectedNode: $model.selectedNode,
                    colorMode: model.colorMode,
                    categories: model.fileTypeCategories
                )
            case .sunburst:
                LayoutChartView(kind: .sunburst, tree: tree, totals: totals, currentNode: $model.currentNode, selectedNode: $model.selectedNode, otherFraction: otherFraction, colorMode: model.colorMode, categories: model.fileTypeCategories)
                    .onChange(of: model.currentNode) { _, v in model.selectedNode = v }
            case .flame:
                LayoutChartView(kind: .flame, tree: tree, totals: totals, currentNode: $model.currentNode, selectedNode: $model.selectedNode, otherFraction: otherFraction, colorMode: model.colorMode, categories: model.fileTypeCategories)
                    .onChange(of: model.currentNode) { _, v in model.selectedNode = v }
            case .bubbles:
                LayoutChartView(kind: .bubbles, tree: tree, totals: totals, currentNode: $model.currentNode, selectedNode: $model.selectedNode, otherFraction: otherFraction, colorMode: model.colorMode, categories: model.fileTypeCategories)
                    .onChange(of: model.currentNode) { _, v in model.selectedNode = v }
            case .mindMap:
                LayoutChartView(kind: .mindMap, tree: tree, totals: totals, currentNode: $model.currentNode, selectedNode: $model.selectedNode, otherFraction: otherFraction, colorMode: model.colorMode, categories: model.fileTypeCategories)
                    .onChange(of: model.currentNode) { _, v in model.selectedNode = v }
            case .topSizes:
                TopSizesView(tree: tree, totals: totals, rootURL: rootURL, selectedNode: $model.selectedNode)
            case .ageMap:
                AgeMapView(model: model, tree: tree, totals: totals, rootURL: rootURL)
            case .folders:
                FoldersView(tree: tree, totals: totals, rootURL: rootURL, currentNode: $model.currentNode, selectedNode: $model.selectedNode)
                    .onChange(of: model.currentNode) { _, v in model.selectedNode = v }
            }
        }
    }
}


/// Treemap canvas with selection + By folder/type/age coloring.
struct ExploreTreemapView: View {
    let tree: FileTree
    let totals: [Int64]
    @Binding var currentNode: Int32
    @Binding var selectedNode: Int32
    var colorMode: ExploreColorMode
    var categories: [FileTypeCategory]

    @State private var layoutRects: [TreemapRect] = []
    @State private var canvasSize: CGSize = .zero


    var body: some View {
        VStack(spacing: 0) {
            HStack {
                BreadcrumbBar(tree: tree, currentNode: currentNode) { id in
                    currentNode = id
                    selectedNode = id
                    cacheLayout()
                }
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: currentSize, countStyle: .file))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
            .padding(8)

            Canvas { context, size in
                let items = tree.children(of: currentNode, totals: totals)
                let rects = SquarifiedTreemap.layout(items: items, in: CGRect(origin: .zero, size: size))
                for r in rects {
                    let inset = r.rect.insetBy(dx: 1, dy: 1)
                    let path = Path(inset)
                    let selected = r.id == selectedNode
                    context.fill(path, with: .color(colorFor(id: r.id)))
                    context.stroke(path, with: .color(selected ? DiskMapTheme.ink : .black.opacity(0.25)), lineWidth: selected ? 2 : 1)
                    if inset.width > 52 && inset.height > 20 {
                        context.draw(
                            Text(tree.name(of: r.id)).font(.caption.weight(.semibold)).foregroundStyle(DiskMapTheme.ink),
                            at: CGPoint(x: inset.minX + 4, y: inset.minY + 4),
                            anchor: .topLeading
                        )
                    }
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { cacheLayout(in: proxy.size) }
                        .onChange(of: proxy.size) { _, s in cacheLayout(in: s) }
                }
            }
            .gesture(
                SpatialTapGesture(count: 2).onEnded { event in
                    guard let hit = SquarifiedTreemap.hitTest(layoutRects, at: event.location) else { return }
                    selectedNode = hit
                    if tree.isDirectory[Int(hit)] {
                        currentNode = hit
                        cacheLayout()
                    }
                }
            )
            .simultaneousGesture(
                SpatialTapGesture().onEnded { event in
                    guard let hit = SquarifiedTreemap.hitTest(layoutRects, at: event.location) else { return }
                    selectedNode = hit
                }
            )
        }
        .onChange(of: currentNode) { _, _ in cacheLayout() }
        .onChange(of: totals) { _, _ in cacheLayout() }
        .onChange(of: colorMode) { _, _ in cacheLayout() }
    }

    private var currentSize: Int64 {
        guard currentNode >= 0, Int(currentNode) < totals.count else { return 0 }
        return totals[Int(currentNode)]
    }

    private func cacheLayout(in size: CGSize? = nil) {
        if let size, size.width > 0, size.height > 0 { canvasSize = size }
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            layoutRects = []
            return
        }
        layoutRects = SquarifiedTreemap.layout(
            items: tree.children(of: currentNode, totals: totals),
            in: CGRect(origin: .zero, size: canvasSize)
        )
    }

    private func colorFor(id: Int32) -> Color {
        ExploreColoring.color(for: id, in: tree, mode: colorMode, categories: categories)
    }
}



struct LargestItemsStrip: View {
    @ObservedObject var model: ScanModel
    let tree: FileTree
    let root: URL

    private var rows: [(id: Int32, size: Int64)] {
        let node = model.currentNode
        guard model.selectedTotals.count == tree.count else { return [] }
        return tree.children(of: node, totals: model.selectedTotals).sorted { $0.size > $1.size }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Largest items in this folder")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DiskMapTheme.ink)
                .padding(.horizontal, 14)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(rows.prefix(12).enumerated()), id: \.element.id) { _, row in
                        Button {
                            model.selectedNode = row.id
                            if tree.isDirectory[Int(row.id)] {
                                model.currentNode = row.id
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tree.name(of: row.id))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(DiskMapTheme.ink)
                                    .lineLimit(1)
                                Text(ByteFormat.string(row.size))
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(DiskMapTheme.mutedLabel)
                                Text(tree.isDirectory[Int(row.id)] ? "Folder" : "File")
                                    .font(.system(size: 10))
                                    .foregroundStyle(DiskMapTheme.mutedLabel)
                            }
                            .padding(10)
                            .frame(width: 140, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(DiskMapTheme.cardFill)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.vertical, 8)
        .background(DiskMapTheme.inspectorFill.opacity(0.5))
    }
}
