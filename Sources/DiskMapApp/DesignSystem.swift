import SwiftUI

enum DiskMapTheme {
    /// Warm cream from diskbuddy-*.png samples (250,245,236).
    static let cream = Color(red: 250 / 255, green: 245 / 255, blue: 236 / 255)
    /// Near-black primary / active (28,27,23).
    static let ink = Color(red: 28 / 255, green: 27 / 255, blue: 23 / 255)
    static let mutedLabel = Color(red: 90 / 255, green: 82 / 255, blue: 72 / 255)
    static let cardFill = Color(red: 255 / 255, green: 254 / 255, blue: 248 / 255)
    static let cardStroke = Color(red: 220 / 255, green: 214 / 255, blue: 204 / 255)
    static let compressed = Color(red: 70 / 255, green: 140 / 255, blue: 90 / 255)
    static let inspectorFill = Color(red: 237 / 255, green: 234 / 255, blue: 226 / 255)

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

    /// Soft pastels for top-level folder coloring (Library tan, Downloads pink, Documents green…).
    static let folderPastels: [Color] = [
        Color(red: 0.82, green: 0.72, blue: 0.55), // tan
        Color(red: 0.90, green: 0.70, blue: 0.75), // pink
        Color(red: 0.65, green: 0.78, blue: 0.62), // green
        Color(red: 0.70, green: 0.78, blue: 0.88), // blue
        Color(red: 0.85, green: 0.78, blue: 0.55), // gold
        Color(red: 0.75, green: 0.68, blue: 0.82), // lilac
        Color(red: 0.88, green: 0.74, blue: 0.62), // peach
        Color(red: 0.62, green: 0.80, blue: 0.78), // teal
    ]
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
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DiskMapTheme.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
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
                .foregroundStyle(emphasize ? DiskMapTheme.compressed : DiskMapTheme.mutedLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
                .fontWeight(emphasize ? .semibold : .regular)
                .foregroundStyle(emphasize ? DiskMapTheme.compressed : DiskMapTheme.ink)
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
        .frame(height: 4)
    }
}
