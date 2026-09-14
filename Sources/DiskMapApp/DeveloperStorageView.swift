import DiskMapCore
import SwiftUI

struct DeveloperStorageView: View {
    @ObservedObject var model: ScanModel
    var pickFolder: () -> Void

    private let developerNames: Set<String> = [
        ".npm", ".nvm", ".yarn", ".pnpm-store", ".cargo", ".rustup", ".gradle",
        "DerivedData", "CoreSimulator", "node_modules", ".cocoapods", ".pub-cache",
        ".cursor", ".codex", ".docker", "Android", "sdk"
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
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Developer Storage")
                    .font(DiskMapType.title)
                    .foregroundStyle(DiskMapTheme.ink)
                Text(ByteFormat.string(total))
                    .font(DiskMapType.heroNumber)
                    .foregroundStyle(DiskMapTheme.developer)
                Text("Detected from known tool directories in this scan. Clearing caches is usually safer than deleting SDKs or project environments.")
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                ForEach(rows, id: \.nodeID) { row in
                    PanelCard {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(DiskMapTheme.ink)
                                Text(row.reason)
                                    .font(DiskMapType.caption)
                                    .foregroundStyle(DiskMapTheme.mutedLabel)
                            }
                            Spacer()
                            Text(ByteFormat.string(row.bytes))
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        }
                    }
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
            // Skip nested node_modules under another counted node_modules later by size sort only
            let path = tree.path(of: id, root: root).path
            let safety = SafetyClassifier.assess(path: path, name: name, isDirectory: true)
            rows.append(Row(nodeID: id, title: safety.title, bytes: totals[i], reason: safety.reason))
        }
        rows.sort { $0.bytes > $1.bytes }
        // Deduplicate nested: drop a row if an ancestor row already listed
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
