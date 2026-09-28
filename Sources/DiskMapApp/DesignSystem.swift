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

    /// Canvas background — calm off-white matching DiskMap1/2 mocks.
    static let cream = adaptive(light: (250, 250, 252), dark: (29, 29, 31))
    /// Near-black primary / active in light; near-white in dark.
    static let ink = adaptive(light: (28, 27, 23), dark: (236, 236, 240))
    /// Text and icons placed ON an `ink` fill (selected chips, toasts, the
    /// primary ink button). It was hardcoded white, which vanishes once `ink`
    /// turns light in dark mode.
    static let onInk = adaptive(light: (255, 255, 255), dark: (29, 29, 31))
    static let mutedLabel = adaptive(light: (110, 110, 115), dark: (158, 158, 166),
                                     highContrastLight: (72, 72, 78), highContrastDark: (198, 198, 206))
    static let cardFill = adaptive(light: (255, 255, 255), dark: (40, 40, 44))
    static let cardStroke = adaptive(light: (226, 226, 230), dark: (60, 60, 66),
                                     highContrastLight: (150, 150, 158), highContrastDark: (120, 120, 130))
    static let compressed = adaptive(light: (70, 140, 90), dark: (98, 184, 124))
    static let inspectorFill = adaptive(light: (248, 248, 250), dark: (35, 35, 38))
    /// The navigation rail shares the application canvas so the shell reads as one surface.
    static let sidebarFill = cream
    static let navSelected = adaptive(light: (232, 232, 237), dark: (58, 58, 64))
    static let hoverFill = adaptive(light: (242, 242, 245), dark: (48, 48, 53))
    static let inspectedFill = adaptive(light: (235, 239, 246), dark: (38, 48, 66))
    static let disabledLabel = adaptive(light: (118, 118, 124), dark: (118, 118, 126),
                                        highContrastLight: (92, 92, 98), highContrastDark: (150, 150, 158))
    static let focus = adaptive(light: (56, 110, 209), dark: (104, 152, 242))
    /// A deliberately dark banner surface in both appearances (Overview's
    /// "Explain my storage"); lifted in dark mode so it still reads as a card.
    static let inverseSurface = adaptive(light: (46, 46, 56), dark: (54, 56, 70))
    /// Text drawn on pastel data tiles. Fixed, because the tiles are.
    static let tileLabel = Color(red: 28 / 255, green: 27 / 255, blue: 23 / 255)

    /// A data tint made OPAQUE by compositing it over the light canvas
    /// (TASK-049). Charts used `color.opacity(x)` for depth fades and bubble
    /// containers; over a dark canvas translucency darkens the fill, so the
    /// fixed dark `tileLabel` lost contrast (bubble labels read dark-on-dark).
    /// Compositing against the fixed light canvas keeps tiles identical in
    /// both appearances.
    static func wash(_ color: Color, strength: Double) -> Color {
        let a = min(max(strength, 0), 1)
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return color.opacity(a) }
        let bg = (250.0 / 255, 250.0 / 255, 252.0 / 255)
        return Color(
            .sRGB,
            red: Double(c.redComponent) * a + bg.0 * (1 - a),
            green: Double(c.greenComponent) * a + bg.1 * (1 - a),
            blue: Double(c.blueComponent) * a + bg.2 * (1 - a),
            opacity: 1
        )
    }

    // Semantic — lifted slightly in dark mode to keep contrast on dark surfaces.
    static let info = adaptive(light: (51, 115, 242), dark: (96, 152, 255))
    static let safe = adaptive(light: (46, 158, 97), dark: (74, 192, 128))
    static let review = adaptive(light: (230, 158, 31), dark: (242, 178, 66))
    static let danger = adaptive(light: (219, 56, 56), dark: (242, 100, 100))
    static let developer = adaptive(light: (122, 89, 217), dark: (162, 136, 246))

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

    static let folderPastels: [Color] = [
        Color(red: 0.55, green: 0.45, blue: 0.85), // library purple
        Color(red: 0.92, green: 0.45, blue: 0.62), // downloads pink
        Color(red: 0.30, green: 0.55, blue: 0.95), // developer blue
        Color(red: 0.25, green: 0.72, blue: 0.48), // caches green
        Color(red: 0.95, green: 0.55, blue: 0.25), // apps orange
        Color(red: 0.45, green: 0.55, blue: 0.65), // documents slate
        Color(red: 0.70, green: 0.70, blue: 0.72), // other gray
        Color(red: 0.62, green: 0.80, blue: 0.78),
    ]

    /// The one colour per file kind (TASK-047). There were four copies of
    /// this switch — two identical in BiggestFilesView, a partial one in
    /// ForgottenFilesView, and a drifted one in FileBrowserView where documents
    /// were teal instead of gold. These are the Biggest Files values.
    static func kindColor(_ kind: FileKind) -> Color {
        switch kind {
        case .video: return Color(red: 0.55, green: 0.35, blue: 0.85)
        case .diskImage: return Color(red: 0.25, green: 0.45, blue: 0.90)
        case .archive: return Color(red: 0.92, green: 0.50, blue: 0.20)
        case .application: return Color(red: 0.20, green: 0.55, blue: 0.85)
        case .document: return Color(red: 0.85, green: 0.65, blue: 0.15)
        case .virtualDisk: return Color(red: 0.50, green: 0.35, blue: 0.80)
        case .deviceBackup: return Color(red: 0.20, green: 0.65, blue: 0.45)
        case .database: return Color(red: 0.40, green: 0.50, blue: 0.60)
        case .other: return DiskMapTheme.mutedLabel
        }
    }

    /// One ramp for file age, used by the Age Map screen and by Explore's
    /// "age" colouring (TASK-047). There were two copies with drifted
    /// saturation; these are the Age Map screen's values. Newest = green,
    /// oldest = deep red.
    static func ageColor(_ bucket: AgeBucket) -> Color {
        switch bucket {
        case .under30: return Color(hue: 0.42, saturation: 0.45, brightness: 0.72)
        case .days30to90: return Color(hue: 0.38, saturation: 0.5, brightness: 0.62)
        case .days90to365: return Color(hue: 0.12, saturation: 0.55, brightness: 0.78)
        case .oneToTwoYears: return Color(hue: 0.06, saturation: 0.65, brightness: 0.72)
        case .overTwoYears: return Color(hue: 0.02, saturation: 0.7, brightness: 0.55)
        case .unknown: return DiskMapTheme.mutedLabel.opacity(0.4)
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
        case "applications": return hex("C9A078")
        default: return hex(treemapFolderPalette[abs(index) % treemapFolderPalette.count])
        }
    }

    static let treemapFolderPalette = ["849BB8", "A795C7", "C78797", "7BA89C", "B9A071", "8FACC0", "A2A4AC"]

    /// Tinted panel backgrounds. Built from the semantic colour at low
    /// opacity so they sit correctly on either canvas — the hardcoded pale
    /// blue / warm cream fills they replace glared in dark mode.
    static var infoSurface: Color { info.opacity(0.08) }
    static var reviewSurface: Color { review.opacity(0.10) }

    /// Folders in lists (was an ad-hoc "link blue" repeated 8× in
    /// FileBrowserView, close to but not equal to `info`).
    static let folderTint = info

    static func categoryColor(_ hint: String) -> Color {
        switch hint {
        case "library": return folderPastels[0]
        case "downloads": return folderPastels[1]
        case "developer": return folderPastels[2]
        case "caches": return folderPastels[3]
        case "apps": return folderPastels[4]
        case "documents": return folderPastels[5]
        case "system": return Color(red: 0.45, green: 0.47, blue: 0.52)
        default: return folderPastels[6]
        }
    }
}

enum DiskMapSpace {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32

    /// Default page padding.
    static let page: CGFloat = 20
    /// Compact list row height target.
    static let rowMin: CGFloat = 44
}

/// "1 item" / "3 items", with the number in the user's locale.
func countLabel(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
    "\(count.formatted()) \(count == 1 ? singular : (plural ?? singular + "s"))"
}

enum DiskMapRadius {
    static let control: CGFloat = 8
    static let card: CGFloat = 12
}

enum DiskMapMetric {
    static let topBarHeight: CGFloat = 50
    static let sidebarWidth: CGFloat = 200
    static let controlHeight: CGFloat = 30
    static let searchHeight: CGFloat = 32
    static let tableHeaderHeight: CGFloat = 30
    static let statusBarHeight: CGFloat = 30
    static let checkboxColumnWidth: CGFloat = 24
    static let inspectorPadding: CGFloat = 18
}

/// The type scale (TASK-050). Every text size goes through `scale`, so a
/// future text-size preference changes one number instead of ~600 call
/// sites — before this, 86% of `.font` calls hand-set a point size and
/// bypassed the scale. Icon glyph sizes are not text and stay local.
enum DiskMapType {
    static let scale: CGFloat = 1

    private static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * scale, weight: weight)
    }

    static let micro = text(10)
    static let microStrong = text(10, .semibold)
    static let microMedium = text(10, .medium)
    static let caption = text(11)
    static let captionMedium = text(11, .medium)
    static let captionStrong = text(11, .semibold)
    /// 12 pt had no token, which is why it was the most hand-rolled size.
    static let small = text(12)
    static let smallMedium = text(12, .medium)
    static let smallStrong = text(12, .semibold)
    static let body = text(13)
    static let bodyMedium = text(13, .medium)
    static let bodyStrong = text(13, .semibold)
    static let callout = text(14, .semibold)
    static let section = text(15, .semibold)
    static let headline = text(16, .semibold)
    static let title = text(22, .semibold)
    static let heroNumber = text(28, .semibold).monospacedDigit()
}

struct SectionLabel: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(DiskMapTheme.mutedLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PanelCard<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: DiskMapRadius.card, style: .continuous)
                    .fill(DiskMapTheme.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: DiskMapRadius.card, style: .continuous)
                            .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                    )
            )
    }
}

struct StatRow: View {
    let label: String
    let value: String
    var emphasize: Bool = false
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(emphasize ? DiskMapTheme.safe : DiskMapTheme.mutedLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
                .fontWeight(emphasize ? .semibold : .regular)
                .foregroundStyle(emphasize ? DiskMapTheme.safe : DiskMapTheme.ink)
                .multilineTextAlignment(.trailing)
        }
        .font(.system(size: 12))
    }
}

struct ProportionBar: View {
    let fraction: Double
    var tint: Color = DiskMapTheme.ink.opacity(0.35)
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DiskMapTheme.cardStroke.opacity(0.5))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }
}

struct SegmentedStorageBar: View {
    let segments: [(color: Color, fraction: Double)]
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    let w = max(0, geo.size.width * min(1, max(0, seg.fraction)))
                    if w > 0.5 {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(seg.color)
                            .frame(width: w)
                    }
                }
            }
        }
        .frame(height: 9)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct InkButtonStyle: ButtonStyle {
    var filled: Bool = true
    var fullWidth: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, 14)
            .frame(height: DiskMapMetric.controlHeight)
            .foregroundStyle(filled ? DiskMapTheme.onInk : DiskMapTheme.ink)
            .background(
                RoundedRectangle(cornerRadius: DiskMapRadius.control, style: .continuous)
                    .fill(filled ? DiskMapTheme.ink.opacity(configuration.isPressed ? 0.85 : 1) : DiskMapTheme.navSelected)
            )
    }
}

struct PrimaryCTAStyle: ButtonStyle {
    var fullWidth: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, 16)
            .frame(height: DiskMapMetric.controlHeight)
            .foregroundStyle(Color.white)
            .background(
                // Fixed brand green: the lifted dark-mode `safe` would drop
                // white text to ~2.3:1 contrast.
                RoundedRectangle(cornerRadius: DiskMapRadius.control, style: .continuous)
                    .fill(Color(red: 46 / 255, green: 158 / 255, blue: 97 / 255).opacity(configuration.isPressed ? 0.85 : 1))
            )
    }
}
