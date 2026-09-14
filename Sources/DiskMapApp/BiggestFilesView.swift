import AppKit
import DiskMapCore
import SwiftUI

/// Find → Biggest Files: files only, ranked by size, with inspector matching DiskMap-BiggestFiles ref.
struct BiggestFilesView: View {
    @ObservedObject var model: ScanModel
    let tree: FileTree
    let rootURL: URL
    var onOpenCleanup: () -> Void = {}

    enum SortMode: String, CaseIterable, Identifiable {
        case largest, smallest, newest, oldest, name
        var id: String { rawValue }
        var title: String {
            switch self {
            case .largest: return "Largest"
            case .smallest: return "Smallest"
            case .newest: return "Recently modified"
            case .oldest: return "Oldest"
            case .name: return "Name"
            }
        }
    }

    @State private var query = ""
    @State private var kindFilter: FileKind? = nil
    @State private var sortMode: SortMode = .largest
    @State private var selectedID: Int32?

    private var totals: [Int64] { model.selectedTotals }

    private var usedDenominator: Int64 {
        if let vol = model.analysis.volume { return max(1, Int64(vol.usedBytes)) }
        return max(1, model.analysis.scannedBytes)
    }

    private var allFileIDs: [Int32] {
        guard totals.count == tree.count else { return [] }
        return TopSizes.rankedFiles(tree: tree, totals: totals, limit: 2_000)
    }

    private var filtered: [Int32] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pathPrefix = model.folderFilterPath
        var ids = allFileIDs.filter { id in
            let name = tree.name(of: id)
            let abs = tree.path(of: id, root: rootURL).path
            if let pathPrefix {
                let prefix = pathPrefix.hasSuffix("/") ? pathPrefix : pathPrefix + "/"
                if abs != pathPrefix && !abs.hasPrefix(prefix) { return false }
            }
            let kind = FileKind.classify(fileName: name, path: abs)
            if let kindFilter, kind != kindFilter { return false }
            if q.isEmpty { return true }
            let display = CanonicalPath.displayPath(absolutePath: abs).lowercased()
            return name.lowercased().contains(q) || display.contains(q)
        }
        switch sortMode {
        case .largest:
            ids.sort { totals[Int($0)] > totals[Int($1)] }
        case .smallest:
            ids.sort { totals[Int($0)] < totals[Int($1)] }
        case .newest:
            ids.sort { tree.modifiedDay[Int($0)] > tree.modifiedDay[Int($1)] }
        case .oldest:
            ids.sort { a, b in
                let da = tree.modifiedDay[Int(a)]
                let db = tree.modifiedDay[Int(b)]
                if da == 0 { return false }
                if db == 0 { return true }
                return da < db
            }
        case .name:
            ids.sort {
                tree.name(of: $0).localizedCaseInsensitiveCompare(tree.name(of: $1)) == .orderedAscending
            }
        }
        return ids
    }

    private var totalBytes: Int64 {
        filtered.reduce(Int64(0)) { $0 + totals[Int($1)] }
    }

    private var activeSelection: Int32? {
        if let selectedID, filtered.contains(selectedID) { return selectedID }
        return filtered.first
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
            if selectedID == nil, let first = filtered.first {
                selectedID = first
                model.selectedNode = first
            }
        }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            controls
            Divider().overlay(DiskMapTheme.cardStroke)
            if model.isScanning {
                ProgressView("Scanning your Mac… Biggest files will appear when the scan finishes.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                emptyState
            } else {
                list
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Biggest Files")
                    .font(DiskMapType.title)
                    .foregroundStyle(DiskMapTheme.ink)
                Text("The largest individual files using storage on your Mac. Folders are not shown here.")
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 2) {
                Text("Showing \(filtered.count.formatted()) files")
                    .font(DiskMapType.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                Text("Total \(ByteFormat.string(totalBytes))")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DiskMapTheme.ink)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                searchField
                sortControl
                    .frame(width: 172)
            }
            if let pathPrefix = model.folderFilterPath {
                HStack(spacing: 8) {
                    Text("In " + CanonicalPath.displayPath(absolutePath: pathPrefix))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Clear") {
                        model.folderFilterPath = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Capsule().fill(DiskMapTheme.navSelected))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip(title: "All Files", selected: kindFilter == nil) {
                        kindFilter = nil
                    }
                    ForEach([FileKind.video, .diskImage, .archive, .application, .document, .other], id: \.self) { kind in
                        filterChip(title: kind.title, selected: kindFilter == kind) {
                            kindFilter = (kindFilter == kind) ? nil : kind
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            TextField("Search files by name or path…", text: $query)
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
    }

    private var sortControl: some View {
        Menu {
            ForEach(SortMode.allCases) { mode in
                Button(mode.title) { sortMode = mode }
            }
        } label: {
            HStack(spacing: 8) {
                Text("Sort: " + sortMode.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(DiskMapTheme.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Sort by " + sortMode.title)
    }

    private func filterChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .foregroundStyle(selected ? Color.white : DiskMapTheme.ink)
                .background(Capsule().fill(selected ? DiskMapTheme.ink : DiskMapTheme.navSelected))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Text(allFileIDs.isEmpty ? "No unusually large files" : "No files match this filter")
                .font(DiskMapType.section)
                .foregroundStyle(DiskMapTheme.ink)
            Text(
                allFileIDs.isEmpty
                    ? "Your largest files are all relatively small, or the scan found no files."
                    : "Try another type filter or clear the search."
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
                ForEach(Array(filtered.prefix(500).enumerated()), id: \.element) { index, id in
                    fileRow(rank: index + 1, id: id)
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

    private func fileRow(rank: Int, id: Int32) -> some View {
        let i = Int(id)
        let name = tree.name(of: id)
        let abs = tree.path(of: id, root: rootURL).path
        let kind = FileKind.classify(fileName: name, path: abs)
        let size = totals[i]
        let selected = id == selectedID
        let parent = CanonicalPath.parentDisplay(of: abs)
        let modified = relativeModified(tree.modifiedDay[i])
        return Button {
            selectedID = id
            model.selectedNode = id
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Text("\(rank)")
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .frame(width: 28, alignment: .center)
                Image(systemName: kind.symbolName)
                    .font(.system(size: 14))
                    .foregroundStyle(kindTint(kind))
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                        .lineLimit(1)
                    Text(parent)
                        .font(.system(size: 11))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                kindPill(kind)
                Text(modified)
                    .font(.system(size: 11))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .frame(width: 88, alignment: .trailing)
                Text(ByteFormat.string(size))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DiskMapTheme.ink)
                    .frame(width: 84, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? DiskMapTheme.ink.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(kind.title), \(ByteFormat.string(size))")
    }

    private func kindPill(_ kind: FileKind) -> some View {
        Text(kind.title)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(kindTint(kind))
            .background(Capsule().fill(kindTint(kind).opacity(0.14)))
            .frame(width: 92, alignment: .leading)
    }

    private func kindTint(_ kind: FileKind) -> Color {
        switch kind {
        case .video: return Color(red: 0.55, green: 0.35, blue: 0.85)
        case .diskImage: return Color(red: 0.25, green: 0.45, blue: 0.90)
        case .archive: return Color(red: 0.92, green: 0.50, blue: 0.20)
        case .application: return Color(red: 0.20, green: 0.55, blue: 0.85)
        case .document: return Color(red: 0.85, green: 0.65, blue: 0.15)
        case .virtualDisk: return Color(red: 0.50, green: 0.35, blue: 0.80)
        case .deviceBackup: return Color(red: 0.20, green: 0.65, blue: 0.45)
        case .database: return Color(red: 0.40, green: 0.50, blue: 0.60)
        case .other: return DiskMapTheme.mutedLabel
        }
    }

    private var inspector: some View {
        Group {
            if let id = activeSelection {
                FileInspectorPanel(
                    model: model,
                    tree: tree,
                    rootURL: rootURL,
                    id: id,
                    size: totals[Int(id)],
                    usedDenominator: usedDenominator,
                    onOpenCleanup: onOpenCleanup
                )
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                    Text("Select a file")
                        .font(DiskMapType.body)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DiskMapTheme.cardFill)
    }

    private func relativeModified(_ day: Int32) -> String {
        guard day > 0 else { return "Unknown" }
        let today = AgeMap.today()
        let age = today - day
        if age <= 0 { return "Today" }
        if age == 1 { return "Yesterday" }
        if age < 30 { return "\(age) days ago" }
        if age < 365 {
            let months = max(1, age / 30)
            return months == 1 ? "1 month ago" : "\(months) months ago"
        }
        let years = max(1, age / 365)
        return years == 1 ? "1 year ago" : "\(years) years ago"
    }
}

/// Separated so escaping Task closures capture a stable ObservedObject cleanly.
private struct FileInspectorPanel: View {
    @ObservedObject var model: ScanModel
    let tree: FileTree
    let rootURL: URL
    let id: Int32
    let size: Int64
    let usedDenominator: Int64
    var onOpenCleanup: () -> Void = {}

    var body: some View {
        let name = tree.name(of: id)
        let abs = tree.path(of: id, root: rootURL).path
        let kind = FileKind.classify(fileName: name, path: abs)
        let display = CanonicalPath.displayPath(absolutePath: abs)
        let safety = SafetyClassifier.assess(path: abs, name: name, isDirectory: false)
        let pct = Double(size) / Double(usedDenominator)
        let allowTrash = safety.level != SafetyLevel.protected && kind != FileKind.virtualDisk
        let modified = relativeModified(tree.modifiedDay[Int(id)])

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: kind.symbolName)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(tint(kind))
                        .frame(width: 56, height: 56)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(tint(kind).opacity(0.12))
                        )
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DiskMapTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Text(ByteFormat.string(size))
                            .font(.system(size: 26, weight: .semibold).monospacedDigit())
                            .foregroundStyle(DiskMapTheme.ink)
                        Text(kind.title + " · " + String(format: "%.1f%% of used storage", min(100, pct * 100)))
                            .font(.system(size: 11))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 12) {
                    metaBlock(label: "Location", value: CanonicalPath.parentDisplay(of: abs))
                    metaBlock(label: "Modified", value: modified)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Why is it large?")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                    Text(FileKind.whyLarge(kind: kind, name: name))
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

                VStack(alignment: .leading, spacing: 6) {
                    Text(safety.level.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(safetyColor(safety.level))
                    Text(safety.reason)
                        .font(.system(size: 12))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    if kind == FileKind.virtualDisk || name.lowercased().hasSuffix(".raw") {
                        Text("Do not delete this file directly — manage storage in the owning app.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DiskMapTheme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(spacing: 8) {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: abs)])
                    }
                    .buttonStyle(PrimaryCTAStyle(fullWidth: true))

                    Button("Open Containing Folder") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: abs).deletingLastPathComponent())
                    }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))

                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(display, forType: .string)
                        model.showToast("Path copied")
                    }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))

                    if allowTrash {
                        Button("Move to Trash…") {
                            Task { await stageForTrash(url: URL(fileURLWithPath: abs), name: name) }
                        }
                        .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                    }
                }
                .padding(.top, 4)
            }
            .padding(18)
        }
    }

    private func stageForTrash(url: URL, name: String) async {
        let url = url.standardizedFileURL
        if model.isStaged(url) {
            model.showToast("Already in cleanup list")
            onOpenCleanup()
            return
        }
        let ok = await model.cleanupQueue.stage(url, size: size, reason: "Biggest file: " + name)
        await model.refreshQueue()
        if ok {
            model.showToast("Added to cleanup review")
            onOpenCleanup()
        } else {
            model.showToast("Blocked by safety rules")
        }
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
                .lineLimit(2)
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

    private func tint(_ kind: FileKind) -> Color {
        switch kind {
        case .video: return Color(red: 0.55, green: 0.35, blue: 0.85)
        case .diskImage: return Color(red: 0.25, green: 0.45, blue: 0.90)
        case .archive: return Color(red: 0.92, green: 0.50, blue: 0.20)
        case .application: return Color(red: 0.20, green: 0.55, blue: 0.85)
        case .document: return Color(red: 0.85, green: 0.65, blue: 0.15)
        case .virtualDisk: return Color(red: 0.50, green: 0.35, blue: 0.80)
        case .deviceBackup: return Color(red: 0.20, green: 0.65, blue: 0.45)
        case .database: return Color(red: 0.40, green: 0.50, blue: 0.60)
        case .other: return DiskMapTheme.mutedLabel
        }
    }

    private func relativeModified(_ day: Int32) -> String {
        guard day > 0 else { return "Unknown" }
        let today = AgeMap.today()
        let age = today - day
        if age <= 0 { return "Today" }
        if age == 1 { return "Yesterday" }
        if age < 30 { return "\(age) days ago" }
        if age < 365 {
            let months = max(1, age / 30)
            return months == 1 ? "1 month ago" : "\(months) months ago"
        }
        let years = max(1, age / 365)
        return years == 1 ? "1 year ago" : "\(years) years ago"
    }
}
