import AppKit
import Quartz
import SwiftUI
import DiskMapCore

struct CleanupQueueView: View {
    @ObservedObject var model: ScanModel
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Will free \(diskByteString(model.reclaimableBytes))")
                    .font(.headline)
                Spacer()
                Button("Move to Trash…") { confirming = true }
                    .disabled(model.stagedItems.isEmpty)
            }
            .padding(8)

            if model.stagedItems.isEmpty {
                Text("Nothing staged. Duplicates, Quick Wins, and app leftovers land here for review. Confirm moves them to the Trash — nothing is deleted directly.")
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(grouped.keys.sorted(), id: \.self) { reason in
                        Section(reason) {
                            ForEach(grouped[reason] ?? []) { item in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.url.path).lineLimit(1)
                                        if item.sharesStorageGroup != nil {
                                            Text("Shared storage. Counted as free only if every copy of this group is in the queue.")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Text(diskByteString(item.size))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Button("Quick Look") { QuickLookPresenter.shared.present(item.url) }
                                    Button("Remove") {
                                        Task {
                                            await model.cleanupQueue.unstage(id: item.id)
                                            await model.refreshQueue()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if !model.lastCommitLines.isEmpty {
                // A big commit reports one line per item — bound it so the
                // report can't push the staged list out of the window.
                ScrollView {
                    Text(model.lastCommitLines.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 120)
                .overlay(alignment: .top) { Divider() }
            }
        }
        .task { await model.refreshQueue() }
        .confirmationDialog(
            "Move staged items to the Trash?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await model.commitCleanup() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will free about \(diskByteString(model.reclaimableBytes)). Items go to the Trash, not a permanent delete.")
        }
    }

    private var grouped: [String: [CleanupQueue.StagedItem]] {
        Dictionary(grouping: model.stagedItems, by: \.reason)
    }
}

final class QuickLookPresenter: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPresenter()
    private var url: URL?

    func present(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return }
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem {
        (url ?? URL(fileURLWithPath: "/")) as NSURL
    }
}
