import AppKit
import DiskMapCore
import SwiftUI

/// Clean → Caches: app-grouped cache cleanup (reference DiskMap-SafeToReview).
struct CachesReviewView: View {
    @ObservedObject var model: ScanModel
    @Environment(\.diskMapContentWidth) private var contentWidth
    var onOpenCleanup: () -> Void
    var onBack: () -> Void

    enum Filter: String, CaseIterable, Identifiable {
        case all, safe, review
        var id: String { rawValue }
    }

    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var checked: Set<String> = []
    @State private var selectedID: String?

    private var caches: [ReviewableTarget] {
        model.cachedReviewables.filter { $0.category == .caches }
    }

    private var totalBytes: Int64 { caches.reduce(0) { $0 + $1.bytes } }

    private var visible: [ReviewableTarget] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var list = caches
        switch filter {
        case .all: break
        case .safe: list = list.filter(\.isGenerallySafe)
        case .review: list = list.filter(\.isReviewFirst)
        }
        if !q.isEmpty {
            list = list.filter {
                $0.displayName.lowercased().contains(q)
                    || $0.detail.lowercased().contains(q)
                    || $0.primaryPath.lowercased().contains(q)
            }
        }
        return list.sorted { $0.bytes > $1.bytes }
    }

    private var active: ReviewableTarget? {
        if let selectedID, let hit = visible.first(where: { $0.id == selectedID }) { return hit }
        return visible.first
    }

    private var selectedBytes: Int64 {
        visible.filter { checked.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    private var topLegend: [(String, Int64, Color)] {
        let top = Array(caches.prefix(4))
        let colors: [Color] = [
            Color(red: 0.25, green: 0.55, blue: 0.95),
            Color(red: 0.90, green: 0.35, blue: 0.35),
            Color(red: 0.30, green: 0.72, blue: 0.45),
            Color(red: 0.95, green: 0.75, blue: 0.25),
        ]
        var rows: [(String, Int64, Color)] = []
        for (i, t) in top.enumerated() {
            rows.append((t.displayName, t.bytes, colors[i % colors.count]))
        }
        let rest = totalBytes - top.reduce(Int64(0)) { $0 + $1.bytes }
        if rest > 0 {
            rows.append(("Other", rest, DiskMapTheme.mutedLabel.opacity(0.45)))
        }
        return rows
    }

    var body: some View {
        AdaptiveInspectorSplit(windowWidth: contentWidth, inspectionToken: selectedID, main: mainColumn, inspector: inspector)
        .background(DiskMapTheme.cream)
        .task {
            if model.cachedReviewables.isEmpty, model.tree != nil {
                model.refreshReviewableCache()
            }
        }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            infoBanner
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            summaryBlock
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            controls
            // Absorb leftover height so the column header stays under filters
            // (unstretched VStack + tall inspector was floating the header in a gap).
            VStack(alignment: .leading, spacing: 0) {
                listHeader
                Divider().overlay(DiskMapTheme.cardStroke)
                if visible.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            selectionBar
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Safe to Review")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            }
            .buttonStyle(.plain)

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(red: 0.45, green: 0.35, blue: 0.85))
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.45, green: 0.35, blue: 0.85).opacity(0.12)))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Caches")
                        .font(DiskMapType.title)
                        .foregroundStyle(DiskMapTheme.ink)
                    Text("Temporary application data that can usually be cleared. Apps will recreate these files when needed.")
                        .font(DiskMapType.body)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var infoBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color(red: 0.25, green: 0.45, blue: 0.90))
            Text("Clearing caches won’t delete your documents. Apps may take longer to start or re-download data the first time afterward.")
                .font(.system(size: 12))
                .foregroundStyle(DiskMapTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.90, green: 0.94, blue: 1.0))
        )
    }

    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(ByteFormat.string(totalBytes)) across \(caches.count.formatted()) cache groups")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DiskMapTheme.ink)

            Color.clear
                .frame(height: 12)
                .overlay {
                    GeometryReader { geo in
                        let total = max(1, totalBytes)
                        HStack(spacing: 2) {
                            ForEach(Array(topLegend.enumerated()), id: \.offset) { _, row in
                                let w = geo.size.width * CGFloat(Double(row.1) / Double(total))
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(row.2)
                                    .frame(width: max(row.1 > 0 ? 4 : 0, w))
                            }
                        }
                    }
                }

            HStack(spacing: 12) {
                ForEach(Array(topLegend.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 5) {
                        Circle().fill(row.2).frame(width: 7, height: 7)
                        Text("\(row.0) \(ByteFormat.string(row.1))")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(DiskMapTheme.ink)
                    }
                }
                Spacer()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DiskMapTheme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                )
        )
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                DiskMapSearchField(placeholder: "Search cache groups…", text: $query)
                Spacer()
                Text("Sort: Largest")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    pill("All (\(caches.count))", filter == .all) { filter = .all }
                    pill("Safe to clear (\(caches.filter(\.isGenerallySafe).count))", filter == .safe) { filter = .safe }
                    pill("Review first (\(caches.filter(\.isReviewFirst).count))", filter == .review) { filter = .review }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func pill(_ title: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .foregroundStyle(on ? Color.white : DiskMapTheme.ink)
                .background(Capsule().fill(on ? DiskMapTheme.ink : DiskMapTheme.navSelected))
        }
        .buttonStyle(.plain)
    }

    private var listHeader: some View {
        HStack(spacing: 8) {
            DiskMapColumnSpacer(width: 22)
            Text("Application").frame(maxWidth: .infinity, alignment: .leading)
            Text("Cache type").frame(width: 140, alignment: .leading)
            Text("Size").frame(width: 72, alignment: .trailing)
            Text("Safety").frame(width: 110, alignment: .leading)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(DiskMapTheme.mutedLabel)
        .padding(.horizontal, 28)
        .frame(height: DiskMapMetric.tableHeaderHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiskMapTheme.cardFill.opacity(0.72))
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(visible) { t in
                    cacheRow(t)
                    Rectangle()
                        .fill(DiskMapTheme.cardStroke.opacity(0.55))
                        .frame(height: 1)
                        .padding(.leading, 48)
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func cacheRow(_ t: ReviewableTarget) -> some View {
        let on = checked.contains(t.id)
        let selected = t.id == selectedID
        return HStack(spacing: 8) {
            Button {
                if on { checked.remove(t.id) } else { checked.insert(t.id) }
            } label: {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(on ? DiskMapTheme.ink : DiskMapTheme.mutedLabel)
            }
            .buttonStyle(.plain)
            .frame(width: 22)

            Button {
                selectedID = t.id
            } label: {
                HStack(spacing: 10) {
                    appIcon(t)
                    Text(t.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(t.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .lineLimit(1)
                        .frame(width: 140, alignment: .leading)
                    Text(ByteFormat.string(t.bytes))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .frame(width: 72, alignment: .trailing)
                    Text(t.isGenerallySafe ? "Generally safe" : "Review first")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .foregroundStyle(t.isGenerallySafe ? DiskMapTheme.safe : DiskMapTheme.review)
                        .background(Capsule().fill((t.isGenerallySafe ? DiskMapTheme.safe : DiskMapTheme.review).opacity(0.14)))
                        .frame(width: 110, alignment: .leading)
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? DiskMapTheme.ink.opacity(0.06) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
    }

    private func appIcon(_ t: ReviewableTarget) -> some View {
        Group {
            if let hint = t.bundleHint,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: hint) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: t.symbolName)
                    .font(.system(size: 12))
                    .foregroundStyle(DiskMapTheme.ink)
                    .frame(width: 22, height: 22)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No caches found")
                .font(DiskMapType.section)
            Text("This scan didn’t include Library/Caches, or caches are empty.")
                .font(DiskMapType.body)
                .foregroundStyle(DiskMapTheme.mutedLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectionBar: some View {
        HStack {
            if checked.isEmpty {
                Text("\(visible.count.formatted()) cache groups")
                    .font(.system(size: 12))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                Spacer()
                Button("Select all generally safe") {
                    checked = Set(visible.filter(\.isGenerallySafe).map(\.id))
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DiskMapTheme.ink)
            } else {
                Text("\(checked.count.formatted()) selected · \(ByteFormat.string(selectedBytes))")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Clear") { checked.removeAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                if let t = active {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: t.primaryPath)])
                    }
                    .buttonStyle(InkButtonStyle(filled: false))
                }
                Button("Add to Cleanup") {
                    Task { await stageChecked() }
                }
                .buttonStyle(InkButtonStyle(filled: true))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(DiskMapTheme.cardFill)
        .overlay(alignment: .top) { Divider().overlay(DiskMapTheme.cardStroke) }
    }

    private var inspector: some View {
        Group {
            if let t = active {
                ReviewableInspector(model: model, target: t, onOpenCleanup: onOpenCleanup) {
                    Task { await stageOne(t) }
                }
            } else {
                Color.clear
            }
        }
        .background(DiskMapTheme.cardFill)
    }

    private func stageChecked() async {
        let items = visible.filter { checked.contains($0.id) }
        var ok = 0
        for t in items where await stageTarget(t) { ok += 1 }
        await model.refreshQueue()
        model.showToast(ok > 0 ? "Added \(ok) to Cleanup" : "Nothing added")
        if ok > 0 { onOpenCleanup() }
    }

    private func stageOne(_ t: ReviewableTarget) async {
        let ok = await stageTarget(t)
        await model.refreshQueue()
        model.showToast(ok ? "Added to Cleanup" : "Blocked or already added")
        if ok { onOpenCleanup() }
    }

    private func stageTarget(_ t: ReviewableTarget) async -> Bool {
        var any = false
        for (idx, path) in t.paths.enumerated() {
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            if model.isStaged(url) { any = true; continue }
            var size = t.bytes / Int64(max(1, t.paths.count))
            if idx < t.nodeIDs.count {
                let nid = Int(t.nodeIDs[idx])
                if nid < model.selectedTotals.count { size = model.selectedTotals[nid] }
            }
            if await model.cleanupQueue.stage(url, size: size, reason: "Cache: \(t.displayName)") {
                any = true
            }
        }
        return any
    }
}

// Shared inspector for Safe to Review + Caches
struct ReviewableInspector: View {
    @ObservedObject var model: ScanModel
    let target: ReviewableTarget
    var onOpenCleanup: () -> Void
    var onStage: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: target.symbolName)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(DiskMapTheme.ink)
                        .frame(width: 56, height: 56)
                        .background(RoundedRectangle(cornerRadius: 14).fill(DiskMapTheme.ink.opacity(0.08)))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(target.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DiskMapTheme.ink)
                        Text(ByteFormat.string(target.bytes))
                            .font(.system(size: 26, weight: .semibold).monospacedDigit())
                        Text(target.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                }

                block(title: "What is this?", body: target.safety.reason)
                block(title: "What happens if I clear it?", body: target.consequence)

                VStack(alignment: .leading, spacing: 6) {
                    Text(target.isGenerallySafe ? "Generally safe to clear" : target.safety.level.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(target.isGenerallySafe ? DiskMapTheme.safe : DiskMapTheme.review)
                    Text(target.safety.recommendedAction)
                        .font(.system(size: 12))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill((target.isGenerallySafe ? DiskMapTheme.safe : DiskMapTheme.review).opacity(0.10))
                )

                if !target.paths.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Locations")
                            .font(.system(size: 12, weight: .semibold))
                        ForEach(target.paths.prefix(6), id: \.self) { path in
                            Text(CanonicalPath.displayPath(absolutePath: path))
                                .font(.system(size: 11))
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        if target.paths.count > 6 {
                            Text("+\(target.paths.count - 6) more")
                                .font(.system(size: 11))
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                        }
                    }
                }

                VStack(spacing: 8) {
                    if !target.isProtected {
                        Button(action: onStage) {
                            Label("Add to Cleanup", systemImage: "trash")
                        }
                        .buttonStyle(PrimaryCTAStyle(fullWidth: true))
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target.primaryPath)])
                    }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            CanonicalPath.displayPath(absolutePath: target.primaryPath),
                            forType: .string
                        )
                        model.showToast("Path copied")
                    }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                }
            }
            .padding(18)
        }
    }

    private func block(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DiskMapTheme.ink)
            Text(body)
                .font(.system(size: 12))
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0.93, green: 0.95, blue: 0.99))
        )
    }
}
