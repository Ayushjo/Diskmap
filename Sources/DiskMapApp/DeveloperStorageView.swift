import AppKit
import DiskMapCore
import SwiftUI

struct DeveloperStorageView: View {
    @ObservedObject var model: ScanModel
    var pickFolder: () -> Void

    private let developerNames: Set<String> = [
        ".npm", ".nvm", ".yarn", ".pnpm-store", ".pnpm", ".cargo", ".rustup", ".gradle",
        "DerivedData", "CoreSimulator", "node_modules", ".cocoapods", ".pub-cache",
        ".cursor", ".codex", ".docker", "Android", "sdk", "__pycache__", ".venv", "venv"
    ]

    var body: some View {
        Group {
            if model.tree == nil {
                VStack(spacing: 12) {
                    Text("Scan to analyze developer storage.")
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                    Button("Choose Folder…", action: pickFolder).buttonStyle(InkButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                loaded
            }
        }
        .background(DiskMapTheme.cream)
    }

    private var loaded: some View {
        let rows = developerRows()
        let total = rows.reduce(Int64(0)) { $0 + $1.bytes }
        let groups = Dictionary(grouping: rows, by: \.group)
        let order = ["Xcode", "Node", "Rust", "Python", "Containers", "IDE / AI", "Other"]
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Developer Storage")
                    .font(DiskMapType.title)
                    .foregroundStyle(DiskMapTheme.ink)
                Text(ByteFormat.string(total))
                    .font(DiskMapType.heroNumber)
                    .foregroundStyle(DiskMapTheme.developer)
                Text("Detected from known tool directories in this scan. Clearing caches is usually safer than deleting SDKs or project environments. Every recommendation includes a safety reason.")
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                ForEach(order.filter { groups[$0] != nil }, id: \.self) { group in
                    Text(group)
                        .font(DiskMapType.section)
                        .foregroundStyle(DiskMapTheme.ink)
                        .padding(.top, 4)
                    ForEach(groups[group] ?? [], id: \.nodeID) { row in
                        PanelCard {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(row.title)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(DiskMapTheme.ink)
                                        Text(row.reason)
                                            .font(DiskMapType.caption)
                                            .foregroundStyle(DiskMapTheme.mutedLabel)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text(row.action)
                                            .font(DiskMapType.caption)
                                            .foregroundStyle(DiskMapTheme.ink.opacity(0.7))
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 4) {
                                        Text(ByteFormat.string(row.bytes))
                                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                        Text(row.level.title)
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(row.level == .safe ? DiskMapTheme.safe : (row.level == .protected ? DiskMapTheme.danger : DiskMapTheme.review))
                                    }
                                }
                                HStack {
                                    Button("Reveal") {
                                        if let root = model.rootURL, let tree = model.tree {
                                            NSWorkspace.shared.activateFileViewerSelecting([tree.path(of: row.nodeID, root: root)])
                                        }
                                    }
                                    .buttonStyle(InkButtonStyle(filled: false))
                                    Button("Add to review") {
                                        Task {
                                            guard let root = model.rootURL, let tree = model.tree else { return }
                                            let url = tree.path(of: row.nodeID, root: root)
                                            if model.isStaged(url) {
                                                model.showToast("Already in cleanup list")
                                                return
                                            }
                                            let ok = await model.cleanupQueue.stage(url, size: row.bytes, reason: "Developer: \(row.title)")
                                            await model.refreshQueue()
                                            model.showToast(ok ? "Added to cleanup review" : "Blocked by safety rules")
                                        }
                                    }
                                    .buttonStyle(PrimaryCTAStyle())
                                    .disabled(row.level == .protected)
                                }
                            }
                        }
                    }
                }
                if rows.isEmpty {
                    Text("No known developer directories found in this scan root.")
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
            }
            .padding(20)
        }
    }

    private struct Row {
        var nodeID: Int32
        var title: String
        var bytes: Int64
        var reason: String
        var action: String
        var level: SafetyLevel
        var group: String
    }

    private func group(for name: String) -> String {
        let n = name.lowercased()
        if n == "deriveddata" || n == "coresimulator" { return "Xcode" }
        if n == ".npm" || n == ".nvm" || n == ".yarn" || n == ".pnpm-store" || n == ".pnpm" || n == "node_modules" {
            return "Node"
        }
        if n == ".cargo" || n == ".rustup" { return "Rust" }
        if n == ".venv" || n == "venv" || n == "__pycache__" || n == ".pub-cache" { return "Python" }
        if n == ".docker" || n == "android" || n == "sdk" { return "Containers" }
        if n == ".cursor" || n == ".codex" || n == ".gradle" || n == ".cocoapods" { return "IDE / AI" }
        return "Other"
    }

    private func developerRows() -> [Row] {
        guard let tree = model.tree, let root = model.rootURL else { return [] }
        let totals = model.selectedTotals
        var rows: [Row] = []
        for id in 0..<Int32(tree.count) {
            let i = Int(id)
            guard tree.isDirectory[i] else { continue }
            let name = tree.name(of: id)
            guard developerNames.contains(name) || developerNames.contains(name.lowercased()) else { continue }
            let path = tree.path(of: id, root: root).path
            let safety = SafetyClassifier.assess(path: path, name: name, isDirectory: true)
            rows.append(Row(
                nodeID: id,
                title: safety.title,
                bytes: totals[i],
                reason: safety.reason,
                action: safety.recommendedAction,
                level: safety.level,
                group: group(for: name)
            ))
        }
        rows.sort { $0.bytes > $1.bytes }
        var kept: [Row] = []
        var keptIDs: [Int32] = []
        for row in rows {
            let ancestors = Set(tree.ancestorIDs(of: row.nodeID))
            if keptIDs.contains(where: { ancestors.contains($0) && $0 != row.nodeID }) {
                continue
            }
            kept.append(row)
            keptIDs.append(row.nodeID)
            if kept.count >= 40 { break }
        }
        return kept
    }
}
