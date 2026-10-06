import AppKit
import DiskMapCore
import SwiftUI

/// Find → Biggest Folders: storage-area investigation with select vs drill + inspector.
struct BiggestFoldersView: View {
    @ObservedObject var model: ScanModel
    @Environment(\.diskMapContentWidth) private var contentWidth
    let tree: FileTree
    let rootURL: URL
    var onOpenCleanup: () -> Void = {}

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
        AdaptiveInspectorSplit(windowWidth: contentWidth, inspectionToken: selectedID.map(String.init), main: mainColumn, inspector: inspector)
        .background(DiskMapTheme.canvas)
        .onChange(of: model.currentNode) { _, newValue in
            selectedID = newValue
            model.selectedNode = newValue
        }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(eyebrow: "Find", title: "Biggest Folders",
                           subtitle: "Click to inspect, double-click or › to open.") {
                    HeaderSummary(parts: [countLabel(rows.count, "folder"), ByteFormat.string(parentTotal) + " here"])
                }
                navBar
                filterBar
            }
            .padding(.horizontal, 28)
            .padding(.top, DiskMapSpace.pageTop)
            .padding(.bottom, 12)
            Hairline()
            if rows.isEmpty {
                DiskMapEmptyState(
                    symbol: "folder",
                    title: rawRows.isEmpty ? "Nothing with a size in this folder" : "No folders match",
                    message: rawRows.isEmpty ? "Try another folder, or go back up." : "Clear the search or show technical folders."
                )
            } else {
                list
            }
            NodeSelectionToolbar(model: model)
        }
    }

    private var atScannedVolumeRoot: Bool {
        model.currentNode == 0 && (rootURL.path == "/" || rootURL.standardizedFileURL.path == "/")
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            DiskMapSearchField(placeholder: "Search folders by name or path", text: $query)
                .frame(maxWidth: 340)
            if atScannedVolumeRoot {
                Chip(title: "Show technical", isOn: showTechnical) { showTechnical.toggle() }
                    .help("Show zero-size and technical system stubs at the volume root")
            }
            Spacer(minLength: 0)
        }
    }

    private var navBar: some View {
        HStack(spacing: 8) {
            Button(action: goBack) { Label("Back", systemImage: "chevron.left") }
                .buttonStyle(IconButtonStyle())
                .disabled(!canGoBack)
                .help("Back to parent folder")
                .accessibilityLabel("Back to parent folder")
            BreadcrumbBar(tree: tree, currentNode: model.currentNode) { id in
                model.currentNode = id
                selectedID = id
                model.selectedNode = id
            }
        }
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

    private var list: some View {
        let ordered = rows.map(\.id)
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows, id: \.id) { row in
                    folderRow(row, ordered: ordered)
                    RowSeparator(indent: 10 + 14 + 12 + 24 + 12)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 4)
        }
        .listKeyboard(
            ids: ordered, selection: $selectedID,
            path: { tree.path(of: $0, root: rootURL).path },
            stage: { id in
                model.stageRow(path: tree.path(of: id, root: rootURL).path, size: model.selectedTotals[Int(id)],
                               reason: "Biggest folder: " + tree.name(of: id))
            },
            selectAll: { model.multiSelection = Set(ordered) },
            clearSelection: { model.clearMultiSelection() }
        )
    }

    private func folderRow(_ row: (id: Int32, size: Int64), ordered: [Int32]) -> some View {
        let i = Int(row.id)
        let isDir = tree.isDirectory[i]
        let name = tree.name(of: row.id)
        let inMulti = model.multiSelection.contains(row.id)
        let selected = row.id == (selectedID ?? activeSelection) || inMulti
        let frac = Double(row.size) / Double(parentTotal)
        let fileCount = model.descendantFileCounts.indices.contains(i) ? model.descendantFileCounts[i] : 0
        let folderCount = model.descendantFolderCounts.indices.contains(i) ? model.descendantFolderCounts[i] : 0
        let abs = tree.path(of: row.id, root: rootURL).path
        let safety = SafetyClassifier.assess(path: abs, name: name, isDirectory: isDir)
        let stage: (() -> Void)? = safety.level == .protected ? nil : {
            model.stageRow(path: abs, size: row.size, reason: "Biggest folder: " + name)
        }
        var subtitle = isDir ? countLabel(fileCount, "file") + " · " + countLabel(folderCount, "folder")
            : FileKind.classify(fileName: name, path: abs).title
        // Its storage category, with ⚠ where removing it breaks something.
        let verdict = StorageClassifier.classify(path: abs, isDirectory: isDir)
        if verdict.storageClass.id != "other" {
            subtitle += " · " + (verdict.advice.isRisky ? "⚠ " : "") + verdict.storageClass.title
        }
        if isDir, let shared = model.cloneSharedBytes(of: row.id), i < model.allocatedTotals.count {
            subtitle += " · about \(ByteFormat.string(max(0, model.allocatedTotals[i] - shared))) on disk (shared copies)"
        }
        return HStack(spacing: 0) {
            Button {
                selectedID = row.id
                model.select(row.id, ordered: ordered)
            } label: {
                KitRow(title: name, subtitle: subtitle, selected: selected, path: abs, onStage: stage) {
                    MultiSelectMark(on: inMulti)
                    Group {
                        if isDir {
                            Image(systemName: "folder")
                                .font(.system(size: DiskMapType.scaled(14)))
                                .foregroundStyle(DiskMapTheme.ink2)
                                .frame(width: 24, height: 24)
                        } else {
                            FileIdentityIcon(url: URL(fileURLWithPath: abs), size: 24)
                        }
                    }
                } trailing: {
                    if safety.level == .protected {
                        SafetyLabel(level: .protected)
                    }
                    ProportionBar(fraction: frac)
                        .frame(width: 90)
                    MonoColumn(text: ByteFormat.string(row.size), width: 74, emphasis: true)
                    Image(systemName: "chevron.right")
                        .font(.system(size: DiskMapType.scaled(10), weight: .semibold))
                        .foregroundStyle(isDir ? DiskMapTheme.ink3 : .clear)
                        .frame(width: 12)
                }
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded { if isDir { drill(into: row.id) } })
            .accessibilityLabel("\(name), \(ByteFormat.string(row.size))\(isDir ? ", \(subtitle)" : "")")
            .accessibilityAction(named: "Open") { if isDir { drill(into: row.id) } }
            .rowActions(path: abs, stage: stage)
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
            if let id = activeSelection, tree.isDirectory[Int(id)] {
                FolderInspector(model: model, tree: tree, rootURL: rootURL, id: id,
                                reason: "Biggest folder: " + tree.name(of: id))
            } else {
                DiskMapEmptyState(symbol: "folder", title: "Select a folder", message: "Its details and actions appear here.")
            }
        }
        .background(DiskMapTheme.canvas)
    }
}
