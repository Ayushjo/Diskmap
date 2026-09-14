import AppKit
import DiskMapCore
import SwiftUI

/// Find → Biggest Files: files only, ranked by allocated/logical totals, with inspector.
struct BiggestFilesView: View {
    @ObservedObject var model: ScanModel
    let tree: FileTree
    let rootURL: URL

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
        var ids = allFileIDs.filter { id in
            let name = tree.name(of: id)
            let abs = tree.path(of: id, root: rootURL).path
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
                let da = tree.modifiedDay[Int(a)], db = tree.modifiedDay[Int(b)]
                if da == 0 { return false }
                if db == 0 { return true }
                return da < db
            }
        case .name:
            ids.sort { tree.name(of: $0).localizedCaseInsensitiveCompare(tree.name(of: $1)) == .orderedAscending }
        }
        return ids
    }

    private var totalBytes: Int64 {
        filtered.reduce(Int64(0)) { $0 + totals[Int($1)] }
    }

    var body: some View {
        HStack(spacing: 0) {
            mainColumn
            Divider().overlay(DiskMapTheme.cardStroke)
            inspector
                .frame(width: 300)
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
            Spacer()
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
        .padding(.bottom, 12)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                    TextField("Search files by name or path…", text: $query)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(DiskMapTheme.cardFill)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(DiskMapTheme.cardStroke)))
                Menu {
                    ForEach(SortMode.allCases) { mode in
                        Button(mode.title) { sortMode = mode }
                    }
                } label: {
                    Text("Sort: \(sortMode.title)")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(DiskMapTheme.cardFill)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DiskMapTheme.cardStroke)))
                }
                .menuStyle(.borderlessButton)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip("All Files", selected: kindFilter == nil) { kindFilter = nil }
                    ForEach([FileKind.video, .diskImage, .archive, .application, .document, .other], id: \.self) { kind in
                        filterChip(kind.title, selected: kindFilter == kind) {
                            kindFilter = kindFilter == kind ? nil : kind
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func filterChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
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
            Text(allFileIDs.isEmpty
                 ? "Your largest files are all relatively small, or the scan found no files."
                 : "Try another type filter or clear the search.")
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
                    .frame(width: 28)
                Image(systemName: kind.symbolName)
                    .font(.system(size: 14))
                    .foregroundStyle(DiskMapTheme.ink.opacity(0.75))
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
                Spacer(minLength: 8)
                kindPill(kind)
                Text(modified)
                    .font(.system(size: 11))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .frame(width: 90, alignment: .trailing)
                Text(ByteFormat.string(size))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DiskMapTheme.ink)
                    .frame(width: 88, alignment: .trailing)
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
        .accessibilityLabel("\(name), \(kind.title), \(ByteFormat.string(size))")
    }

    private func kindPill(_ kind: FileKind) -> some View {
        Text(kind.title)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(DiskMapTheme.ink)
            .background(Capsule().fill(DiskMapTheme.navSelected))
            .frame(width: 88, alignment: .leading)
    }

    private var inspector: some View {
        Group {
            if let id = selectedID ?? filtered.first {
                inspectorBody(id: id)
            } else {
                Text("Select a file")
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DiskMapTheme.inspectorFill)
    }

    private func inspectorBody(id: Int32) -> some View {
        let i = Int(id)
        let name = tree.name(of: id)
        let abs = tree.path(of: id, root: rootURL).path
        let kind = FileKind.classify(fileName: name, path: abs)
        let size = totals[i]
        let display = CanonicalPath.displayPath(absolutePath: abs)
        let safety = SafetyClassifier.assess(path: abs, name: name, isDirectory: false)
        let pct = Double(size) / Double(usedDenominator)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: kind.symbolName)
                        .font(.system(size: 28))
                        .frame(width: 52, height: 52)
                        .background(RoundedRectangle(cornerRadius: 12).fill(DiskMapTheme.cardFill)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(DiskMapTheme.cardStroke)))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DiskMapTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(ByteFormat.string(size))
                            .font(DiskMapType.heroNumber)
                            .foregroundStyle(DiskMapTheme.ink)
                        Text("\(kind.title) · \(String(format: "%.1f%% of used storage", pct * 100))")
                            .font(DiskMapType.caption)
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                }
                metaRow("Location", CanonicalPath.parentDisplay(of: abs))
                metaRow("Modified", relativeModified(tree.modifiedDay[i]))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Why is it large?")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                    Text(FileKind.whyLarge(kind: kind, name: name))
                        .font(DiskMapType.caption)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.93, green: 0.95, blue: 0.99)))

                VStack(alignment: .leading, spacing: 6) {
                    Text(safety.level.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(safety.level == .safe ? DiskMapTheme.safe : (safety.level == .protected ? DiskMapTheme.danger : DiskMapTheme.review))
                    Text(safety.reason)
                        .font(DiskMapType.caption)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    if kind == .virtualDisk || name.lowercased().hasSuffix(".raw") {
                        Text("Do not delete this file directly — manage storage in the owning app.")
                            .font(DiskMapType.caption)
                            .foregroundStyle(DiskMapTheme.danger)
                    }
                }

                VStack(spacing: 8) {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: abs)])
                    }
                    .buttonStyle(PrimaryCTAStyle())
                    Button("Open Containing Folder") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: abs).deletingLastPathComponent())
                    }
                    .buttonStyle(InkButtonStyle(filled: false))
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(display, forType: .string)
                        model.showToast("Path copied")
                    }
                    .buttonStyle(InkButtonStyle(filled: false))
                    if safety.level != .protected && kind != .virtualDisk {
                        Button("Move to Trash…") {
                            Task {
                                let url = URL(fileURLWithPath: abs)
                                if model.isStaged(url) {
                                    model.showToast("Already in cleanup list")
                                    return
                                }
                                let ok = await model.cleanupQueue.stage(url, size: size, reason: "Biggest file: \(name)")
                                await model.refreshQueue()
                                model.showToast(ok ? "Added to cleanup review" : "Blocked by safety rules")
                            }
                        }
                        .buttonStyle(InkButtonStyle(filled: false))
                        .foregroundStyle(DiskMapTheme.danger)
                    }
                }
                .padding(.top, 4)
            }
            .padding(16)
        }
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(DiskMapType.caption)
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DiskMapTheme.ink)
                .textSelection(.enabled)
        }
    }

    private func relativeModified(_ day: Int32) -> String {
        guard day > 0 else { return "Unknown" }
        let today = AgeMap.today()
        let age = today - day
        if age <= 1 { return "Yesterday" }
        if age < 30 { return "\(age) days ago" }
        if age < 365 { return "\(age / 30) months ago" }
        return "\(age / 365) years ago"
    }
}
