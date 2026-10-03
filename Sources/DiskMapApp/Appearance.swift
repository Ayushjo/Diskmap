import AppKit
import SwiftUI

/// System / Light / Dark, chosen in the top bar or View ▸ Appearance.
/// Applied app-wide through `NSApp.appearance`, so every window — and the
/// menu bar panel — follows, and the adaptive design tokens resolve for it.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "Appearance"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// Set by the snapshot harness so its `--appearance` render isn't undone.
    @MainActor static var harnessOverride = false

    @MainActor static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    @MainActor func apply() {
        guard !Self.harnessOverride else { return }
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Top bar: one icon that shows the current choice and offers the three.
struct AppearanceMenuButton: View {
    @AppStorage(AppAppearance.storageKey) private var raw = AppAppearance.system.rawValue

    private var choice: AppAppearance { AppAppearance(rawValue: raw) ?? .system }

    var body: some View {
        Menu {
            Picker("Appearance", selection: $raw) {
                ForEach(AppAppearance.allCases) { option in
                    Label(option.title, systemImage: option.symbol).tag(option.rawValue)
                }
            }
            .pickerStyle(.inline)
        } label: {
            // A label, not a bare image: VoiceOver read the symbol's name
            // ("circle.lefthalf.filled") as the button's title (TASK-078).
            Label("Appearance", systemImage: choice.symbol)
                .labelStyle(.iconOnly)
                .font(DiskMapType.smallMedium)
                .frame(width: 30, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Appearance: \(choice.title)")
        .accessibilityLabel("Appearance, \(choice.title)")
        .onChange(of: raw) { _, _ in choice.apply() }
    }
}

/// View ▸ Appearance.
struct AppearanceCommands: Commands {
    @AppStorage(AppAppearance.storageKey) private var raw = AppAppearance.system.rawValue
    @AppStorage(TextSize.storageKey) private var textSize = TextSize.standard.rawValue

    private var current: TextSize { TextSize(rawValue: textSize) ?? .standard }

    /// The scale first, then the stored value — whose change rebuilds the
    /// window (`.id`), so every token is read at the new size.
    private func setTextSize(_ size: TextSize) {
        DiskMapType.scale = size.scale
        textSize = size.rawValue
    }

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Picker("Appearance", selection: $raw) {
                ForEach(AppAppearance.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .onChange(of: raw) { _, value in (AppAppearance(rawValue: value) ?? .system).apply() }
            // TASK-085: DiskMap's own text size.
            Menu("Text Size") {
                Button("Bigger") { setTextSize(current.bigger) }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(current == .largest)
                Button("Smaller") { setTextSize(current.smaller) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(current == .smaller)
                Button("Default Size") { setTextSize(.standard) }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                ForEach(TextSize.allCases) { size in
                    Button((size == current ? "✓ " : "") + size.title) { setTextSize(size) }
                }
            }
        }
    }
}
