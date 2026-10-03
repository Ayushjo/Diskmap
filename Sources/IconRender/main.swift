import AppKit
import SwiftUI

// IconRender (TASK-083) — draws DiskMap's app icon in SwiftUI and writes an
// .iconset, so the icon is code, reviewable and regenerable.
//
//   swift run IconRender <variant 1|2|3|4> <out.iconset> one iconset (4 = logo)
//   swift run IconRender --previews <dir>                1024 px PNG of each variant
// then: iconutil -c icns <out.iconset> -o Resources/AppIcon.icns

private func hex(_ value: UInt32) -> Color {
    Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
}
private let palette: [Color] = [0x849BB8, 0xA795C7, 0xC78797, 0x7BA89C, 0xB9A071].map(hex)

/// A small fixed treemap: the same proportions the app's charts produce.
private struct Tiles: View {
    var gap: CGFloat
    var radius: CGFloat
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let rects: [(CGRect, Int)] = [
                (CGRect(x: 0, y: 0, width: 0.56, height: 1), 0),
                (CGRect(x: 0.56, y: 0, width: 0.44, height: 0.55), 1),
                (CGRect(x: 0.56, y: 0.55, width: 0.24, height: 0.45), 2),
                (CGRect(x: 0.80, y: 0.55, width: 0.20, height: 0.25), 3),
                (CGRect(x: 0.80, y: 0.80, width: 0.20, height: 0.20), 4),
            ]
            ForEach(Array(rects.enumerated()), id: \.offset) { _, entry in
                let r = entry.0
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(palette[entry.1])
                    .frame(width: r.width * w - gap, height: r.height * h - gap)
                    .position(x: (r.midX) * w, y: (r.midY) * h)
            }
        }
    }
}

/// The logo's "D" (copy of DiskMapApp's DiskMapMark; keep the two in step).
private struct Mark: View {
    var ink: Color
    var accent: Color
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let u = w / 260
            let bowlX = w * 87 / 260, bowlW = w - bowlX
            let topH = h * 129 / 273, bottomY = h * 147 / 273, bottomH = h - bottomY
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8 * u, style: .continuous)
                    .fill(ink)
                    .frame(width: w * 69 / 260, height: h)
                UnevenRoundedRectangle(topLeadingRadius: 8 * u, bottomLeadingRadius: 30 * u,
                                       bottomTrailingRadius: 6 * u, topTrailingRadius: topH, style: .continuous)
                    .fill(accent)
                    .frame(width: bowlW, height: topH)
                    .offset(x: bowlX)
                UnevenRoundedRectangle(topLeadingRadius: 34 * u, bottomLeadingRadius: 8 * u,
                                       bottomTrailingRadius: bottomH, topTrailingRadius: 6 * u, style: .continuous)
                    .fill(ink)
                    .frame(width: bowlW, height: bottomH)
                    .offset(x: bowlX, y: bottomY)
            }
        }
        .aspectRatio(260.0 / 273.0, contentMode: .fit)
    }
}

private struct Icon: View {
    let variant: Int
    let size: CGFloat
    var body: some View {
        let corner = size * 0.225
        ZStack {
            switch variant {
            case 4:
                // The logo: paper tile, the "D" mark centred.
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(LinearGradient(colors: [hex(0xFCFBF8), hex(0xEFEDE7)], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: max(1, size * 0.002))
                Mark(ink: hex(0x2B2F35), accent: hex(0x8070F0))
                    .frame(height: size * 0.44)
                    .offset(x: size * 0.012)
            case 2:
                // Dark tile, treemap inset, small D badge.
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(LinearGradient(colors: [hex(0x2B2D33), hex(0x17181C)], startPoint: .top, endPoint: .bottom))
                Tiles(gap: size * 0.025, radius: size * 0.035)
                    .padding(size * 0.15)
            case 3:
                // Full-bleed treemap with a bold D.
                Tiles(gap: size * 0.02, radius: size * 0.03)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                Text("D")
                    .font(.system(size: size * 0.52, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.25), radius: size * 0.02, y: size * 0.01)
            default:
                // Cream tile, treemap, ink "D" chip in the corner.
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(LinearGradient(colors: [hex(0xFBF8F2), hex(0xEFE9DD)], startPoint: .top, endPoint: .bottom))
                Tiles(gap: size * 0.025, radius: size * 0.035)
                    .padding(size * 0.14)
            }
            if variant == 1 || variant == 2 {
                RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                    .fill(variant == 2 ? hex(0xFBF8F2) : hex(0x1D1E22))
                    .frame(width: size * 0.3, height: size * 0.3)
                    .overlay(Text("D")
                        .font(.system(size: size * 0.2, weight: .bold, design: .rounded))
                        .foregroundStyle(variant == 2 ? hex(0x1D1E22) : hex(0xFBF8F2)))
                    .position(x: size * 0.74, y: size * 0.74)
                    .shadow(color: .black.opacity(0.2), radius: size * 0.015, y: size * 0.008)
            }
        }
        // macOS icons sit inside a margin of the canvas (Big Sur grid: 824 of 1024).
        .frame(width: size * 0.805, height: size * 0.805)
        .frame(width: size, height: size)
    }
}

@MainActor
private func png(variant: Int, pixels: Int) -> Data? {
    let renderer = ImageRenderer(content: Icon(variant: variant, size: CGFloat(pixels)))
    renderer.scale = 1
    guard let image = renderer.cgImage else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

@MainActor
private func run() -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.first == "--previews", args.count == 2 {
        let dir = URL(fileURLWithPath: args[1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for variant in 1...4 {
            guard let data = png(variant: variant, pixels: 1024) else { return 1 }
            try? data.write(to: dir.appendingPathComponent("variant-\(variant).png"))
        }
        return 0
    }
    guard args.count == 2, let variant = Int(args[0]), (1...4).contains(variant) else {
        FileHandle.standardError.write(Data("usage: IconRender <1|2|3|4> <out.iconset> | --previews <dir>\n".utf8))
        return 2
    }
    let out = URL(fileURLWithPath: args[1], isDirectory: true)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            guard let data = png(variant: variant, pixels: points * scale) else { return 1 }
            do { try data.write(to: out.appendingPathComponent(name)) } catch { return 1 }
        }
    }
    return 0
}

exit(MainActor.assumeIsolated { run() })
