import SwiftUI
import AppKit

@main
struct DiskMapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("ShowMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage(TextSize.storageKey) private var textSize = TextSize.standard.rawValue

    var body: some Scene {
        WindowGroup(id: "main") {
            // A new text size rebuilds the window so every token is re-read.
            ContentView()
                .id(textSize)
        }
        .commands {
            ExportScanCommands(model: ScanModel.shared)
            KeyboardCommands(model: ScanModel.shared)
            MenuBarCommands()
            AppearanceCommands()
            UpdateCommands()
        }
        Settings {
            SettingsView()
                .id(textSize)
        }
        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarStatusView(model: ScanModel.shared)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppAppearance.current.apply()
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            window.makeKeyAndOrderFront(nil)
        }
        // Don't wait for the SwiftUI view to appear. A terminal-launched
        // app can sit in the run loop without `.task` ever firing.
        ScanModel.shared.startIfRequested()
        SnapshotHarness.startIfRequested()
        // Sparkle starts only if the user turned automatic checks on (TASK-083).
        if !SnapshotHarness.isActive { Updates.shared.startIfEnabled() }
    }

    /// A folder dropped on the Dock icon, or `open -a DiskMap ~/code`
    /// (TASK-063). The bundle declares folders with LSHandlerRank None, so
    /// DiskMap never becomes the default app for opening folders.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let folder = scannableFolder(urls) else { return }
        Task { @MainActor in
            guard !ScanModel.shared.isScanning else { return }
            await ScanModel.shared.scan(folder)
        }
    }
}

