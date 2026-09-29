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
///         [--find-query "size>100MB age>1y"]
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
        // `--find-query "ext:mp4 size>100MB"` renders Find with that query.
        if let findQuery = value(after: "--find-query") { model.findQuery = findQuery }

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
            // `--click 600,300 --keys j,j,down` (window points from the top
            // left): synthetic events sent to this window only, to check the
            // keyboard wiring (TASK-062) without Accessibility permission.
            if value(after: "--click") != nil || value(after: "--keys") != nil {
                await sendInput(to: window)
                try? await Task.sleep(nanoseconds: 800_000_000)
                write(window: window, to: dir.appendingPathComponent("\(key(destination))-keys-\(appearanceName).png"))
            }
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
        // Let the scan cache finish writing, so a second harness run starts
        // from it (quick rescan screenshots).
        await model.waitForCacheSave()
        NSApp.terminate(nil)
    }

    private static func sendInput(to window: NSWindow) async {
        if let click = value(after: "--click") {
            let parts = click.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2, let height = window.contentView?.bounds.height {
                let point = NSPoint(x: parts[0], y: height - parts[1])
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil,
                                                      eventNumber: 0, clickCount: 1, pressure: 1) {
                        window.sendEvent(event)
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                // Past the double-click interval, so single-tap gestures fire.
                try? await Task.sleep(nanoseconds: UInt64((NSEvent.doubleClickInterval + 0.4) * 1_000_000_000))
            }
        }
        guard let keys = value(after: "--keys") else { return }
        let table: [String: (String, UInt16)] = [
            "j": ("j", 38), "k": ("k", 40), "down": ("\u{F701}", 125), "up": ("\u{F700}", 126),
            "return": ("\r", 36), "space": (" ", 49),
        ]
        for name in keys.split(separator: ",").map(String.init) {
            guard let (characters, code) = table[name] else { continue }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: characters,
                                                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                    window.sendEvent(event)
                }
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
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
        ("overview", .overview), ("find", .find), ("biggestFiles", .biggestFiles), ("biggestFolders", .biggestFolders),
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
