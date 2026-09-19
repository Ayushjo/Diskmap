import SwiftUI

enum DiskMapTheme {
    /// Canvas background — calm off-white matching DiskMap1/2 mocks.
    static let cream = Color(red: 250 / 255, green: 250 / 255, blue: 252 / 255)
    /// Near-black primary / active.
    static let ink = Color(red: 28 / 255, green: 27 / 255, blue: 23 / 255)
    static let mutedLabel = Color(red: 110 / 255, green: 110 / 255, blue: 115 / 255)
    static let cardFill = Color.white
    static let cardStroke = Color(red: 226 / 255, green: 226 / 255, blue: 230 / 255)
    static let compressed = Color(red: 70 / 255, green: 140 / 255, blue: 90 / 255)
    static let inspectorFill = Color(red: 248 / 255, green: 248 / 255, blue: 250 / 255)
    /// The navigation rail shares the application canvas so the shell reads as one surface.
    static let sidebarFill = cream
    static let navSelected = Color(red: 232 / 255, green: 232 / 255, blue: 237 / 255)
    static let hoverFill = Color(red: 242 / 255, green: 242 / 255, blue: 245 / 255)
    static let inspectedFill = Color(red: 235 / 255, green: 239 / 255, blue: 246 / 255)
    static let disabledLabel = Color(red: 118 / 255, green: 118 / 255, blue: 124 / 255)
    static let focus = Color(red: 0.22, green: 0.43, blue: 0.82)

    // Semantic
    static let info = Color(red: 0.20, green: 0.45, blue: 0.95)
    static let safe = Color(red: 0.18, green: 0.62, blue: 0.38)
    static let review = Color(red: 0.90, green: 0.62, blue: 0.12)
    static let danger = Color(red: 0.86, green: 0.22, blue: 0.22)
    static let developer = Color(red: 0.48, green: 0.35, blue: 0.85)

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

enum DiskMapType {
    static let title = Font.system(size: 22, weight: .semibold)
    static let section = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11)
    static let heroNumber = Font.system(size: 28, weight: .semibold).monospacedDigit()
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
            .foregroundStyle(filled ? Color.white : DiskMapTheme.ink)
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
                RoundedRectangle(cornerRadius: DiskMapRadius.control, style: .continuous)
                    .fill(DiskMapTheme.safe.opacity(configuration.isPressed ? 0.85 : 1))
            )
    }
}
