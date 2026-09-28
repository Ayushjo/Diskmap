import AppKit
import SwiftUI

/// Developer tool: renders the app's own window to PNG files so UI changes can
/// be checked without Screen Recording permission (the app draws itself
/// in-process; nothing else on screen is captured). Inert unless launched with
/// `--snapshot-dir`.
///
///     DiskMapApp --scan ~/some/folder --snapshot-dir /tmp/shots \
///         [--snapshot-destinations overview,cleanSafe] [--appearance dark] \
///         [--snapshot-at 3]      # also capture a mid-scan frame
///
/// After the scan finishes it visits each destination, waits for it to
/// settle, writes `<dir>/<destination>-<appearance>.png`, then quits.
@MainActor
enum SnapshotHarness {
    private static var arguments: [String] { CommandLine.arguments }

    static var isActive: Bool { value(after: "--snapshot-dir") != nil }

    static func startIfRequested() {
        guard let dir = value(after: "--snapshot-dir") else { return }
        if let appearance = value(after: "--appearance") {
            // hc-* renders the Increase Contrast token values via an in-app
            // override; the system setting itself is left alone.
            DiskMapTheme.forceIncreasedContrast = appearance.hasPrefix("hc-")
            NSApp.appearance = NSAppearance(named: appearance.hasSuffix("dark") ? .darkAqua : .aqua)
        }
        Task { await run(into: URL(fileURLWithPath: dir, isDirectory: true)) }
    }

    private static func run(into dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = ScanModel.shared
        let appearanceName = value(after: "--appearance") ?? "light"
        // Optional mid-scan frame: `--snapshot-at 3` captures 3 s after launch.
        if let at = value(after: "--snapshot-at").flatMap(Double.init),
           let window = NSApp.windows.first(where: { $0.contentView != nil }) {
            window.setContentSize(NSSize(width: 1280, height: 820))
            try? await Task.sleep(nanoseconds: UInt64(at * 1_000_000_000))
            write(window: window, to: dir.appendingPathComponent("scanning-\(appearanceName).png"))
        }
        // Wait for the launch scan (--scan) to finish, up to two minutes.
        for _ in 0..<1_200 {
            if model.tree != nil && !model.isScanning { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let window = NSApp.windows.first(where: { $0.contentView != nil && $0.isVisible })
            ?? NSApp.windows.first else {
            NSApp.terminate(nil)
            return
        }
        window.setContentSize(snapshotSize())

        for destination in destinations() {
            model.destination = destination
            // Wait for a lazily built catalog to be ready rather than a fixed
            // pause (a first launch after a rebuild once captured the loading
            // state), then let SwiftUI settle.
            if let catalog = catalog(for: destination) {
                for _ in 0..<150 where !model.isCatalogReady(catalog) {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            write(window: window, to: dir.appendingPathComponent("\(key(destination))-\(appearanceName).png"))
        }
        // `--explore-modes all` (or a comma list) also captures every
        // Visualize mode, since the harness otherwise only sees the default.
        if let modes = value(after: "--explore-modes") {
            let wanted = modes == "all" ? Set(ExploreViewMode.allCases.map(\.rawValue)) : Set(modes.split(separator: ",").map(String.init))
            model.destination = .visualize
            for mode in ExploreViewMode.allCases where wanted.contains(mode.rawValue) {
                model.exploreMode = mode
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                write(window: window, to: dir.appendingPathComponent("mode-\(mode.rawValue)-\(appearanceName).png"))
            }
        }
        NSApp.terminate(nil)
    }

    /// `--snapshot-size 1280x1600` for screens whose content runs below the fold.
    private static func catalog(for destination: AppDestination) -> ScanModel.Catalog? {
        switch destination {
        case .developerStorage: return .developer
        case .forgottenFiles: return .forgotten
        case .cleanSafe, .cleanCaches: return .reviewables
        case .cleanDownloads: return .oldDownloads
        case .cleanMedia: return .largeMedia
        default: return nil
        }
    }

    private static func snapshotSize() -> NSSize {
        let parts = (value(after: "--snapshot-size") ?? "1280x820").split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : NSSize(width: 1280, height: 820)
    }

    private static func write(window: NSWindow, to url: URL) {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }

    private static let all: [(String, AppDestination)] = [
        ("overview", .overview), ("biggestFiles", .biggestFiles), ("biggestFolders", .biggestFolders),
        ("forgottenFiles", .forgottenFiles), ("duplicates", .duplicates), ("cleanSafe", .cleanSafe),
        ("cleanCaches", .cleanCaches), ("cleanDownloads", .cleanDownloads), ("cleanMedia", .cleanMedia),
        ("fileBrowser", .fileBrowser), ("visualize", .visualize), ("developerStorage", .developerStorage),
        ("applications", .applications), ("snapshots", .snapshots),
    ]

    private static func destinations() -> [AppDestination] {
        guard let list = value(after: "--snapshot-destinations") else { return all.map(\.1) }
        let wanted = Set(list.split(separator: ",").map(String.init))
        return all.filter { wanted.contains($0.0) }.map(\.1)
    }

    private static func key(_ destination: AppDestination) -> String {
        all.first { $0.1 == destination }?.0 ?? "unknown"
    }

    private static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
