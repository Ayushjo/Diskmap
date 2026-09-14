import AppKit
import Quartz
import SwiftUI
import DiskMapCore

struct CleanupQueueView: View {
    @ObservedObject var model: ScanModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingTrash = false
    @State private var pendingRemove: CleanupQueue.StagedItem?
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cleanup Queue")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                    Text("Will free \(diskByteString(model.reclaimableBytes))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
                Spacer()
                Button("Move to Trash…") { confirmingTrash = true }
                    .buttonStyle(.borderedProminent)
                    .tint(DiskMapTheme.ink)
                    .disabled(model.stagedItems.isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                    .tint(DiskMapTheme.ink)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().overlay(DiskMapTheme.cardStroke)

            if model.stagedItems.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                    Text("Nothing staged")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                    Text("Duplicates, Quick Wins, and app leftovers land here for review. Confirm moves them to the Trash — nothing is deleted directly.")
                        .font(.system(size: 12))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                List {
                    ForEach(grouped.keys.sorted(), id: \.self) { reason in
                        Section {
                            ForEach(grouped[reason] ?? []) { item in
                                HStack(alignment: .center, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.url.lastPathComponent)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(DiskMapTheme.ink)
                                            .lineLimit(1)
                                        Text(item.url.path)
                                            .font(.system(size: 11))
                                            .foregroundStyle(DiskMapTheme.mutedLabel)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        if item.sharesStorageGroup != nil {
                                            Text("Shared storage — counted free only if every copy is queued.")
                                                .font(.caption)
                                                .foregroundStyle(DiskMapTheme.mutedLabel)
                                        } else {
                                            Text(diskByteString(item.size))
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(DiskMapTheme.mutedLabel)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    Button("Quick Look") { QuickLookPresenter.shared.present(item.url) }
                                        .buttonStyle(.bordered)
                                        .tint(DiskMapTheme.ink)
                                    Button("Remove", role: .destructive) {
                                        pendingRemove = item
                                        confirmRemove = true
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .padding(.vertical, 4)
                                .listRowBackground(DiskMapTheme.cardFill)
                            }
                        } header: {
                            Text(reason.capitalized)
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(DiskMapTheme.cream)
            }

            if !model.lastCommitLines.isEmpty {
                Text(model.lastCommitLines.joined(separator: "\n"))
                    .font(.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DiskMapTheme.inspectorFill)
            }
        }
        .background(DiskMapTheme.cream)
        .preferredColorScheme(.light)
        .frame(minWidth: 640, minHeight: 480)
        .task { await model.refreshQueue() }
        .confirmationDialog(
            "Move staged items to the Trash?",
            isPresented: $confirmingTrash,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await model.commitCleanup() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will free about \(diskByteString(model.reclaimableBytes)). Items go to the Trash, not a permanent delete.")
        }
        .confirmationDialog(
            "Remove from Cleanup Queue?",
            isPresented: $confirmRemove,
            titleVisibility: .visible
        ) {
            Button("Remove from Queue", role: .destructive) {
                guard let item = pendingRemove else { return }
                let name = item.url.lastPathComponent
                Task {
                    await model.cleanupQueue.unstage(id: item.id)
                    await model.refreshQueue()
                    model.showToast("Removed “\(name)” from Cleanup")
                    pendingRemove = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingRemove = nil
            }
        } message: {
            if let item = pendingRemove {
                Text(item.url.path)
            } else {
                Text("This item will stay on disk. Only the queue entry is removed.")
            }
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
