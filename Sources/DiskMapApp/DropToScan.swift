import AppKit
import SwiftUI
import UniformTypeIdentifiers

// TASK-063: drop a folder on the window or the Dock icon to scan it.

/// The folder to scan from a drop or an "open" request, if any. Files are
/// ignored rather than scanning their parent — a scan is a deliberate choice
/// of folder, not a guess.
func scannableFolder(_ urls: [URL]) -> URL? {
    urls.first { url in
        var isDirectory: ObjCBool = false
        return url.isFileURL && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue && url.pathExtension != "app"
    }?.standardizedFileURL
}

struct DropToScan: ViewModifier {
    @ObservedObject var model: ScanModel
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                guard !model.isScanning else { return false }
                let group = DispatchGroup()
                let collected = Collected()
                for provider in providers {
                    group.enter()
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url { collected.append(url) }
                        group.leave()
                    }
                }
                group.notify(queue: .main) {
                    guard let folder = scannableFolder(collected.urls) else {
                        model.showToast("Drop a folder to scan it")
                        return
                    }
                    Task { await model.scan(folder) }
                }
                return true
            }
            .overlay {
                if isTargeted {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(DiskMapTheme.accent.opacity(0.08))
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(DiskMapTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        Label(model.isScanning ? "Wait for the current scan to finish" : "Drop a folder to scan it",
                              systemImage: "arrow.down.doc")
                            .font(DiskMapType.heading)
                            .foregroundStyle(DiskMapTheme.ink)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(DiskMapTheme.raised))
                    }
                    .padding(10)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Drop a folder to scan it")
                }
            }
    }

    /// Drop callbacks arrive on arbitrary threads.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [URL] = []
        var urls: [URL] { lock.withLock { storage } }
        func append(_ url: URL) { lock.withLock { storage.append(url) } }
    }
}
