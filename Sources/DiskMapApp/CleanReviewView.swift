import AppKit
import DiskMapCore
import SwiftUI

/// Clean section — review-first entry points backed by Quick Wins + analysis.
struct CleanReviewView: View {
    @ObservedObject var model: ScanModel
    var mode: AppDestination
    @Binding var showCleanup: Bool
    var pickFolder: () -> Void

    var body: some View {
        Group {
            if model.isScanning {
                ProgressView("Scanning…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.tree == nil {
                VStack(spacing: 12) {
                    Text("Scan first to find cleanup candidates.")
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                    Button("Choose Folder…", action: pickFolder).buttonStyle(InkButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .background(DiskMapTheme.cream)
    }

    private var content: some View {
        let totals = model.selectedTotals
        let hits = filteredHits(totals: totals)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                downloadsOrMediaExtras(totals: totals)
                if hits.isEmpty && mode != .cleanDownloads && mode != .cleanMedia {
                    Text("No matching candidates in this scan.")
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
                ForEach(hits, id: \.id) { hit in
                    hitRow(hit: hit, totals: totals)
                }
                Button("Open cleanup review…") { showCleanup = true }
                    .buttonStyle(InkButtonStyle())
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func downloadsOrMediaExtras(totals: [Int64]) -> some View {
        if mode == .cleanDownloads || mode == .cleanMedia {
            let files = model.analysis.topFiles.filter { file in
                let lower = file.name.lowercased()
                let path = file.relativePath.lowercased()
                if mode == .cleanDownloads {
                    return path.contains("downloads")
                }
                return lower.hasSuffix(".mkv") || lower.hasSuffix(".mp4") || lower.hasSuffix(".mov")
                    || lower.hasSuffix(".avi") || lower.hasSuffix(".iso") || lower.hasSuffix(".dmg")
            }
            if files.isEmpty {
                Text("No matching large files in this scan.")
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            } else {
                ForEach(files.prefix(40)) { file in
                    fileRow(file)
                }
            }
        }
    }

    private func hitRow(hit: QuickWins.Hit, totals: [Int64]) -> some View {
        let size = totals.indices.contains(Int(hit.id)) ? totals[Int(hit.id)] : 0
        let path = model.rootURL.flatMap { root in model.tree.map { $0.path(of: hit.id, root: root).path } } ?? hit.name
        let safety = SafetyClassifier.assess(path: path, name: hit.name, isDirectory: true)
        return PanelCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(safety.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                    Spacer()
                    Text(ByteFormat.string(size))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    safetyBadge(safety.level)
                }
                Text(safety.reason)
                    .font(DiskMapType.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
                Text(path)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .lineLimit(2)
                HStack {
                    Button("Reveal") {
                        if let root = model.rootURL, let tree = model.tree {
                            NSWorkspace.shared.activateFileViewerSelecting([tree.path(of: hit.id, root: root)])
                        }
                    }
                    .buttonStyle(InkButtonStyle(filled: false))
                    Button("Add to review") {
                        Task {
                            guard let root = model.rootURL, let tree = model.tree else { return }
                            let url = tree.path(of: hit.id, root: root)
                            if model.isStaged(url) {
                                model.showToast("Already in cleanup list")
                                return
                            }
                            let _ = await model.cleanupQueue.stage(url, size: size, reason: "Review cleanup: \(hit.name)")
                            await model.refreshQueue()
                            model.showToast("Added to cleanup review")
                        }
                    }
                    .buttonStyle(PrimaryCTAStyle())
                    .disabled(safety.level == .protected)
                }
            }
        }
    }

    private func fileRow(_ file: StorageFileHit) -> some View {
        let path = (model.rootURL?.path ?? "") + "/" + file.relativePath
        let safety = SafetyClassifier.assess(path: path, name: file.name, isDirectory: false)
        return PanelCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(file.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                        .lineLimit(1)
                    Spacer()
                    Text(ByteFormat.string(file.bytes))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    safetyBadge(safety.level)
                }
                Text(safety.reason)
                    .font(DiskMapType.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                Text(file.relativePath)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .lineLimit(2)
                Button("Add to review") {
                    Task {
                        guard let root = model.rootURL, let tree = model.tree else { return }
                        let url = tree.path(of: file.nodeID, root: root)
                        if model.isStaged(url) {
                            model.showToast("Already in cleanup list")
                            return
                        }
                        let _ = await model.cleanupQueue.stage(url, size: file.bytes, reason: "Review cleanup: \(file.name)")
                        await model.refreshQueue()
                        model.showToast("Added to cleanup review")
                    }
                }
                .buttonStyle(PrimaryCTAStyle())
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(mode.label)
                .font(DiskMapType.title)
                .foregroundStyle(DiskMapTheme.ink)
            Text("Review candidates before anything moves to Trash. Nothing is deleted automatically.")
                .font(DiskMapType.body)
                .foregroundStyle(DiskMapTheme.mutedLabel)
            if model.analysis.quickWinBytes > 0 || model.analysis.forgottenBytes > 0 {
                HStack(spacing: 10) {
                    if model.analysis.quickWinBytes > 0 {
                        metricChip(
                            label: "Quick wins",
                            value: ByteFormat.string(model.analysis.quickWinBytes)
                        )
                    }
                    if model.analysis.forgottenBytes > 0 {
                        metricChip(
                            label: "Forgotten",
                            value: ByteFormat.string(model.analysis.forgottenBytes)
                        )
                    }
                    metricChip(
                        label: "Worth reviewing",
                        value: ByteFormat.string(model.analysis.reviewableBytes)
                    )
                }
            }
        }
    }

    private func metricChip(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(DiskMapTheme.ink)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DiskMapTheme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                )
        )
    }

    private func filteredHits(totals: [Int64]) -> [QuickWins.Hit] {
        let all = model.cachedQuickWins
        switch mode {
        case .cleanCaches:
            return all.filter { hit in
                let n = hit.name.lowercased()
                return n.contains("cache") || n == "caches" || n.contains("log")
            }
        case .cleanDownloads, .cleanMedia:
            return []
        default:
            return all.sorted { a, b in
                let sa = totals.indices.contains(Int(a.id)) ? totals[Int(a.id)] : 0
                let sb = totals.indices.contains(Int(b.id)) ? totals[Int(b.id)] : 0
                return sa > sb
            }
        }
    }

    private func safetyBadge(_ level: SafetyLevel) -> some View {
        Text(level.title)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(badgeColor(level))
            .background(Capsule().fill(badgeColor(level).opacity(0.12)))
    }

    private func badgeColor(_ level: SafetyLevel) -> Color {
        switch level {
        case .safe: return DiskMapTheme.safe
        case .review: return DiskMapTheme.review
        case .protected: return DiskMapTheme.danger
        }
    }
}
