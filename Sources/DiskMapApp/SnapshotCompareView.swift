import AppKit
import DiskMapCore
import SwiftUI

/// Snapshots › Compare: the story first, then where it happened, then a
/// drill-down whose rows always add up to the folder above them.
struct SnapshotCompareView: View {
    let comparison: SnapshotComparison
    let hotspots: [SnapshotComparison.Entry]
    let beforeRecord: SnapshotRecord
    let afterRecord: SnapshotRecord
    @Binding var browsePath: String
    @Binding var selectedPath: String?

    @State private var levelFilter: LevelFilter = .all
    @State private var showAllRows = false
    @State private var tab: Tab = .biggest

    enum Tab: Hashable { case biggest, all }

    enum LevelFilter: String, CaseIterable, Identifiable {
        case all, grew, shrank, added, removed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .grew: return "Grew"
            case .shrank: return "Shrank"
            case .added: return "New"
            case .removed: return "Removed"
            }
        }
        func matches(_ entry: SnapshotComparison.Entry) -> Bool {
            switch self {
            case .all: return true
            case .grew: return entry.kind == .grew
            case .shrank: return entry.kind == .shrunk
            case .added: return entry.kind == .added
            case .removed: return entry.kind == .removed
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            summary
            KitTabs(tabs: [
                .init(id: Tab.biggest, title: "Biggest changes", count: "\(min(hotspots.count, 10))"),
                .init(id: Tab.all, title: "All changes", count: "\(comparison.children(of: browseEntry).count)"),
            ], selection: $tab)
            if tab == .biggest && !hotspots.isEmpty {
                hotspotList
            } else {
                browser
            }
        }
        .onAppear { if hotspots.isEmpty { tab = .all } }
    }

    // MARK: Summary

    private var root: SnapshotComparison.Entry { comparison.root }

    private var summary: some View {
        let split = comparison.split(of: root)
        let scale = max(root.before, root.after, 1)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(SnapshotCompareText.signed(root.delta))
                    .font(DiskMapType.display)
                    .foregroundStyle(DiskMapTheme.ink)
                Text("over \(SnapshotCompareText.span(from: beforeRecord.header.capturedAt, to: afterRecord.header.capturedAt))")
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.ink2)
            }
            VStack(alignment: .leading, spacing: 6) {
                sizeBar(label: beforeRecord.isCurrent ? "Now" : shortDate(beforeRecord), bytes: root.before, scale: scale, tint: DiskMapTheme.ink3.opacity(0.6))
                sizeBar(label: afterRecord.isCurrent ? "Now" : shortDate(afterRecord), bytes: root.after, scale: scale, tint: DiskMapTheme.ink.opacity(0.55))
            }
            .frame(maxWidth: 560)
            Text(stripText(split: split))
                .font(DiskMapType.figureSmall)
                .foregroundStyle(DiskMapTheme.ink2)
            Text(SnapshotCompareText.story(hotspots: hotspots, total: root.delta))
                .font(DiskMapType.body)
                .foregroundStyle(DiskMapTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !comparison.rootsMatch {
                DiskMapNoticeBanner(symbol: "exclamationmark.triangle", tint: DiskMapTheme.review,
                                    title: "These snapshots are of different folders",
                                    detail: "Paths may not line up between them.")
            }
        }
    }

    private func stripText(split: (grew: Int64, shrank: Int64)) -> String {
        var parts = ["Grew \(ByteFormat.string(split.grew))", "Freed \(ByteFormat.string(-split.shrank))"]
        if afterRecord.freeBytes > 0, beforeRecord.freeBytes > 0 {
            parts.append("Mac free \(SnapshotCompareText.signed(afterRecord.freeBytes - beforeRecord.freeBytes))")
        }
        return parts.joined(separator: "  ·  ")
    }

    private func shortDate(_ record: SnapshotRecord) -> String {
        record.header.capturedAt.formatted(.dateTime.month(.abbreviated).day())
    }

    private func sizeBar(label: String, bytes: Int64, scale: Int64, tint: Color) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(DiskMapType.figureSmall)
                .foregroundStyle(DiskMapTheme.ink3)
                .frame(width: 56, alignment: .leading)
            ProportionBar(fraction: Double(bytes) / Double(scale), tint: tint, height: 6)
            Text(ByteFormat.string(bytes))
                .font(DiskMapType.figureSmall)
                .foregroundStyle(DiskMapTheme.ink)
                .frame(width: 80, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Lists

    private var hotspotList: some View {
        let scale = hotspots.map { abs($0.delta) }.max() ?? 1
        return VStack(alignment: .leading, spacing: 0) {
            Text("Each row is where a change happened — not every folder above it.")
                .font(DiskMapType.secondary)
                .foregroundStyle(DiskMapTheme.ink3)
                .padding(.bottom, 6)
            ForEach(hotspots.prefix(10)) { entry in
                changeRow(entry, scale: scale, showParent: true) {
                    selectedPath = entry.path
                    browsePath = parentPath(of: entry.path)
                }
                RowSeparator(indent: 36)
            }
        }
    }

    private var browseEntry: SnapshotComparison.Entry {
        comparison.entry(atPath: browsePath) ?? root
    }

    private var browser: some View {
        let entry = browseEntry
        let children = comparison.children(of: entry)
        let visible = children.filter(levelFilter.matches)
        let scale = children.map { abs($0.delta) }.max() ?? 1
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                breadcrumbs
                Spacer()
                Text(SnapshotCompareText.signed(entry.delta))
                    .font(DiskMapType.figureSmall)
                    .foregroundStyle(DiskMapTheme.ink2)
            }
            HStack(spacing: 2) {
                ForEach(LevelFilter.allCases) { filter in
                    let count = filter == .all ? children.count : children.filter(filter.matches).count
                    if filter == .all || count > 0 {
                        Chip(title: filter.title, count: "\(count)", isOn: levelFilter == filter) { levelFilter = filter }
                    }
                }
            }
            if visible.isEmpty {
                Text(children.isEmpty ? "Nothing changed inside this folder." : "Nothing here matches that filter.")
                    .font(DiskMapType.secondary)
                    .foregroundStyle(DiskMapTheme.ink3)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(visible.prefix(showAllRows ? 500 : 30)) { child in
                        changeRow(child, scale: scale, showParent: false) { selectedPath = child.path }
                            .simultaneousGesture(TapGesture(count: 2).onEnded { if child.isDirectory { open(child.path) } })
                        RowSeparator(indent: 36)
                    }
                }
                if !showAllRows, visible.count > 30 {
                    Button("Show \(min(visible.count, 500) - 30) more") { showAllRows = true }
                        .buttonStyle(LinkButtonStyle())
                        .font(DiskMapType.secondary)
                } else if visible.count > 500 {
                    Text("Showing the 500 largest of \(visible.count.formatted()) changes here.")
                        .font(DiskMapType.secondary)
                        .foregroundStyle(DiskMapTheme.ink3)
                }
            }
        }
    }

    private var breadcrumbs: some View {
        let parts = browsePath.split(separator: "/").map(String.init)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                crumb(URL(fileURLWithPath: comparison.after.rootPath).lastPathComponent, path: "", isLast: parts.isEmpty)
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    Text("/").font(DiskMapType.figureSmall).foregroundStyle(DiskMapTheme.ink3)
                    crumb(part, path: parts.prefix(index + 1).joined(separator: "/"), isLast: index == parts.count - 1)
                }
            }
        }
    }

    private func crumb(_ title: String, path: String, isLast: Bool) -> some View {
        Button { open(path) } label: {
            Text(title)
                .font(isLast ? DiskMapType.bodyEmphasis : DiskMapType.body)
                .foregroundStyle(isLast ? DiskMapTheme.ink : DiskMapTheme.ink2)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .disabled(isLast)
    }

    private func open(_ path: String) {
        browsePath = path
        levelFilter = .all
        showAllRows = false
        selectedPath = path.isEmpty ? nil : path
        tab = .all
    }

    private func parentPath(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    private func changeRow(_ entry: SnapshotComparison.Entry, scale: Int64, showParent: Bool,
                           action: @escaping () -> Void) -> some View {
        let selected = selectedPath == entry.path
        return HStack(spacing: 4) {
            Button(action: action) {
                HStack(spacing: 12) {
                    Image(systemName: entry.isDirectory ? "folder" : "doc")
                        .font(.system(size: DiskMapType.scaled(13)))
                        .foregroundStyle(DiskMapTheme.ink2)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(DiskMapType.bodyEmphasis)
                            .foregroundStyle(DiskMapTheme.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(showParent
                             ? CanonicalPath.displayPath(absolutePath: (comparison.absolutePath(of: entry) as NSString).deletingLastPathComponent)
                             : SnapshotCompareText.beforeAfter(entry))
                            .font(DiskMapType.secondary)
                            .foregroundStyle(DiskMapTheme.ink3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let kind = entry.kind {
                        KindBadge(kind: kind).frame(width: 84, alignment: .leading)
                    }
                    DeltaBar(delta: entry.delta, scale: scale)
                        .frame(width: 100)
                    Text(SnapshotCompareText.signed(entry.delta))
                        .font(DiskMapType.figureStrong)
                        .foregroundStyle(DiskMapTheme.ink)
                        .frame(width: 84, alignment: .trailing)
                }
                .padding(.horizontal, 8)
                .frame(minHeight: DiskMapSpace.rowTwoLine)
                .background(RowBackground(selected: selected, hovering: false))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if entry.isDirectory {
                Button { open(entry.path) } label: {
                    Label("Show what changed inside \(entry.name)", systemImage: "chevron.right")
                }
                .buttonStyle(IconButtonStyle(size: 24))
            } else {
                Color.clear.frame(width: 24, height: 24)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.name), \(entry.kind?.title ?? "unchanged"), \(SnapshotCompareText.signed(entry.delta))")
    }
}

/// Growth to the right of the centre line, freed space to the left, length
/// relative to the largest change in view.
struct DeltaBar: View {
    let delta: Int64
    let scale: Int64

    var body: some View {
        GeometryReader { proxy in
            let half = proxy.size.width / 2
            let length = max(2, half * CGFloat(min(1, Double(abs(delta)) / Double(max(scale, 1)))))
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(DiskMapTheme.line)
                    .frame(width: 1)
                    .offset(x: half)
                RoundedRectangle(cornerRadius: 2)
                    .fill(SnapshotCompareText.color(for: delta).opacity(0.75))
                    .frame(width: length, height: 6)
                    .offset(x: delta >= 0 ? half : half - length)
            }
            .frame(height: proxy.size.height)
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }
}

/// A change kind as a dot + word.
struct KindBadge: View {
    let kind: SnapshotChangeKind

    var body: some View {
        SafetyLabel(level: nil, title: kind == .added ? "New" : kind.title, tint: tint)
    }

    private var tint: Color {
        switch kind {
        case .added, .grew: return DiskMapTheme.review
        case .removed, .shrunk: return DiskMapTheme.safe
        }
    }
}

enum SnapshotCompareText {
    static func signed(_ delta: Int64) -> String {
        delta == 0 ? "±0" : (delta > 0 ? "+" : "−") + ByteFormat.string(abs(delta))
    }

    /// Growth costs space (review), shrinking frees it (safe).
    static func color(for delta: Int64) -> Color {
        delta > 0 ? DiskMapTheme.review : delta < 0 ? DiskMapTheme.safe : DiskMapTheme.mutedLabel
    }

    /// "1.2 GB → 3.4 GB", "— → 392.9 MB" for new, "1.2 GB → gone" for removed.
    static func beforeAfter(_ entry: SnapshotComparison.Entry) -> String {
        let before = entry.beforeID == nil ? "—" : ByteFormat.string(entry.before)
        let after = entry.afterID == nil ? "gone" : ByteFormat.string(entry.after)
        return "\(before) → \(after)"
    }

    static func span(from start: Date, to end: Date) -> String {
        let seconds = abs(end.timeIntervalSince(start))
        let days = Int(seconds / 86_400)
        if days >= 2 { return "\(days) days" }
        if days == 1 { return "1 day" }
        let hours = Int(seconds / 3_600)
        return hours >= 1 ? "\(hours) hour\(hours == 1 ? "" : "s")" : "less than an hour"
    }

    /// "Mostly Media (+29.5 GB) and vm_bundles (+11.4 GB, new). Freed:
    /// malcolm… (−17.1 GB, removed)." Built only from hotspots, so every
    /// name in it can be found in the list below.
    static func story(hotspots: [SnapshotComparison.Entry], total: Int64) -> String {
        func describe(_ entry: SnapshotComparison.Entry) -> String {
            let suffix: String
            switch entry.kind {
            case .added: suffix = ", new"
            case .removed: suffix = ", removed"
            default: suffix = ""
            }
            return "\(label(entry)) (\(signed(entry.delta))\(suffix))"
        }
        let growth = hotspots.filter { $0.delta > 0 }.prefix(2)
        let freed = hotspots.filter { $0.delta < 0 }.prefix(2)
        guard !growth.isEmpty || !freed.isEmpty else {
            return total == 0 ? "Nothing changed in size." : "The change is spread thinly across many small items."
        }
        var sentences: [String] = []
        if !growth.isEmpty {
            sentences.append("Growth came mostly from " + growth.map(describe).joined(separator: " and ") + ".")
        }
        if !freed.isEmpty {
            sentences.append("Space was freed by " + freed.map(describe).joined(separator: " and ") + ".")
        }
        return sentences.joined(separator: " ")
    }

    /// Last component, with its parent when the name alone says little
    /// ("Message › Media" rather than "Media").
    static func label(_ entry: SnapshotComparison.Entry) -> String {
        let parts = entry.path.split(separator: "/")
        guard let last = parts.last else { return entry.name }
        if parts.count >= 2, last.count <= 12, !last.contains(".") {
            return "\(parts[parts.count - 2]) › \(last)"
        }
        return String(last)
    }
}
