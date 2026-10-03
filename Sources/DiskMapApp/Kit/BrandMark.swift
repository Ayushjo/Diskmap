import SwiftUI

/// The DiskMap "D": a bar, a violet top bowl and an ink bottom bowl.
/// Drawn from the logo (docs/brand/diskmap-logo.png) as shapes so it stays
/// sharp at any size and follows the appearance. IconRender keeps a copy.
struct DiskMapMark: View {
    var ink: Color = DiskMapTheme.ink
    var accent: Color = DiskMapTheme.accent

    /// Width / height of the mark.
    static let aspect: CGFloat = 260.0 / 273.0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let u = w / 260 // logo units
            let bowlX = w * 87 / 260, bowlW = w - bowlX
            let topH = h * 129 / 273, bottomY = h * 147 / 273, bottomH = h - bottomY
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8 * u, style: .continuous)
                    .fill(ink)
                    .frame(width: w * 69 / 260, height: h)
                UnevenRoundedRectangle(topLeadingRadius: 8 * u, bottomLeadingRadius: 30 * u,
                                       bottomTrailingRadius: 6 * u, topTrailingRadius: topH,
                                       style: .continuous)
                    .fill(accent)
                    .frame(width: bowlW, height: topH)
                    .offset(x: bowlX)
                UnevenRoundedRectangle(topLeadingRadius: 34 * u, bottomLeadingRadius: 8 * u,
                                       bottomTrailingRadius: bottomH, topTrailingRadius: 6 * u,
                                       style: .continuous)
                    .fill(ink)
                    .frame(width: bowlW, height: bottomH)
                    .offset(x: bowlX, y: bottomY)
            }
        }
        .aspectRatio(Self.aspect, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// The logo's wordmark: the mark is the "D", followed by "iskMap".
struct DiskMapWordmark: View {
    /// Height of the mark (the cap height of the "D").
    var height: CGFloat = 16
    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: height * 0.1) {
            DiskMapMark()
                .frame(height: height)
                .alignmentGuide(.lastTextBaseline) { $0[.bottom] }
            Text("iskMap")
                .font(.system(size: height * 1.2, weight: .bold))
                .tracking(-0.01 * height)
                .foregroundStyle(DiskMapTheme.ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("DiskMap")
    }
}
