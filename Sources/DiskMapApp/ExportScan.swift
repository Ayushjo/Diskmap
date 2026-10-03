import SwiftUI
import AppKit
import DiskMapCore

/// File ▸ Export Scan… (⇧⌘E), TASK-058. The same exporters as `diskmap
/// export`; the write runs off the main thread and ends in a toast.
struct ExportScanCommands: Commands {
    @ObservedObject var model: ScanModel

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Button("Export Scan…") { ExportScan.run(model: model) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.tree == nil || model.isScanning)
            Divider()
            // TASK-080: undo the last Move to Trash.
            Button(model.lastCleanup.map { "Put Back Last Cleanup (\($0.items.count))" } ?? "Put Back Last Cleanup") {
                Task { await model.putBackLastCleanup() }
            }
            .disabled(model.lastCleanup?.items.isEmpty ?? true)
        }
    }
}

@MainActor
enum ExportScan {
    static func run(model: ScanModel) {
        guard let tree = model.tree, let root = model.rootURL,
              model.allocatedTotals.count == tree.count, model.logicalTotals.count == tree.count else { return }

        let formats: [(ExportFormat, String)] = [
            (.json, "JSON (nested)"),
            (.ndjson, "NDJSON (one row per item)"),
            (.csv, "CSV"),
            (.ncdu, "ncdu (browse with ncdu -f)"),
        ]
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: formats.map(\.1))
        let label = NSTextField(labelWithString: "Format:")
        let accessory = NSStackView(views: [label, popup])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        let panel = NSSavePanel()
        panel.title = "Export Scan"
        panel.accessoryView = accessory
        panel.canCreateDirectories = true
        let baseName = root.lastPathComponent.isEmpty || root.path == "/" ? "Macintosh HD" : root.lastPathComponent
        func applyFormat() {
            let format = formats[max(0, popup.indexOfSelectedItem)].0
            let suffix = format == .ncdu ? "-ncdu" : ""
            panel.nameFieldStringValue = "\(baseName)\(suffix).\(format.fileExtension)"
        }
        applyFormat()
        let target = PopupTarget(applyFormat)
        popup.target = target
        popup.action = #selector(PopupTarget.changed)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = target
        let format = formats[max(0, popup.indexOfSelectedItem)].0
        let allocated = model.allocatedTotals, logical = model.logicalTotals

        model.showToast("Exporting \(tree.count.formatted()) items…")
        Task.detached(priority: .userInitiated) {
            let outcome = write(tree: tree, root: root, allocated: allocated, logical: logical, format: format, to: url)
            await MainActor.run {
                switch outcome {
                case .success(let bytes):
                    model.showToast("Exported \(ByteFormat.string(bytes)) to \(url.lastPathComponent)")
                case .failure(let error):
                    model.showToast("Export failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Streams straight to the file the save panel chose (it already asked
    /// before overwriting). No temp-and-delete dance: the app has exactly one
    /// removal path, and it is the cleanup queue.
    nonisolated static func write(tree: FileTree, root: URL, allocated: [Int64], logical: [Int64],
                                  format: ExportFormat, to url: URL) -> Result<Int64, Error> {
        do {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
            }
            let handle = try FileHandle(forWritingTo: url)
            var written: Int64 = 0
            var failure: Error?
            TreeExporter.export(tree: tree, root: root, allocated: allocated, logical: logical, format: format) { chunk in
                guard failure == nil else { return }
                let data = Data(chunk.utf8)
                do { try handle.write(contentsOf: data); written += Int64(data.count) }
                catch { failure = error }
            }
            try handle.close()
            if let failure { throw failure }
            return .success(written)
        } catch {
            return .failure(error)
        }
    }
}

private final class PopupTarget: NSObject {
    let onChange: () -> Void
    init(_ onChange: @escaping () -> Void) { self.onChange = onChange }
    @objc func changed() { onChange() }
}
