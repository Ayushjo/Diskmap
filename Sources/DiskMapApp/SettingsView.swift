import DiskMapCore
import SwiftUI

/// DiskMap ▸ Settings… (⌘,). Small on purpose: a choice lives here only when
/// it changes what the numbers mean or what DiskMap does on its own.
struct SettingsView: View {
    @AppStorage("ShowMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage(CloneAccounting.key) private var cloneMode = CloneAccounting.defaultMode.rawValue

    var body: some View {
        Form {
            Section {
                Picker("APFS clones", selection: $cloneMode) {
                    Text("Count every copy").tag(SharingMode.off.rawValue)
                    Text("Count each clone family once").tag(SharingMode.refcount.rawValue)
                    Text("Also find edited clones").tag(SharingMode.full.rawValue)
                }
                Text(CloneAccounting.explanation(SharingMode(rawValue: cloneMode) ?? .off))
                    .font(DiskMapType.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Scanning")
            }
            Section {
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
        UserDefaults.standard.string(forKey: key).flatMap(SharingMode.init(rawValue:)) ?? defaultMode
    }

    static func explanation(_ mode: SharingMode) -> String {
        switch mode {
        case .off:
            return "Fastest. A file copied with Finder or by tools like pnpm shares its blocks with the original, but is counted again for every copy — totals can be far above what the disk actually uses."
        case .refcount:
            return "Clones count once, so folder sizes match the disk. Scans take roughly 15–20% longer. The next scan reads every folder again."
        case .full:
            return "Also notices copies that were edited after cloning and still share some blocks (counted in full and reported), and lets Cleanup measure a folder that hasn’t changed since the scan instantly instead of reading it again. Scans take nearly twice as long."
        }
    }
}
