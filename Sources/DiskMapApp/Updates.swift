import Sparkle
import SwiftUI

// TASK-083 — software updates through Sparkle: the ONLY place DiskMap may
// use the network (AGENTS.md rule 2, amended). Everything about it is opt-in:
// - nothing is created or started at launch unless the user turned on
//   automatic checks in Settings;
// - "Check for Updates…" is a user-initiated request;
// - a build without SUFeedURL and SUPublicEDKey in its Info.plist (e.g.
//   `swift run`) cannot check at all, and says so.
// A test fails if networking APIs appear in any other source file.

@MainActor
final class Updates: ObservableObject {
    static let shared = Updates()
    static let automaticKey = "CheckForUpdatesAutomatically"

    /// Off by default, and stays off until the user turns it on.
    static let automaticDefault = false

    private var controller: SPUStandardUpdaterController?

    /// True when this build carries an update feed and the key to verify it.
    var isConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String) ?? ""
        let key = (info["SUPublicEDKey"] as? String) ?? ""
        return !feed.isEmpty && !key.isEmpty
    }

    var checksAutomatically: Bool {
        UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool ?? Self.automaticDefault
    }

    /// Called at launch: starts Sparkle only if the user chose automatic checks.
    func startIfEnabled() {
        guard isConfigured, checksAutomatically else { return }
        setAutomaticChecks(true)
    }

    func checkForUpdates() {
        guard isConfigured else { return }
        updater().checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.automaticKey)
        guard isConfigured else { return }
        if enabled || controller != nil {
            updater().updater.automaticallyChecksForUpdates = enabled
        }
    }

    private func updater() -> SPUStandardUpdaterController {
        if let controller { return controller }
        let made = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        made.updater.automaticallyChecksForUpdates = checksAutomatically
        controller = made
        return made
    }
}

/// DiskMap ▸ Check for Updates…
struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Updates.shared.checkForUpdates() }
                .disabled(!Updates.shared.isConfigured)
                .help(Updates.shared.isConfigured ? "Ask the update server once" : "Updates aren’t set up in this build.")
        }
    }
}

/// Settings ▸ Updates.
struct UpdateSettingsSection: View {
    @AppStorage(Updates.automaticKey) private var automatic = Updates.automaticDefault

    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: Binding(
                get: { automatic },
                set: { automatic = $0; Updates.shared.setAutomaticChecks($0) }
            ))
            .disabled(!Updates.shared.isConfigured)
            Text(Updates.shared.isConfigured
                 ? "Off unless you turn it on. When on, DiskMap asks its update server about once a day — the only time it uses the network. Scans and cleanups never do."
                 : "This build has no update feed, so DiskMap never contacts any server. Download new versions yourself.")
                .font(DiskMapType.secondary)
                .foregroundStyle(DiskMapTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Updates")
        }
    }
}
