import AppKit
import DiskMapCore
import SwiftUI

// TASK-064: a menu bar glance — free space, change since the last scan, and
// a one-click rescan. Strictly passive: it scans only when clicked, never
// notifies, and its only periodic work is one statfs(2) for the label every
// few minutes. Shown while DiskMap runs; hide it from the DiskMap menu.

/// What the menu bar compares against, kept across launches.
struct LastScanRecord: Codable, Equatable {
    var rootPath: String
    var scannedAt: Date
    var freeBytes: UInt64
    var scannedBytes: Int64

    static let key = "LastScanRecord"

    static func load(from defaults: UserDefaults = .standard) -> LastScanRecord? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(LastScanRecord.self, from: $0) }
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

enum MenuBarText {
    /// Changes under 50 MB are noise (caches, logs), not news.
    static let noise: Int64 = 50_000_000

    static func delta(previousFree: UInt64, currentFree: UInt64) -> String {
        let change = Int64(currentFree) - Int64(previousFree)
        if abs(change) < noise { return "Free space is about the same as at your last scan." }
        let amount = ByteFormat.string(abs(change))
        return change < 0 ? "\(amount) less free than at your last scan." : "\(amount) more free than at your last scan."
    }

    /// Low enough to say so in the menu bar itself.
    static func isLow(_ volume: VolumeStats) -> Bool {
        volume.totalBytes > 0 && Double(volume.freeBytes) / Double(volume.totalBytes) < 0.10
    }
}

/// Free space for the menu bar label, re-read every five minutes — one
/// statfs(2), the only periodic work. It publishes only when the value
/// changes. (A `TimelineView` in the label sent SwiftUI's menu bar
/// controller into an endless update loop at launch; found by sampling.)
@MainActor
final class MenuBarVolume: ObservableObject {
    static let shared = MenuBarVolume()
    @Published private(set) var volume: VolumeStats? = VolumeStats.forPath("/")
    private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let current = VolumeStats.forPath("/")
        if current != volume { volume = current }
    }
}

struct MenuBarLabel: View {
    @ObservedObject private var state = MenuBarVolume.shared

    var body: some View {
        if let volume = state.volume, MenuBarText.isLow(volume) {
            Label(ByteFormat.string(Int64(volume.freeBytes)) + " free", systemImage: "externaldrive.badge.exclamationmark")
        } else {
            Image(systemName: "internaldrive")
                .accessibilityLabel("DiskMap")
        }
    }
}

struct MenuBarStatusView: View {
    @ObservedObject var model: ScanModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("ShowMenuBarExtra") private var showMenuBarExtra = true
    // Read up front so the first layout already has its real height.
    @State private var volume: VolumeStats? = VolumeStats.forPath("/")
    @State private var record: LastScanRecord? = LastScanRecord.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let volume {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(ByteFormat.string(Int64(volume.freeBytes))) free")
                        .font(DiskMapType.section)
                        .foregroundStyle(MenuBarText.isLow(volume) ? DiskMapTheme.danger : DiskMapTheme.ink)
                    Text("\(volume.volumeName) · \(ByteFormat.string(Int64(volume.totalBytes))) total")
                        .font(DiskMapType.caption)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DiskMapTheme.navSelected)
                            Capsule()
                                .fill(MenuBarText.isLow(volume) ? DiskMapTheme.danger : DiskMapTheme.info)
                                .frame(width: proxy.size.width * min(1, max(0, volume.usedFraction)))
                        }
                    }
                    .frame(height: 6)
                    .accessibilityLabel("\(Int((volume.usedFraction * 100).rounded())) percent used")
                }
            }
            if let record {
                VStack(alignment: .leading, spacing: 3) {
                    if let volume {
                        Text(MenuBarText.delta(previousFree: record.freeBytes, currentFree: volume.freeBytes))
                            .font(DiskMapType.body)
                            .foregroundStyle(DiskMapTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Last scan: \(CanonicalPath.displayPath(absolutePath: record.rootPath)) · \(ByteFormat.string(record.scannedBytes)) · \(record.scannedAt.formatted(.relative(presentation: .named)))")
                        .font(DiskMapType.caption)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .lineLimit(2)
                }
            } else {
                Text("No scan yet.")
                    .font(DiskMapType.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
            if model.cachedDeveloper.summary.staleProjectCount > 0 {
                Text("\(model.cachedDeveloper.summary.staleProjectCount) projects untouched for 6+ months hold \(ByteFormat.string(model.cachedDeveloper.summary.staleReclaimableBytes)).")
                    .font(DiskMapType.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack(spacing: 8) {
                Button(model.isScanning ? "Scanning…" : "Rescan") { rescan() }
                    .buttonStyle(InkButtonStyle(filled: true))
                    .disabled(model.isScanning || (model.rootURL ?? record.map { URL(fileURLWithPath: $0.rootPath) }) == nil)
                Button("Open DiskMap") { openApp() }
                    .buttonStyle(InkButtonStyle(filled: false))
            }
            Button { showMenuBarExtra = false } label: {
                Text("Hide from Menu Bar")
                    .font(DiskMapType.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
            .buttonStyle(.plain)
            .help("Bring it back from the DiskMap menu › Show in Menu Bar")
        }
        .padding(14)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)   // the panel is as tall as its content
        .onAppear(perform: refresh)
        .onChange(of: model.isScanning) { _, _ in refresh() }
    }

    private func refresh() {
        volume = VolumeStats.forPath("/")
        record = LastScanRecord.load()
        MenuBarVolume.shared.refresh()
    }

    /// The same quick rescan as the toolbar; it runs only because it was clicked.
    private func rescan() {
        guard let root = model.rootURL ?? record.map({ URL(fileURLWithPath: $0.rootPath, isDirectory: true) }) else { return }
        Task { await model.scan(root) }
    }

    private func openApp() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}

/// DiskMap ▸ Show in Menu Bar.
struct MenuBarCommands: Commands {
    @AppStorage("ShowMenuBarExtra") private var showMenuBarExtra = true

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Toggle("Show in Menu Bar", isOn: $showMenuBarExtra)
        }
    }
}
