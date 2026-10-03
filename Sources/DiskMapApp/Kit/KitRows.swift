import AppKit
import DiskMapCore
import SwiftUI

/// The flat list row every list uses: leading icon, name over a secondary
/// line, trailing mono columns, hover actions, accent selection.
struct KitRow<Leading: View, Trailing: View>: View {
    var title: String
    var subtitle: String?
    var selected: Bool
    /// Hover actions (Quick Look, Reveal, Add to Cleanup) need a path.
    var path: String?
    var onStage: (() -> Void)?
    var height: CGFloat = DiskMapSpace.rowTwoLine
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DiskMapType.bodyEmphasis)
                    .foregroundStyle(DiskMapTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(DiskMapType.secondary)
                        .foregroundStyle(DiskMapTheme.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            if let path, hovering {
                RowHoverActions(path: path, onStage: onStage)
                    .transition(.opacity)
            }
            trailing
        }
        .padding(.horizontal, 10)
        .frame(minHeight: height)
        .background(RowBackground(selected: selected, hovering: hovering))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A row's mono column (size, date, count).
struct MonoColumn: View {
    var text: String
    var width: CGFloat
    var emphasis = false
    var body: some View {
        Text(text)
            .font(emphasis ? DiskMapType.figureStrong : DiskMapType.figureSmall)
            .foregroundStyle(emphasis ? DiskMapTheme.ink : DiskMapTheme.ink2)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }
}

/// A row's plain text column (kind, source).
struct TextColumn: View {
    var text: String
    var width: CGFloat
    var body: some View {
        Text(text)
            .font(DiskMapType.secondary)
            .foregroundStyle(DiskMapTheme.ink2)
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
    }
}

/// Separator between rows, indented to the text.
struct RowSeparator: View {
    var indent: CGFloat = 52
    var body: some View {
        Rectangle().fill(DiskMapTheme.line.opacity(0.7)).frame(height: 1).padding(.leading, indent)
    }
}

/// The leading slot of a multi-selectable row: a check when ⌘-selected.
struct MultiSelectMark: View {
    var on: Bool
    var body: some View {
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .font(.system(size: DiskMapType.scaled(12)))
            .foregroundStyle(on ? DiskMapTheme.accent : .clear)
            .frame(width: 14)
            .accessibilityHidden(true)
    }
}

// MARK: - The one file inspector

/// Used by every page that inspects a single file: header, facts, why, safety, actions.
struct FileInspector: View {
    @ObservedObject var model: ScanModel
    let tree: FileTree
    let rootURL: URL
    let id: Int32
    let size: Int64
    /// Cleanup reason recorded with the staged item ("Biggest file: …").
    var reason: String
    var extraFacts: [(String, String)] = []
    /// Replaces the "why it's large" note (e.g. Forgotten Files' reasons).
    var note: (label: String, text: String)? = nil
    /// False where the page has its own reason not to offer cleanup.
    var allowStage = true
    /// Shown above the header (Large Media's thumbnail).
    var preview: AnyView? = nil

    private var usedDenominator: Int64 {
        if let vol = model.analysis.volume { return max(1, Int64(vol.usedBytes)) }
        return max(1, model.analysis.scannedBytes)
    }

    var body: some View {
        let name = tree.name(of: id)
        let abs = tree.path(of: id, root: rootURL).path
        let url = URL(fileURLWithPath: abs)
        let kind = FileKind.classify(fileName: name, path: abs)
        let safety = SafetyClassifier.assess(path: abs, name: name, isDirectory: false)
        let share = Double(size) / Double(usedDenominator)
        let allowTrash = allowStage && safety.level != .protected && kind != .virtualDisk
        let staged = model.isStaged(url)

        return InspectorColumn {
            if let preview { preview }
            InspectorHeader(name: name, size: ByteFormat.string(size),
                            detail: "\(kind.title) · \(Self.percent(share)) of used space") {
                if preview == nil { FileIdentityIcon(url: url, kind: kind, size: 40) }
            }
            Hairline()
            FactRow(label: "Location", value: CanonicalPath.parentDisplay(of: abs))
            FactRow(label: "Modified", value: RelativeAge.long(day: tree.modifiedDay[Int(id)]))
            ForEach(extraFacts, id: \.0) { fact in FactRow(label: fact.0, value: fact.1) }
            if let shared = tree.sharingInfo(of: id) {
                FactRow(label: "APFS clone", value: "Shares \(ByteFormat.string(shared.sharedBytes)) with \(shared.otherCopies) other cop\(shared.otherCopies == 1 ? "y" : "ies")")
            }
            Hairline()
            if let note {
                Note(label: note.label, text: note.text)
            } else {
                Note(label: "Why it's large", text: FileKind.whyLarge(kind: kind, name: name))
            }
            SafetyLine(assessment: safety)
            if kind == .virtualDisk || name.lowercased().hasSuffix(".raw") {
                Text("Don't delete this file directly — manage its storage in the app that owns it.")
                    .font(DiskMapType.secondary)
                    .foregroundStyle(DiskMapTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            InspectorActions(
                primaryTitle: staged ? "In Cleanup" : "Add to Cleanup",
                primaryDone: staged,
                primaryEnabled: allowTrash,
                primary: {
                    if staged { model.isCleanupQueuePresented = true } else {
                        model.stageRow(path: abs, size: size, reason: reason)
                    }
                },
                path: abs
            ) {
                Button("Show in Visualize") {
                    model.selectedNode = id
                    model.currentNode = max(0, tree.parent[Int(id)])
                    model.destination = .visualize
                }
                Button("Show in File Browser") {
                    model.currentNode = max(0, tree.parent[Int(id)])
                    model.selectedNode = id
                    model.destination = .fileBrowser
                }
            }
            .padding(.top, 4)
        }
    }

    static func percent(_ fraction: Double) -> String {
        let pct = fraction * 100
        if pct > 0 && pct < 0.1 { return "<0.1%" }
        return String(format: "%.1f%%", min(100, pct))
    }
}

// MARK: - The one folder inspector

/// Used by every page that inspects a folder: header, composition, largest
/// files, why, safety, actions.
struct FolderInspector: View {
    @ObservedObject var model: ScanModel
    let tree: FileTree
    let rootURL: URL
    let id: Int32
    /// Cleanup reason recorded with the staged folder.
    var reason: String? = nil

    private var usedDenominator: Int64 {
        if let vol = model.analysis.volume { return max(1, Int64(vol.usedBytes)) }
        return max(1, model.analysis.scannedBytes)
    }

    /// Built off the main thread: composition and largest files walk the
    /// whole subtree, which is slow for a home folder or a volume root.
    @State private var insight: FolderInsight?
    @State private var builtFor: String?

    private var buildKey: String { "\(id):\(model.scanID):\(model.sizeBasis)" }

    var body: some View {
        Group {
            if let insight, insight.nodeID == id {
                content(insight)
            } else if builtFor == buildKey {
                DiskMapEmptyState(symbol: "folder", title: "Select a folder", message: "Its details and actions appear here.")
            } else {
                DiskMapLoadingState(title: "Reading folder", detail: tree.name(of: id))
            }
        }
        .task(id: buildKey) {
            let key = buildKey
            let (tree, root, id) = (self.tree, self.rootURL, self.id)
            let totals = model.selectedTotals
            let files = model.descendantFileCounts, folders = model.descendantFolderCounts
            let categories = model.fileTypeCategories
            let built = await Task.detached(priority: .userInitiated) {
                FolderInsight.build(nodeID: id, tree: tree, root: root, totals: totals,
                                    fileCounts: files, folderCounts: folders, categories: categories)
            }.value
            guard !Task.isCancelled else { return }
            insight = built
            builtFor = key
        }
    }

    private func content(_ insight: FolderInsight) -> some View {
        let url = URL(fileURLWithPath: insight.absolutePath, isDirectory: true)
        let staged = model.isStaged(url)
        let share = Double(insight.bytes) / Double(usedDenominator)
        return InspectorColumn {
            InspectorHeader(name: insight.name, size: ByteFormat.string(insight.bytes),
                            detail: countLabel(insight.fileCount, "file") + " · " + countLabel(insight.folderCount, "folder") + " · \(FileInspector.percent(share)) of used") {
                Image(systemName: "folder")
                    .font(.system(size: DiskMapType.scaled(17), weight: .regular))
                    .foregroundStyle(DiskMapTheme.ink2)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DiskMapTheme.ink.opacity(0.06)))
                    .accessibilityHidden(true)
            }
            Hairline()
            FactRow(label: "Location", value: insight.displayPath)
            if !insight.composition.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    MonoLabel("Made of")
                    SegmentedStorageBar(segments: insight.composition.map {
                        (DiskMapTheme.hex($0.colorHex), Double($0.bytes) / Double(max(1, insight.bytes)))
                    })
                    ForEach(insight.composition.prefix(5), id: \.categoryID) { row in
                        HStack(spacing: 8) {
                            Circle().fill(DiskMapTheme.hex(row.colorHex)).frame(width: 6, height: 6)
                            Text(row.label)
                                .font(DiskMapType.secondary)
                                .foregroundStyle(DiskMapTheme.ink)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(ByteFormat.string(row.bytes))
                                .font(DiskMapType.figureSmall)
                                .foregroundStyle(DiskMapTheme.ink2)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if !insight.largestFiles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        MonoLabel("Largest files")
                        Spacer()
                        Button("View all") {
                            model.folderFilterPath = insight.absolutePath
                            model.destination = .biggestFiles
                        }
                        .buttonStyle(LinkButtonStyle())
                        .font(DiskMapType.secondary)
                    }
                    ForEach(insight.largestFiles.prefix(5), id: \.id) { file in
                        HStack {
                            Text(file.name)
                                .font(DiskMapType.secondary)
                                .foregroundStyle(DiskMapTheme.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 6)
                            Text(ByteFormat.string(file.bytes))
                                .font(DiskMapType.figureSmall)
                                .foregroundStyle(DiskMapTheme.ink2)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Hairline()
            Note(label: "Why it's large", text: insight.whyLarge)
            if insight.reviewableBytes > 0 {
                Note(label: "Reviewable", text: "\(ByteFormat.string(insight.reviewableBytes)) — "
                     + (insight.safety.level == .safe ? "looks like regenerable cache or temp data."
                        : "files under here not modified in over a year."))
            }
            SafetyLine(assessment: insight.safety)
            InspectorActions(
                primaryTitle: staged ? "In Cleanup" : "Add to Cleanup",
                primaryDone: staged,
                primaryEnabled: insight.safety.level != .protected,
                primary: {
                    if staged { model.isCleanupQueuePresented = true } else {
                        model.stageRow(path: insight.absolutePath, size: insight.bytes,
                                       reason: reason ?? "Folder: " + insight.name)
                    }
                },
                path: insight.absolutePath
            ) {
                Button("Open in File Browser") {
                    model.currentNode = id
                    model.selectedNode = id
                    model.destination = .fileBrowser
                }
                Button("Show in Visualize") {
                    model.currentNode = id
                    model.selectedNode = id
                    model.destination = .visualize
                }
                Button("Biggest Files in This Folder") {
                    model.folderFilterPath = insight.absolutePath
                    model.destination = .biggestFiles
                }
            }
            .padding(.top, 4)
        }
    }
}
