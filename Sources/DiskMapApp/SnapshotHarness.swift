import AppKit
import SwiftUI

/// Developer tool: renders the app's own window to PNG files so UI changes can
/// be checked without Screen Recording permission (the app draws itself
/// in-process; nothing else on screen is captured). Inert unless launched with
/// `--snapshot-dir`.
///
///     DiskMapApp --scan ~/some/folder --snapshot-dir /tmp/shots \
///         [--snapshot-destinations overview,cleanSafe] [--appearance dark]
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
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        Task { await run(into: URL(fileURLWithPath: dir, isDirectory: true)) }
    }

    private static func run(into dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = ScanModel.shared
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
        window.setContentSize(NSSize(width: 1280, height: 820))

        let appearanceName = value(after: "--appearance") ?? "light"
        for destination in destinations() {
            model.destination = destination
            // Let SwiftUI lay out and run the destination's `.task` work.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            write(window: window, to: dir.appendingPathComponent("\(key(destination))-\(appearanceName).png"))
        }
        NSApp.terminate(nil)
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
