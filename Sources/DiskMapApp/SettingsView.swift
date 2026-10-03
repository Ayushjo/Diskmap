import DiskMapCore
import SwiftUI

/// DiskMap ▸ Settings… (⌘,). Small on purpose: a choice lives here only when
/// it changes what the numbers mean or what DiskMap does on its own.
struct SettingsView: View {
    @AppStorage("ShowMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage(CloneAccounting.key) private var cloneMode = CloneAccounting.defaultMode.rawValue
    @AppStorage(ScanModel.keepHistoryKey) private var keepHistory = true
    @AppStorage(TextSize.storageKey) private var textSize = TextSize.standard.rawValue

    var body: some View {
        Form {
            Section {
                Picker("APFS clones", selection: $cloneMode) {
                    Text("Count every copy").tag(SharingMode.off.rawValue)
                    Text("Count each clone family once").tag(SharingMode.refcount.rawValue)
                    Text("Also find edited clones").tag(SharingMode.full.rawValue)
                }
                Text(CloneAccounting.explanation(SharingMode(rawValue: cloneMode) ?? .off))
                    .font(DiskMapType.secondary)
                    .foregroundStyle(DiskMapTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Scanning")
            }
            Section {
                Toggle("Keep storage history", isOn: $keepHistory)
                Text("Notes a few hundred folder sizes per scan so DiskMap can say what grew — kept a year on this Mac, never sent anywhere.")
                    .font(DiskMapType.secondary)
                    .foregroundStyle(DiskMapTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("History")
            }
            UpdateSettingsSection()
            Section {
                Picker("Text size", selection: Binding(
                    get: { TextSize(rawValue: textSize) ?? .standard },
                    set: { DiskMapType.scale = $0.scale; textSize = $0.rawValue }
                )) {
                    ForEach(TextSize.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show in Menu Bar", isOn: $showMenuBarExtra)
            } header: {
                Text("General")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The clone-accounting choice (TASK-077), stored in user defaults.
enum CloneAccounting {
    static let key = "CloneAccounting"
    /// Off: reading clone facts made a home walk +14% (median) / +22% (p95)
    /// slower for refcount and ~1.9× for full (docs/perf-results/clone-scan-ab.txt)
    /// — over the 10% budget for a default.
    static let defaultMode: SharingMode = .off

    static var mode: SharingMode {
        if SnapshotHarness.isDeterministic { return defaultMode }
        return UserDefaults.standard.string(forKey: key).flatMap(SharingMode.init(rawValue:)) ?? defaultMode
    }

    static func explanation(_ mode: SharingMode) -> String {
        switch mode {
        case .off:
            return "Fastest, but a cloned copy (Finder, pnpm) is counted again for every copy, so totals can exceed what the disk uses."
        case .refcount:
            return "Clones count once so sizes match the disk; scans take about 15–20% longer, and the next one reads every folder."
        case .full:
            return "Also finds edited clones and lets Cleanup measure unchanged folders instantly; scans take nearly twice as long."
        }
    }
}
