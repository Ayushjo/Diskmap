import AppKit
import DiskMapCore
import SwiftUI

/// Find → Biggest Folders: storage-area investigation with select vs drill + inspector.
struct BiggestFoldersView: View {
    @ObservedObject var model: ScanModel
    let tree: FileTree
    let rootURL: URL

    @State private var query = ""
    @State private var showTechnical = false
    @State private var selectedID: Int32?

    private var totals: [Int64] { model.selectedTotals }

    private var usedDenominator: Int64 {
        if let vol = model.analysis.volume { return max(1, Int64(vol.usedBytes)) }
        return max(1, model.analysis.scannedBytes)
    }

    private var parentTotal: Int64 {
        guard model.currentNode >= 0, Int(model.currentNode) < totals.count else { return 1 }
        return max(totals[Int(model.currentNode)], 1)
    }

    private var rawRows: [(id: Int32, size: Int64)] {
        guard model.currentNode >= 0,
              Int(model.currentNode) < tree.count,
              totals.count == tree.count else { return [] }
        return tree.children(of: model.currentNode, totals: totals).sorted { $0.size > $1.size }
    }

    private static let hiddenTechnical: Set<String> = [
        ".vol", ".file", "cores", "dev", "bin", "sbin", "Network", "automount",
        "home", "net",
    ]

    private var rows: [(id: Int32, size: Int64)] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let atRoot = model.currentNode == 0
        let scanningRoot = rootURL.path == "/" || rootURL.standardizedFileURL.path == "/"
        return rawRows.filter { row in
            let name = tree.name(of: row.id)
            if atRoot, scanningRoot, !showTechnical {
                if row.size <= 0 { return false }
                if Self.hiddenTechnical.contains(name) { return false }
            }
            if q.isEmpty { return true }
            let abs = tree.path(of: row.id, root: rootURL).path
            let display = CanonicalPath.displayPath(absolutePath: abs).lowercased()
            return name.lowercased().contains(q) || display.contains(q)
        }
    }

    private var activeSelection: Int32? {
        if let selectedID {
            if tree.isDirectory[Int(selectedID)] { return selectedID }
        }
        if model.selectedNode >= 0,
           Int(model.selectedNode) < tree.count,
           tree.isDirectory[Int(model.selectedNode)] {
            return model.selectedNode
        }
        if model.currentNode >= 0, Int(model.currentNode) < tree.count {
            return model.currentNode
        }
        return rows.first(where: { tree.isDirectory[Int($0.id)] })?.id
    }

    var body: some View {
        HStack(spacing: 0) {
            mainColumn
            Divider().overlay(DiskMapTheme.cardStroke)
            inspector
                .frame(width: 320)
        }
        .background(DiskMapTheme.cream)
        .onAppear {
            if selectedID == nil {
                selectedID = activeSelection
                if let id = selectedID { model.selectedNode = id }
            }
        }
        .onChange(of: model.currentNode) { _, newValue in
            selectedID = newValue
            model.selectedNode = newValue
        }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            controls
            navBar
            Divider().overlay(DiskMapTheme.cardStroke)
            if model.isScanning {
                ProgressView("Scanning your Mac… Biggest folders will appear when the scan finishes.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                emptyState
            } else {
                list
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Biggest Folders")
                    .font(DiskMapType.title)
                    .foregroundStyle(DiskMapTheme.ink)
                Text("Investigate where storage goes by folder. Click to select; open a folder to drill in.")
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(rows.count.formatted()) folders here")
                    .font(DiskMapType.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                Text(ByteFormat.string(parentTotal))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DiskMapTheme.ink)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                TextField("Search folders by name or path…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(DiskMapTheme.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                    )
            )

            if model.currentNode == 0, rootURL.path == "/" || rootURL.standardizedFileURL.path == "/" {
                Toggle(isOn: $showTechnical) {
                    Text("Show technical")
                        .font(.system(size: 11, weight: .semibold))
                }
                .toggleStyle(.checkbox)
                .help("Show zero-size and technical system stubs at the volume root")
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private var navBar: some View {
        HStack(spacing: 10) {
            Button {
                goBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(canGoBack ? DiskMapTheme.ink : DiskMapTheme.mutedLabel.opacity(0.5))
            .disabled(!canGoBack)
            .accessibilityLabel("Back to parent folder")

            BreadcrumbBar(tree: tree, currentNode: model.currentNode) { id in
                model.currentNode = id
                selectedID = id
                model.selectedNode = id
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var canGoBack: Bool {
        guard model.currentNode >= 0, Int(model.currentNode) < tree.count else { return false }
        return tree.parent[Int(model.currentNode)] >= 0
    }

    private func goBack() {
        guard canGoBack else { return }
        let p = tree.parent[Int(model.currentNode)]
        model.currentNode = p
        selectedID = p
        model.selectedNode = p
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Text(rawRows.isEmpty ? "Nothing with a size in this folder" : "No folders match this filter")
                .font(DiskMapType.section)
                .foregroundStyle(DiskMapTheme.ink)
            Text(
                rawRows.isEmpty
                    ? "Try another folder, or go back up."
                    : "Clear search or show technical folders."
            )
            .font(DiskMapType.body)
            .foregroundStyle(DiskMapTheme.mutedLabel)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows, id: \.id) { row in
                    folderRow(row)
                    Rectangle()
                        .fill(DiskMapTheme.cardStroke.opacity(0.65))
                        .frame(height: 1)
                        .padding(.leading, 56)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private func folderRow(_ row: (id: Int32, size: Int64)) -> some View {
        let isDir = tree.isDirectory[Int(row.id)]
        let name = tree.name(of: row.id)
        let selected = row.id == (selectedID ?? activeSelection)
        let frac = Double(row.size) / Double(parentTotal)
        let fileCount = model.descendantFileCounts.indices.contains(Int(row.id))
            ? model.descendantFileCounts[Int(row.id)] : 0
        let folderCount = model.descendantFolderCounts.indices.contains(Int(row.id))
            ? model.descendantFolderCounts[Int(row.id)] : 0
        let abs = tree.path(of: row.id, root: rootURL).path
        let safety = SafetyClassifier.assess(path: abs, name: name, isDirectory: isDir)

        return HStack(spacing: 0) {
            Button {
                selectedID = row.id
                model.selectedNode = row.id
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? DiskMapTheme.ink : DiskMapTheme.cardFill)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                            )
                        Image(systemName: isDir ? "folder.fill" : "doc")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selected ? Color.white : DiskMapTheme.mutedLabel)
                    }
                    .frame(width: 32, height: 32)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(DiskMapTheme.ink)
                                .lineLimit(1)
                            if safety.level == .protected {
                                Text("Protected")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(DiskMapTheme.danger)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(DiskMapTheme.danger.opacity(0.12)))
                            }
                            Spacer(minLength: 8)
                            Text(ByteFormat.string(row.size))
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(DiskMapTheme.ink)
                        }
                        HStack(spacing: 8) {
                            if isDir {
                                Text("\(fileCount.formatted()) files · \(folderCount.formatted()) folders")
                                    .font(.system(size: 11))
                                    .foregroundStyle(DiskMapTheme.mutedLabel)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                        }
                        ProportionBar(fraction: frac, tint: DiskMapTheme.ink.opacity(0.28))
                            .frame(height: 3)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selected ? DiskMapTheme.ink.opacity(0.06) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    if isDir { drill(into: row.id) }
                }
            )
            .accessibilityLabel("\(name), \(ByteFormat.string(row.size))")

            if isDir {
                Button {
                    drill(into: row.id)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(name)")
            }
        }
    }

    private func drill(into id: Int32) {
        guard tree.isDirectory[Int(id)] else { return }
        model.currentNode = id
        selectedID = id
        model.selectedNode = id
    }

    private var inspector: some View {
        Group {
            if let id = activeSelection,
               tree.isDirectory[Int(id)],
               let insight = FolderInsight.build(
                    nodeID: id,
                    tree: tree,
                    root: rootURL,
                    totals: totals,
                    fileCounts: model.descendantFileCounts,
                    folderCounts: model.descendantFolderCounts,
                    categories: model.fileTypeCategories
               ) {
                FolderInspectorPanel(
                    model: model,
                    insight: insight,
                    usedDenominator: usedDenominator
                )
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                    Text("Select a folder")
                        .font(DiskMapType.body)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DiskMapTheme.cardFill)
    }
}

private struct FolderInspectorPanel: View {
    @ObservedObject var model: ScanModel
    let insight: FolderInsight
    let usedDenominator: Int64

    var body: some View {
        let pct = Double(insight.bytes) / Double(max(1, usedDenominator))
        let allowStage = insight.safety.level != .protected

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(DiskMapTheme.ink)
                        .frame(width: 56, height: 56)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(DiskMapTheme.ink.opacity(0.08))
                        )
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(insight.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DiskMapTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Text(ByteFormat.string(insight.bytes))
                            .font(.system(size: 26, weight: .semibold).monospacedDigit())
                            .foregroundStyle(DiskMapTheme.ink)
                        Text(String(format: "%.1f%% of used storage", min(100, pct * 100)))
                            .font(.system(size: 11))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 12) {
                    metaBlock(label: "Location", value: insight.displayPath)
                    metaBlock(
                        label: "Contents",
                        value: "\(insight.fileCount.formatted()) files · \(insight.folderCount.formatted()) folders"
                    )
                }

                if !insight.composition.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Composition")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DiskMapTheme.ink)
                        ForEach(Array(insight.composition.prefix(5).enumerated()), id: \.element.categoryID) { _, row in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(DiskMapTheme.hex(row.colorHex))
                                    .frame(width: 8, height: 8)
                                Text(row.label)
                                    .font(.system(size: 12))
                                    .foregroundStyle(DiskMapTheme.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(ByteFormat.string(row.bytes))
                                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                                    .foregroundStyle(DiskMapTheme.mutedLabel)
                            }
                            ProportionBar(
                                fraction: Double(row.bytes) / Double(max(1, insight.bytes)),
                                tint: DiskMapTheme.hex(row.colorHex)
                            )
                            .frame(height: 3)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Why is it large?")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                    Text(insight.whyLarge)
                        .font(.system(size: 12))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(red: 0.93, green: 0.95, blue: 0.99))
                )

                if insight.reviewableBytes > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Potentially reviewable")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DiskMapTheme.ink)
                        Text(ByteFormat.string(insight.reviewableBytes))
                            .font(.system(size: 16, weight: .semibold).monospacedDigit())
                            .foregroundStyle(DiskMapTheme.ink)
                        Text(
                            insight.safety.level == .safe
                                ? "This folder looks like regenerable cache or temp data."
                                : "Old files (not modified in over a year) under this folder. Review before removing."
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(insight.safety.level.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(safetyColor(insight.safety.level))
                    Text(insight.safety.reason)
                        .font(.system(size: 12))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !insight.largestFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Largest files")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DiskMapTheme.ink)
                        ForEach(insight.largestFiles, id: \.id) { file in
                            HStack {
                                Text(file.name)
                                    .font(.system(size: 12))
                                    .foregroundStyle(DiskMapTheme.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Text(ByteFormat.string(file.bytes))
                                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                                    .foregroundStyle(DiskMapTheme.mutedLabel)
                            }
                        }
                        Button("View all files in this folder") {
                            model.folderFilterPath = insight.absolutePath
                            model.destination = .biggestFiles
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                        .padding(.top, 2)
                    }
                }

                VStack(spacing: 8) {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: insight.absolutePath)])
                    }
                    .buttonStyle(PrimaryCTAStyle(fullWidth: true))

                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(insight.displayPath, forType: .string)
                        model.showToast("Path copied")
                    }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))

                    if allowStage {
                        Button("Review in Cleanup") {
                            Task { await stageFolder() }
                        }
                        .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                    } else {
                        Text("Cleanup staging is disabled for protected system folders.")
                            .font(.system(size: 11))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 4)
            }
            .padding(18)
        }
    }

    private func stageFolder() async {
        let url = URL(fileURLWithPath: insight.absolutePath, isDirectory: true)
        if model.isStaged(url) {
            model.showToast("Already in cleanup list")
            return
        }
        let ok = await model.cleanupQueue.stage(
            url,
            size: insight.bytes,
            reason: "Biggest folder: " + insight.name
        )
        await model.refreshQueue()
        model.showToast(ok ? "Added to cleanup review" : "Blocked by safety rules")
    }

    private func metaBlock(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DiskMapTheme.ink)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
        }
    }

    private func safetyColor(_ level: SafetyLevel) -> Color {
        switch level {
        case .safe: return DiskMapTheme.safe
        case .review: return DiskMapTheme.review
        case .protected: return DiskMapTheme.danger
        }
    }
}
