import AppKit
import DiskMapCore
import SwiftUI

/// Colour tokens. Surfaces, text and semantic colours resolve per appearance
/// (TASK-048) through an AppKit dynamic colour, so the whole app follows the
/// system's Light/Dark setting. The light values are the original ones,
/// unchanged. DATA colours (treemap/chart tiles, file-kind and age palettes)
/// deliberately do NOT adapt: tiles keep their identity in both appearances,
/// and text drawn on them uses the fixed `tileLabel`.
enum DiskMapTheme {
    /// sRGB 0–255 components for each appearance.
    /// Snapshot-harness override only: lets `--appearance hc-light/hc-dark`
    /// render the high-contrast values without changing the system setting.
    nonisolated(unsafe) static var forceIncreasedContrast = false

    /// With Increase Contrast on, the optional high-contrast values are used
    /// (only the low-contrast tokens define them: secondary text, disabled
    /// text, card borders). Read from the system setting: `bestMatch` does
    /// NOT return the high-contrast appearance names for an appearance object
    /// created in code (measured: it returns plain Aqua/DarkAqua), so matching
    /// on those names alone never fires.
    static func adaptive(
        light: (Double, Double, Double),
        dark: (Double, Double, Double),
        highContrastLight: (Double, Double, Double)? = nil,
        highContrastDark: (Double, Double, Double)? = nil
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let increased = forceIncreasedContrast || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let c: (Double, Double, Double)
            switch (isDark, increased) {
            case (true, true): c = highContrastDark ?? dark
            case (false, true): c = highContrastLight ?? light
            case (true, false): c = dark
            case (false, false): c = light
            }
            return NSColor(srgbRed: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: 1)
        })
    }

    // MARK: Surfaces and text — "calm" palette (Milestone 18)
    //
    // Light follows the launch site (design/website-motion-v1): warm paper,
    // ink, one violet. Dark is near-black with hairlines (designeer.xyz).
    // One surface for window, sidebar, page and inspector; `raised` only for
    // popovers, sheets and the rare card.

    /// The one surface: window, sidebar, page, inspector.
    static let canvas = adaptive(light: (248, 247, 244), dark: (11, 11, 12))
    /// Popovers, palette, sheets, the rare card.
    static let raised = adaptive(light: (255, 255, 255), dark: (20, 20, 22))
    /// Hairlines.
    static let line = adaptive(light: (228, 227, 223), dark: (38, 38, 42),
                               highContrastLight: (185, 184, 179), highContrastDark: (74, 74, 80))
    /// Primary text and the primary button.
    static let ink = adaptive(light: (37, 43, 49), dark: (242, 242, 243))
    /// Text and icons on an `ink` fill.
    static let onInk = adaptive(light: (255, 255, 255), dark: (11, 11, 12))
    /// Secondary text.
    static let ink2 = adaptive(light: (102, 113, 126), dark: (163, 163, 168),
                               highContrastLight: (64, 72, 82), highContrastDark: (205, 205, 210))
    /// Mono labels, tertiary text.
    static let ink3 = adaptive(light: (148, 154, 162), dark: (118, 118, 124),
                               highContrastLight: (98, 104, 112), highContrastDark: (170, 170, 176))
    /// The single accent: selection, focus, links, active chips.
    static let accent = adaptive(light: (121, 102, 218), dark: (154, 139, 240))
    /// Selected rows and active chips.
    static var accentSoft: Color { accent.opacity(0.11) }
    /// Row hover.
    static let hover = adaptive(light: (37, 43, 49), dark: (255, 255, 255)).opacity(0.045)

    // Older names, now mapped onto the calm palette so screens not yet
    // rebuilt follow it too. Removed once every page uses the kit.
    static let cream = canvas
    static let mutedLabel = ink2
    static let cardFill = raised
    static let cardStroke = line
    static let inspectorFill = canvas
    static let sidebarFill = canvas
    /// Neutral selection / secondary fill (sidebar, quiet buttons).
    static let navSelected = adaptive(light: (37, 43, 49), dark: (255, 255, 255)).opacity(0.065)
    static let disabledLabel = ink3
    /// Temporary: Overview's explain banner until the pilot removes it.
    static let focus = accent
    /// Text drawn on pastel data tiles. Fixed, because the tiles are.
    static let tileLabel = Color(red: 37 / 255, green: 43 / 255, blue: 49 / 255)

    /// A data tint made OPAQUE by compositing it over the light canvas
    /// (TASK-049), so tiles look the same in both appearances and keep the
    /// fixed dark `tileLabel` readable.
    static func wash(_ color: Color, strength: Double) -> Color {
        let a = min(max(strength, 0), 1)
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return color.opacity(a) }
        let bg = (248.0 / 255, 247.0 / 255, 244.0 / 255)
        return Color(
            .sRGB,
            red: Double(c.redComponent) * a + bg.0 * (1 - a),
            green: Double(c.greenComponent) * a + bg.1 * (1 - a),
            blue: Double(c.blueComponent) * a + bg.2 * (1 - a),
            opacity: 1
        )
    }

    // Semantic — safety only, shown as a dot and a word, never as a fill.
    static let safe = adaptive(light: (62, 142, 99), dark: (108, 196, 149))
    static let review = adaptive(light: (183, 121, 31), dark: (224, 165, 72))
    static let danger = adaptive(light: (194, 69, 61), dark: (238, 122, 112))
    /// Links and highlights: the accent (blue and purple were two more accents).
    static let info = accent
    static let developer = accent

    static func hex(_ hex: String) -> Color {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return .gray }
        return Color(
            red: Double((v >> 16) & 0xff) / 255,
            green: Double((v >> 8) & 0xff) / 255,
            blue: Double(v & 0xff) / 255
        )
    }

    /// The one data palette (launch site): slate, violet, rose, sage, sand,
    /// sky, stone. Charts, bars, categories and kinds all draw from it.
    static let dataPalette = ["849BB8", "A795C7", "C78797", "7BA89C", "B9A071", "8FACC0", "A2A4AC"]
    static func data(_ index: Int) -> Color { hex(dataPalette[abs(index) % dataPalette.count]) }

    static let folderPastels: [Color] = [
        hex("A795C7"), // library
        hex("C78797"), // downloads
        hex("849BB8"), // developer
        hex("7BA89C"), // caches
        hex("B9A071"), // apps
        hex("8FACC0"), // documents
        hex("A2A4AC"), // other
        hex("9FB5A9"),
    ]

    /// The one colour per file kind (TASK-047), from the data palette.
    static func kindColor(_ kind: FileKind) -> Color {
        switch kind {
        case .video: return hex("C78797")
        case .diskImage: return hex("849BB8")
        case .archive: return hex("B9A071")
        case .application: return hex("8FACC0")
        case .document: return hex("7BA89C")
        case .virtualDisk: return hex("A795C7")
        case .deviceBackup: return hex("9FB5A9")
        case .database: return hex("A2A4AC")
        case .other: return DiskMapTheme.ink3
        }
    }

    /// One ramp for file age (TASK-047): sage (new) through sand to rose (old).
    static func ageColor(_ bucket: AgeBucket) -> Color {
        switch bucket {
        case .under30: return hex("7BA89C")
        case .days30to90: return hex("8FACC0")
        case .days90to365: return hex("B9A071")
        case .oneToTwoYears: return hex("C99A7E")
        case .overTwoYears: return hex("C78797")
        case .unknown: return DiskMapTheme.ink3.opacity(0.5)
        }
    }

    /// Treemap/chart colour for a top-level folder (TASK-047: moved here from
    /// ExploreColoring, which kept its own hex palette apart from this file).
    /// Well-known folders get a fixed colour; the rest cycle by node index.
    static func treemapFolderColor(name: String, index: Int) -> Color {
        switch name.lowercased() {
        case "library": return hex("A795C7")
        case "downloads": return hex("C78797")
        case "desktop", "documents": return hex("849BB8")
        case "applications": return hex("B9A071")
        default: return hex(treemapFolderPalette[abs(index) % treemapFolderPalette.count])
        }
    }

    static let treemapFolderPalette = dataPalette

    /// Former tinted panel backgrounds — calm pages use no tinted boxes;
    /// screens not yet rebuilt get a barely-there wash.
    static var infoSurface: Color { ink.opacity(0.035) }
    static var reviewSurface: Color { ink.opacity(0.035) }

    /// Folder glyphs in lists: neutral, not an accent.
    static let folderTint = ink2

    static func categoryColor(_ hint: String) -> Color {
        switch hint {
        case "library": return folderPastels[0]
        case "downloads": return folderPastels[1]
        case "developer": return folderPastels[2]
        case "caches": return folderPastels[3]
        case "apps": return folderPastels[4]
        case "documents": return folderPastels[5]
        case "system": return hex("A2A4AC")
        default: return folderPastels[6]
        }
    }
}

enum DiskMapSpace {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48

    /// Page margins (calm pages: 32 sides, 28 top).
    static let page: CGFloat = 32
    static let pageTop: CGFloat = 28
    /// List row height (one line / two lines).
    static let row: CGFloat = 36
    static let rowTwoLine: CGFloat = 44
}

/// "1 item" / "3 items", with the number in the user's locale.
func countLabel(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
    "\(count.formatted()) \(count == 1 ? singular : (plural ?? singular + "s"))"
}

enum DiskMapRadius {
    /// Controls, chips, rows.
    static let control: CGFloat = 6
    /// Raised surfaces: popovers, sheets, the rare card.
    static let card: CGFloat = 10
}

enum DiskMapMetric {
    static let topBarHeight: CGFloat = 44
    /// Widens with the text size (TASK-085) so labels stay on one line.
    static var sidebarWidth: CGFloat { (212 * max(1, DiskMapType.scale)).rounded() }
    static let controlHeight: CGFloat = 28
    static let searchHeight: CGFloat = 30
    static let tableHeaderHeight: CGFloat = 28
    static let statusBarHeight: CGFloat = 30
    static let checkboxColumnWidth: CGFloat = 24
    static let inspectorPadding: CGFloat = 20
    static let inspectorWidth: CGFloat = 300
    /// Reading width for single-column pages (Overview).
    static let readingWidth: CGFloat = 880
}

/// The type scale (TASK-050). Every text size goes through `scale`, so a
/// future text-size preference changes one number instead of ~600 call
/// sites — before this, 86% of `.font` calls hand-set a point size and
/// bypassed the scale. Icon glyph sizes are not text and stay local.
/// Text size (TASK-085): one factor for every token, chosen in View ▸ Text
/// Size and stored in preferences. macOS has no Dynamic Type for arbitrary
/// apps, so this is DiskMap's own.
enum TextSize: String, CaseIterable, Identifiable {
    case smaller, standard, larger, largest
    var id: String { rawValue }
    static let storageKey = "TextSize"

    var scale: CGFloat {
        switch self {
        case .smaller: return 0.9
        case .standard: return 1.0
        case .larger: return 1.15
        case .largest: return 1.3
        }
    }

    var title: String {
        switch self {
        case .smaller: return "Smaller"
        case .standard: return "Default"
        case .larger: return "Larger"
        case .largest: return "Largest"
        }
    }

    static var stored: TextSize {
        if SnapshotHarness.isDeterministic { return .standard }
        return UserDefaults.standard.string(forKey: storageKey).flatMap(TextSize.init(rawValue:)) ?? .standard
    }

    var bigger: TextSize { Self.allCases.first { $0.scale > scale } ?? self }
    var smaller: TextSize { Self.allCases.last { $0.scale < scale } ?? self }
}

enum DiskMapType {
    /// Set from `TextSize` at launch and whenever it changes; the root view
    /// is rebuilt (`.id`) so every token is read again.
    nonisolated(unsafe) static var scale: CGFloat = TextSize.stored.scale

    /// A hand-set point size, scaled like the tokens.
    static func scaled(_ size: CGFloat) -> CGFloat { size * scale }

    private static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * scale, weight: weight)
    }

    private static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * scale, weight: weight, design: .monospaced)
    }

    // MARK: Calm scale (Milestone 18): names 13, secondary 12, figures and
    // labels in SF Mono, one title and one display figure per page.

    /// The one big figure on a page ("120 GB free").
    static var display: Font { text(28, .semibold).monospacedDigit() }
    /// Page title.
    static var title: Font { text(20, .semibold) }
    /// Section and inspector-name headings.
    static var heading: Font { text(15, .semibold) }
    static var body: Font { text(13) }
    /// Names in lists.
    static var bodyEmphasis: Font { text(13, .medium) }
    static var secondary: Font { text(12) }
    /// Sizes, counts, dates.
    static var figure: Font { mono(12) }
    static var figureStrong: Font { mono(12, .medium) }
    static var figureSmall: Font { mono(11) }
    /// Uppercase eyebrow and section labels (use `MonoLabel`).
    static var label: Font { mono(10, .medium) }

    // Older names, mapped onto the calm scale while pages migrate.
    static var micro: Font { text(10) }
    static var microStrong: Font { text(10, .semibold) }
    static var microMedium: Font { text(10, .medium) }
    static var caption: Font { text(11) }
    static var captionMedium: Font { text(11, .medium) }
    static var captionStrong: Font { text(11, .semibold) }
    static var small: Font { text(12) }
    static var smallMedium: Font { text(12, .medium) }
    static var smallStrong: Font { text(12, .semibold) }
    static var bodyMedium: Font { text(13, .medium) }
    static var bodyStrong: Font { text(13, .semibold) }
    static var callout: Font { text(13, .semibold) }
    static var section: Font { text(15, .semibold) }
    static var headline: Font { text(15, .semibold) }
    static var heroNumber: Font { display }
}

/// Uppercase mono label — section labels, eyebrows, column headers.
struct SectionLabel: View {
    let title: String
    var body: some View {
        MonoLabel(title)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A rare card: hairline on `raised`. Calm pages prefer hairlines and space.
struct PanelCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: DiskMapRadius.card, style: .continuous)
                    .fill(DiskMapTheme.raised)
                    .overlay(
                        RoundedRectangle(cornerRadius: DiskMapRadius.card, style: .continuous)
                            .stroke(DiskMapTheme.line, lineWidth: 1)
                    )
            )
    }
}

/// Label / value row (inspectors). Value in mono.
struct StatRow: View {
    let label: String
    let value: String
    var emphasize: Bool = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(DiskMapType.secondary)
                .foregroundStyle(DiskMapTheme.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
                .font(emphasize ? DiskMapType.figureStrong : DiskMapType.figure)
                .foregroundStyle(DiskMapTheme.ink)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// A thin proportion bar on a hairline track.
struct ProportionBar: View {
    let fraction: Double
    var tint: Color = DiskMapTheme.ink.opacity(0.32)
    var height: CGFloat = 3
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DiskMapTheme.line)
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }
}

/// One stacked bar; the list under it is its legend.
struct SegmentedStorageBar: View {
    let segments: [(color: Color, fraction: Double)]
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    let w = max(0, geo.size.width * min(1, max(0, seg.fraction)))
                    if w > 0.5 {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(seg.color)
                            .frame(width: w)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

// MARK: - Buttons (one primary per screen)

/// Filled ink — the one primary action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    var fullWidth: Bool = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DiskMapType.bodyEmphasis)
            .lineLimit(1)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, 12)
            .frame(height: DiskMapMetric.controlHeight)
            .foregroundStyle(DiskMapTheme.onInk)
            .background(
                RoundedRectangle(cornerRadius: DiskMapRadius.control, style: .continuous)
                    .fill(DiskMapTheme.ink.opacity(!isEnabled ? 0.3 : configuration.isPressed ? 0.82 : 1))
            )
            .contentShape(Rectangle())
    }
}

/// Hairline outline — a secondary action that still needs a label.
struct SecondaryButtonStyle: ButtonStyle {
    var fullWidth: Bool = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DiskMapType.bodyEmphasis)
            .lineLimit(1)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, 12)
            .frame(height: DiskMapMetric.controlHeight)
            .foregroundStyle(DiskMapTheme.ink.opacity(isEnabled ? 1 : 0.35))
            .background(
                RoundedRectangle(cornerRadius: DiskMapRadius.control, style: .continuous)
                    .fill(configuration.isPressed ? DiskMapTheme.navSelected : DiskMapTheme.raised.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: DiskMapRadius.control, style: .continuous)
                            .stroke(DiskMapTheme.line, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
    }
}

/// Text only, with a hover / press fill.
struct QuietButtonStyle: ButtonStyle {
    var tint: Color = DiskMapTheme.ink2
    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration, tint: tint)
    }

    private struct QuietButtonBody: View {
        let configuration: Configuration
        let tint: Color
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .font(DiskMapType.bodyEmphasis)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: DiskMapMetric.controlHeight)
                .foregroundStyle(hovering ? DiskMapTheme.ink : tint)
                .opacity(isEnabled ? 1 : 0.4)
                .background(
                    RoundedRectangle(cornerRadius: DiskMapRadius.control, style: .continuous)
                        .fill(configuration.isPressed ? DiskMapTheme.navSelected : hovering ? DiskMapTheme.hover : .clear)
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// A 28 pt square icon button (row hover actions, inspector secondary actions).
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size)
    }

    private struct IconButtonBody: View {
        let configuration: Configuration
        let size: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .font(.system(size: DiskMapType.scaled(12.5), weight: .medium))
                .labelStyle(.iconOnly)
                .frame(width: size, height: size)
                .foregroundStyle(hovering ? DiskMapTheme.ink : DiskMapTheme.ink2)
                .opacity(isEnabled ? 1 : 0.35)
                .background(
                    RoundedRectangle(cornerRadius: DiskMapRadius.control, style: .continuous)
                        .fill(configuration.isPressed ? DiskMapTheme.navSelected : hovering ? DiskMapTheme.hover : .clear)
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// Violet text link.
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DiskMapType.bodyEmphasis)
            .foregroundStyle(DiskMapTheme.accent.opacity(configuration.isPressed ? 0.7 : 1))
            .contentShape(Rectangle())
    }
}

/// Former names: `filled` is the primary, unfilled the secondary.
struct InkButtonStyle: ButtonStyle {
    var filled: Bool = true
    var fullWidth: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        if filled {
            PrimaryButtonStyle(fullWidth: fullWidth).makeBody(configuration: configuration)
        } else {
            SecondaryButtonStyle(fullWidth: fullWidth).makeBody(configuration: configuration)
        }
    }
}

/// Former green CTA: now the ink primary everywhere.
struct PrimaryCTAStyle: ButtonStyle {
    var fullWidth: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonStyle(fullWidth: fullWidth).makeBody(configuration: configuration)
    }
}
