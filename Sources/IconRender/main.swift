import AppKit
import SwiftUI
import DiskMapBrand

// IconRender (TASK-083) — draws freedisk.space's app icon in SwiftUI and writes an
// .iconset, so the icon is code, reviewable and regenerable.
//
//   swift run IconRender <variant 1|2|3|4> <out.iconset> one iconset (4 = Dusty peeking over the stack)
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

/// The cleared-stack mark. Its vector geometry matches DiskMapApp and the website SVG.
private struct Mark: View {
    var ink: Color
    var accent: Color

    var body: some View {
        ZStack {
            ClearedStackShape(segment: 0).fill(ink)
            ClearedStackShape(segment: 1).fill(hex(0x6D7782))
            ClearedStackShape(segment: 2).fill(accent)
            ClearedStackShape(segment: 3).fill(accent.opacity(0.5))
        }
        .aspectRatio(106.0 / 92.0, contentMode: .fit)
    }
}

private struct ClearedStackShape: Shape {
    let segment: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch segment {
        case 0:
            path.addRoundedRect(in: CGRect(x: 0, y: 0, width: 106, height: 22), cornerSize: CGSize(width: 11, height: 11))
        case 1:
            path.addRoundedRect(in: CGRect(x: 0, y: 35, width: 82, height: 22), cornerSize: CGSize(width: 11, height: 11))
        case 2:
            path.addRoundedRect(in: CGRect(x: 0, y: 70, width: 53, height: 22), cornerSize: CGSize(width: 11, height: 11))
        default:
            path.addRoundedRect(in: CGRect(x: 91, y: 44, width: 15, height: 4), cornerSize: CGSize(width: 2, height: 2))
            path.addRoundedRect(in: CGRect(x: 63, y: 79, width: 43, height: 4), cornerSize: CGSize(width: 2, height: 2))
        }
        let scale = min(rect.width / 106, rect.height / 92)
        let x = rect.minX + (rect.width - 106 * scale) / 2
        let y = rect.minY + (rect.height - 92 * scale) / 2
        return path
            .applying(CGAffineTransform(scaleX: scale, y: scale))
            .applying(CGAffineTransform(translationX: x, y: y))
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
                // Dusty peeking over the cleared stack on a quiet macOS tile.
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(LinearGradient(colors: [hex(0xFCFBF8), hex(0xEFEDE7)], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: max(1, size * 0.002))
                if let mark = DiskMapBrand.rasterizedPeekMark(pixelsTall: Int(size * 0.63)) {
                    Image(nsImage: mark)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size * 0.46, height: size * 0.63)
                } else {
                    Mark(ink: hex(0x252B31), accent: hex(0x7966DA))
                        .frame(width: size * 0.54, height: size * 0.47)
                }
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
