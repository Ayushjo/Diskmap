import SwiftUI
import DiskMapCore

struct AppsView: View {
    @ObservedObject var model: ScanModel
    @State private var apps: [URL] = []
    @State private var selected: URL?
    @State private var leftovers: AppLeftovers?

    var body: some View {
        HSplitView {
            List(apps, id: \.self, selection: $selected) { url in
                Text(url.deletingPathExtension().lastPathComponent)
            }
            .frame(minWidth: 220)

            VStack(alignment: .leading, spacing: 8) {
                if let leftovers {
                    Text(leftovers.appName).font(.headline)
                    Text("App \(diskByteString(leftovers.bundleSize)) · leftovers \(diskByteString(leftovers.leftoverSize))")
                        .foregroundStyle(.secondary)
                    List(leftovers.leftoverPaths, id: \.path) { url in
                        Text(url.path).lineLimit(1)
                    }
                    Button("Stage App and Leftovers") {
                        Task { await stage(leftovers) }
                    }
                    Text("Staged for review. Nothing is removed until you confirm in Cleanup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Select an app to see caches, preferences, and containers that look like they belong to it. Matching is a guess — review before staging.")
                        .foregroundStyle(.secondary)
                        .padding()
                }
                Spacer()
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { apps = AppLeftoverFinder.applicationBundles(in: AppLeftoverFinder.defaultApplicationDirectories()) }
        .onChange(of: selected) { _, url in
            leftovers = url.map { AppLeftoverFinder.findLeftovers(for: $0) }
        }
    }

    private func stage(_ leftovers: AppLeftovers) async {
        _ = await model.cleanupQueue.stage(leftovers.bundlePath, size: leftovers.bundleSize, reason: "app leftover")
        for path in leftovers.leftoverPaths {
            _ = await model.cleanupQueue.stage(path, size: AppLeftoverFinder.allocatedSize(of: path), reason: "app leftover")
        }
        await model.refreshQueue()
    }
}
