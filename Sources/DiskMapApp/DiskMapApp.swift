import SwiftUI
import AppKit

@main
struct DiskMapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("ShowMenuBarExtra") private var showMenuBarExtra = true

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
        }
        .commands {
            ExportScanCommands(model: ScanModel.shared)
            KeyboardCommands(model: ScanModel.shared)
            MenuBarCommands()
            AppearanceCommands()
        }
        Settings {
            SettingsView()
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

