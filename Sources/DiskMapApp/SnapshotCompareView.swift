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
        VStack(alignment: .leading, spacing: 14) {
            summaryCard
            if !hotspots.isEmpty { hotspotCard }
            browserCard
        }
    }

    // MARK: Summary

    private var root: SnapshotComparison.Entry { comparison.root }

    private var summaryCard: some View {
        let split = comparison.split(of: root)
        let scale = max(root.before, root.after, 1)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(SnapshotCompareText.signed(root.delta))
                    .font(.system(size: DiskMapType.scaled(30), weight: .semibold).monospacedDigit())
                    .foregroundStyle(SnapshotCompareText.color(for: root.delta))
                Text("in \(CanonicalPath.displayPath(absolutePath: comparison.after.rootPath)) over \(SnapshotCompareText.span(from: beforeRecord.header.capturedAt, to: afterRecord.header.capturedAt))")
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
            VStack(alignment: .leading, spacing: 6) {
                sizeBar(label: beforeRecord.isCurrent ? "Now" : shortDate(beforeRecord), bytes: root.before, scale: scale, tint: DiskMapTheme.mutedLabel.opacity(0.45))
                sizeBar(label: afterRecord.isCurrent ? "Now" : shortDate(afterRecord), bytes: root.after, scale: scale, tint: DiskMapTheme.info)
            }
            HStack(spacing: 8) {
                chip(symbol: "arrow.up.right", text: "Grew \(ByteFormat.string(split.grew))", tint: DiskMapTheme.review)
                chip(symbol: "arrow.down.right", text: "Freed \(ByteFormat.string(-split.shrank))", tint: DiskMapTheme.safe)
                if afterRecord.freeBytes > 0, beforeRecord.freeBytes > 0 {
                    let free = afterRecord.freeBytes - beforeRecord.freeBytes
                    chip(symbol: "internaldrive", text: "Mac free space \(SnapshotCompareText.signed(free))",
                         tint: free < 0 ? DiskMapTheme.review : DiskMapTheme.safe)
                }
            }
            Text(SnapshotCompareText.story(hotspots: hotspots, total: root.delta))
                .font(DiskMapType.body)
                .foregroundStyle(DiskMapTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !comparison.rootsMatch {
                Label("These snapshots were taken of different folders, so paths may not line up.", systemImage: "exclamationmark.triangle")
                    .font(DiskMapType.caption)
                    .foregroundStyle(DiskMapTheme.review)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SnapshotCompareText.card)
    }

    private func shortDate(_ record: SnapshotRecord) -> String {
        record.header.capturedAt.formatted(.dateTime.month(.abbreviated).day())
    }

    private func sizeBar(label: String, bytes: Int64, scale: Int64, tint: Color) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(DiskMapType.captionStrong)
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .frame(width: 56, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(DiskMapTheme.navSelected)
                    Capsule().fill(tint)
                        .frame(width: max(4, proxy.size.width * CGFloat(Double(bytes) / Double(scale))))
                }
            }
            .frame(height: 10)
            Text(ByteFormat.string(bytes))
                .font(DiskMapType.captionStrong.monospacedDigit())
                .foregroundStyle(DiskMapTheme.ink)
                .frame(width: 80, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func chip(symbol: String, text: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(DiskMapType.captionStrong.monospacedDigit())
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    // MARK: Hotspots

    private var hotspotCard: some View {
        let scale = hotspots.map { abs($0.delta) }.max() ?? 1
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("What changed most")
                    .font(DiskMapType.bodyStrong)
                Text("Each row is where a change actually happened — not every folder above it.")
                    .font(DiskMapType.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
            ForEach(hotspots.prefix(10)) { entry in
                changeRow(entry, scale: scale, showParent: true) {
                    selectedPath = entry.path
                    browsePath = parentPath(of: entry.path)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SnapshotCompareText.card)
    }

    // MARK: Browser

    private var browseEntry: SnapshotComparison.Entry {
        comparison.entry(atPath: browsePath) ?? root
    }

    private var browserCard: some View {
        let entry = browseEntry
        let children = comparison.children(of: entry)
        let visible = children.filter(levelFilter.matches)
        let scale = children.map { abs($0.delta) }.max() ?? 1
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Browse all changes")
                    .font(DiskMapType.bodyStrong)
                Spacer()
                Text("\(SnapshotCompareText.signed(entry.delta)) · \(children.count.formatted()) changed")
                    .font(DiskMapType.captionStrong.monospacedDigit())
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
            breadcrumbs
            HStack(spacing: 6) {
                ForEach(LevelFilter.allCases) { filter in
                    let count = filter == .all ? children.count : children.filter(filter.matches).count
                    Button { levelFilter = filter } label: {
                        Text("\(filter.title) \(count)")
                            .font(.system(size: DiskMapType.scaled(11), weight: levelFilter == filter ? .semibold : .regular))
                            .foregroundStyle(levelFilter == filter ? DiskMapTheme.ink : DiskMapTheme.mutedLabel)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(levelFilter == filter ? DiskMapTheme.navSelected : .clear))
                    }
                    .buttonStyle(.plain)
                    .disabled(count == 0 && filter != .all)
                }
            }
            if visible.isEmpty {
                Text(children.isEmpty ? "Nothing changed inside this folder." : "Nothing in this folder matches that filter.")
                    .font(DiskMapType.small)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .padding(.vertical, 12)
            } else {
                ForEach(visible.prefix(showAllRows ? 500 : 30)) { child in
                    changeRow(child, scale: scale, showParent: false) {
                        selectedPath = child.path
                    }
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        if child.isDirectory { open(child.path) }
                    })
                }
                if !showAllRows, visible.count > 30 {
                    Button("Show \(min(visible.count, 500) - 30) more") { showAllRows = true }
                        .buttonStyle(.link)
                        .font(DiskMapType.captionStrong)
                        .padding(.leading, 8)
                } else if visible.count > 500 {
                    Text("Showing the 500 largest of \(visible.count.formatted()) changes here.")
                        .font(DiskMapType.caption)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SnapshotCompareText.card)
    }

    private var breadcrumbs: some View {
        let parts = browsePath.split(separator: "/").map(String.init)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                crumb(CanonicalPath.displayPath(absolutePath: comparison.after.rootPath), path: "", isLast: parts.isEmpty)
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    Image(systemName: "chevron.right")
                        .font(DiskMapType.micro)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                    crumb(part, path: parts.prefix(index + 1).joined(separator: "/"), isLast: index == parts.count - 1)
                }
            }
        }
    }

    private func crumb(_ title: String, path: String, isLast: Bool) -> some View {
        Button { open(path) } label: {
            Text(title)
                .font(isLast ? DiskMapType.captionStrong : DiskMapType.caption)
                .foregroundStyle(isLast ? DiskMapTheme.ink : DiskMapTheme.info)
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
    }

    private func parentPath(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    // MARK: Rows

    private func changeRow(_ entry: SnapshotComparison.Entry, scale: Int64, showParent: Bool,
                           action: @escaping () -> Void) -> some View {
        let selected = selectedPath == entry.path
        return HStack(spacing: 10) {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                        .foregroundStyle(entry.isDirectory ? DiskMapTheme.info : DiskMapTheme.mutedLabel)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(entry.name)
                                .font(DiskMapType.smallStrong)
                                .foregroundStyle(DiskMapTheme.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let kind = entry.kind { KindBadge(kind: kind) }
                        }
                        Text(showParent
                             ? CanonicalPath.displayPath(absolutePath: (comparison.absolutePath(of: entry) as NSString).deletingLastPathComponent)
                             : SnapshotCompareText.beforeAfter(entry))
                            .font(DiskMapType.caption.monospacedDigit())
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    DeltaBar(delta: entry.delta, scale: scale)
                        .frame(width: 120)
                    Text(SnapshotCompareText.signed(entry.delta))
                        .font(DiskMapType.smallStrong.monospacedDigit())
                        .foregroundStyle(SnapshotCompareText.color(for: entry.delta))
                        .frame(width: 88, alignment: .trailing)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if entry.isDirectory {
                Button { open(entry.path) } label: {
                    Image(systemName: "chevron.right")
                        .font(DiskMapType.captionStrong)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .frame(width: 22, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show what changed inside \(entry.name)")
            } else {
                Color.clear.frame(width: 22, height: 28)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? DiskMapTheme.navSelected : .clear))
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
                    .fill(DiskMapTheme.cardStroke)
                    .frame(width: 1)
                    .offset(x: half)
                RoundedRectangle(cornerRadius: 2)
                    .fill(SnapshotCompareText.color(for: delta))
                    .frame(width: length, height: 8)
                    .offset(x: delta >= 0 ? half : half - length)
            }
            .frame(height: proxy.size.height)
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }
}

struct KindBadge: View {
    let kind: SnapshotChangeKind

    var body: some View {
        let title: String = kind == .added ? "New" : kind.title
        Text(title)
            .font(DiskMapType.microStrong)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.13)))
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

    static var card: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(DiskMapTheme.cardFill)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DiskMapTheme.cardStroke, lineWidth: 1))
    }
}
