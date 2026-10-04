import AppKit
import SwiftUI

// Renders every scene of the promo as two 3840×2160 layers:
//   <id>-bg.png   background + framed app window (or card art)
//   <id>-fg.png   text, transparent, animated separately in ffmpeg

let shots = CommandLine.arguments[1]
let out = CommandLine.arguments[2]
let W: CGFloat = 3840, H: CGFloat = 2160

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Color {
    Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
}

struct Theme {
    let canvas, raised, line, ink, ink2, ink3, accent, chrome: Color
    let glow: Double, shadow: Double
    static let light = Theme(canvas: rgb(248, 247, 244), raised: rgb(255, 255, 255), line: rgb(228, 227, 223),
                             ink: rgb(37, 43, 49), ink2: rgb(102, 113, 126), ink3: rgb(148, 154, 162),
                             accent: rgb(121, 102, 218), chrome: rgb(255, 255, 255), glow: 0.14, shadow: 0.18)
    static let dark = Theme(canvas: rgb(11, 11, 12), raised: rgb(20, 20, 22), line: rgb(44, 44, 48),
                            ink: rgb(242, 242, 243), ink2: rgb(163, 163, 168), ink3: rgb(118, 118, 124),
                            accent: rgb(154, 139, 240), chrome: rgb(28, 28, 30), glow: 0.22, shadow: 0.55)
}

// The freedisk.space "cleared stack" mark (Sources/DiskMapApp/Kit/BrandMark.swift).
struct Mark: View {
    let t: Theme
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width / 106, size.height / 92)
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ rad: CGFloat, _ c: Color) {
                ctx.fill(Path(roundedRect: CGRect(x: x * s, y: y * s, width: w * s, height: h * s), cornerRadius: rad * s), with: .color(c))
            }
            r(0, 0, 106, 22, 11, t.ink)
            r(0, 35, 82, 22, 11, rgb(109, 119, 130))
            r(0, 70, 53, 22, 11, t.accent)
            r(91, 44, 15, 4, 2, t.accent.opacity(0.5))
            r(63, 79, 43, 4, 2, t.accent.opacity(0.5))
        }
        .aspectRatio(106 / 92, contentMode: .fit)
    }
}

struct Wordmark: View {
    let t: Theme
    var size: CGFloat
    var body: some View {
        HStack(alignment: .center, spacing: size * 0.32) {
            Mark(t: t).frame(width: size * 1.15, height: size)
            (Text("freedisk").foregroundColor(t.ink) + Text(".space").foregroundColor(t.accent))
                .font(.system(size: size * 1.15, weight: .bold))
                .tracking(-0.02 * size)
        }
    }
}

struct Backdrop: View {
    let t: Theme
    var body: some View {
        ZStack {
            t.canvas
            RadialGradient(colors: [t.accent.opacity(t.glow), .clear], center: UnitPoint(x: 0.88, y: 0.05),
                           startRadius: 0, endRadius: 1900)
            RadialGradient(colors: [t.accent.opacity(t.glow * 0.45), .clear], center: UnitPoint(x: 0.05, y: 1.0),
                           startRadius: 0, endRadius: 1500)
        }
        .frame(width: W, height: H)
    }
}

/// A macOS window around a screenshot (already cropped, see `cropped`).
struct AppWindow: View {
    let t: Theme
    let image: NSImage
    var crop: CGRect? = nil      // in screenshot pixels
    var width: CGFloat
    var sheet: NSImage? = nil    // drawn over a dimmed window, like a real sheet
    var body: some View {
        let shown = crop.map { cropped(image, $0) } ?? image
        let height = width * shown.size.height / shown.size.width
        VStack(spacing: 0) {
            ZStack {
                t.chrome
                HStack(spacing: 22) {
                    Circle().fill(rgb(255, 95, 87)).frame(width: 26, height: 26)
                    Circle().fill(rgb(254, 188, 46)).frame(width: 26, height: 26)
                    Circle().fill(rgb(40, 200, 64)).frame(width: 26, height: 26)
                    Spacer()
                }
                .padding(.leading, 34)
                Text("freedisk.space").font(.system(size: 30, weight: .semibold)).foregroundColor(t.ink2)
            }
            .frame(width: width, height: 84)
            Rectangle().fill(t.line).frame(width: width, height: 2)
            ZStack(alignment: .top) {
                Image(nsImage: shown)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: width, height: height)
                if let sheet {
                    Color.black.opacity(0.32)
                    let sw = width * sheet.size.width / shown.size.width * 1.25
                    Image(nsImage: sheet).resizable().interpolation(.high)
                        .frame(width: sw, height: sw * sheet.size.height / sheet.size.width)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(t.line, lineWidth: 2))
                        .shadow(color: .black.opacity(0.45), radius: 70, y: 30)
                        .padding(.top, 60)
                }
            }
            .frame(width: width, height: height)
        }
        .background(t.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).stroke(t.line, lineWidth: 2))
        .shadow(color: .black.opacity(t.shadow), radius: 90, y: 50)
    }
}

func cropped(_ image: NSImage, _ rect: CGRect) -> NSImage {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let part = cg.cropping(to: rect) else { return image }
    return NSImage(cgImage: part, size: NSSize(width: part.width, height: part.height))
}

struct Headline: View {
    let t: Theme
    let eyebrow: String, title: String, sub: String?
    var align: HorizontalAlignment = .leading
    var titleSize: CGFloat = 118
    var body: some View {
        VStack(alignment: align, spacing: 26) {
            Text(eyebrow.uppercased())
                .font(.system(size: 30, weight: .medium, design: .monospaced))
                .tracking(3)
                .foregroundColor(t.accent)
            Text(title)
                .font(.system(size: titleSize, weight: .semibold))
                .tracking(-0.025 * titleSize)
                .foregroundColor(t.ink)
                .multilineTextAlignment(align == .center ? .center : .leading)
            if let sub {
                Text(sub)
                    .font(.system(size: 48, weight: .regular))
                    .foregroundColor(t.ink2)
                    .multilineTextAlignment(align == .center ? .center : .leading)
                    .lineSpacing(10)
            }
        }
    }
}

@MainActor
func save<V: View>(_ view: V, _ name: String, opaque: Bool) {
    let r = ImageRenderer(content: view.frame(width: W, height: H).environment(\.colorScheme, .light))
    r.scale = 1
    r.isOpaque = opaque
    guard let cg = r.cgImage else { print("render failed \(name)"); return }
    let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    print("wrote \(name)")
}

func img(_ path: String) -> NSImage {
    guard let i = NSImage(contentsOfFile: "\(shots)/\(path)") else { fatalError("missing \(path)") }
    // Use pixel size so crops are in screenshot pixels.
    if let rep = i.representations.first { i.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh) }
    return i
}

struct Feature {
    let id: String, dark: Bool, shot: String
    var crop: CGRect? = nil
    var sheet: String? = nil
    let eyebrow: String, title: String, sub: String?
}

let features: [Feature] = [
    Feature(id: "02-first", dark: false, shot: "first-light/overview-light.png",
            eyebrow: "01 · Start", title: "Scan your whole Mac.", sub: "One click. Local, fast and private."),
    Feature(id: "04-overview", dark: false, shot: "overview-light.png", crop: CGRect(x: 360, y: 272, width: 930, height: 604),
            eyebrow: "02 · Overview", title: "Know where every gigabyte went.", sub: "Free space, what's using it, and what's worth a look."),
    Feature(id: "05-treemap", dark: true, shot: "visualize-dark.png",
            eyebrow: "03 · Visualize", title: "See your disk as a map.", sub: "Every folder sized by the space it takes. Click to dive in."),
    Feature(id: "06-sunburst", dark: false, shot: "mode-Sunburst-light.png",
            eyebrow: "03 · Visualize", title: "Six ways to look at it.", sub: "Treemap, sunburst, flame, bubbles, mind map, age map."),
    Feature(id: "07-find", dark: true, shot: "find-dark/find-dark.png",
            eyebrow: "04 · Find", title: "Find anything, instantly.", sub: "Plain words, or a query like  kind:video size>5GB"),
    Feature(id: "08-biggest", dark: false, shot: "biggestFiles-light.png",
            eyebrow: "05 · Biggest files", title: "Your biggest files, ranked.", sub: "Filter by kind, folder or age — and see why each one is large."),
    Feature(id: "09-duplicates", dark: true, shot: "dup-dark/duplicates-dark.png",
            eyebrow: "06 · Duplicates", title: "Catch every duplicate.", sub: "Byte-for-byte identical files — and APFS clones that share space."),
    Feature(id: "10-developer", dark: false, shot: "developerStorage-light.png",
            eyebrow: "07 · Developer storage", title: "Reclaim developer clutter.", sub: "node_modules, DerivedData, simulators, Docker — and what each costs to rebuild."),
    Feature(id: "11-media", dark: true, shot: "cleanMedia-dark.png",
            eyebrow: "08 · Large media", title: "Spot the huge videos.", sub: "Films, footage and photo libraries, largest first."),
    Feature(id: "12-safe", dark: false, shot: "cleanSafe-light.png",
            eyebrow: "09 · Clean", title: "Clean up with confidence.", sub: "Every item explained. What's safe is marked as safe."),
    Feature(id: "13-cleanup", dark: true, shot: "sheet-dark/overview-dark.png", sheet: "sheet-dark/cleanup-dark.png",
            eyebrow: "10 · Cleanup", title: "Nothing is deleted behind your back.", sub: "Review, move to the Trash — and Put Back if you change your mind."),
    Feature(id: "14-palette", dark: false, shot: "pal-light/palette-light.png",
            eyebrow: "11 · Command palette", title: "Everything is ⌘K away.", sub: nil),
]

@MainActor
func renderAll() {
    for f in features {
        let t = f.dark ? Theme.dark : Theme.light
        let image = img(f.shot)
        let winW: CGFloat = f.crop == nil ? 2900 : 2500
        save(ZStack(alignment: .topLeading) {
            Backdrop(t: t)
            AppWindow(t: t, image: image, crop: f.crop, width: winW, sheet: f.sheet.map(img))
                .offset(x: (W - winW) / 2, y: 590)
        }.frame(width: W, height: H, alignment: .topLeading).clipped(), "\(f.id)-bg", opaque: true)
        save(ZStack(alignment: .topLeading) {
            Color.clear
            Headline(t: t, eyebrow: f.eyebrow, title: f.title, sub: f.sub, align: .center, titleSize: 108)
                .frame(width: W)
                .offset(y: 130)
        }.frame(width: W, height: H, alignment: .topLeading), "\(f.id)-fg", opaque: false)
    }

    // Title card
    let d = Theme.dark, l = Theme.light
    save(Backdrop(t: d), "01-title-bg", opaque: true)
    save(VStack(spacing: 70) {
        Wordmark(t: d, size: 190)
        Text("See where your space went.")
            .font(.system(size: 64, weight: .regular)).foregroundColor(d.ink2)
    }.frame(width: W, height: H), "01-title-fg", opaque: false)

    // Speed stat
    save(Backdrop(t: d), "03-speed-bg", opaque: true)
    save(VStack(spacing: 40) {
        Text("FAST").font(.system(size: 32, weight: .medium, design: .monospaced)).tracking(4).foregroundColor(d.accent)
        Text("2.25 million files").font(.system(size: 210, weight: .semibold)).tracking(-5).foregroundColor(d.ink)
        Text("scanned in 8 seconds").font(.system(size: 120, weight: .regular, design: .monospaced)).foregroundColor(d.ink2)
        Text("A real home folder · median of 20 runs")
            .font(.system(size: 36, weight: .regular, design: .monospaced)).foregroundColor(d.ink3).padding(.top, 30)
    }.frame(width: W, height: H), "03-speed-fg", opaque: false)

    // Light / dark split
    let lightImg = img("visualize-light.png"), darkImg = img("visualize-dark.png")
    save(ZStack(alignment: .topLeading) {
        HStack(spacing: 0) { l.canvas.frame(width: W / 2); d.canvas.frame(width: W / 2) }
        RadialGradient(colors: [l.accent.opacity(0.16), .clear], center: .top, startRadius: 0, endRadius: 1800)
        AppWindow(t: l, image: lightImg, width: 2300).offset(x: 180, y: 700)
        AppWindow(t: d, image: darkImg, width: 2300).offset(x: W - 2300 - 180, y: 860)
    }.frame(width: W, height: H, alignment: .topLeading).clipped(), "15-themes-bg", opaque: true)
    save(ZStack(alignment: .top) {
        Color.clear
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("Light. ").foregroundColor(l.ink)
            Text("Dark. ").foregroundColor(l.ink)
            Text("Your call.").foregroundColor(l.accent)
        }
        .font(.system(size: 132, weight: .semibold)).tracking(-3)
        .padding(.horizontal, 70).padding(.vertical, 34)
        .background(RoundedRectangle(cornerRadius: 44, style: .continuous).fill(l.raised.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 44, style: .continuous).stroke(l.line, lineWidth: 2))
        .shadow(color: .black.opacity(0.18), radius: 60, y: 24)
        .offset(y: 230)
    }.frame(width: W, height: H), "15-themes-fg", opaque: false)

    // Rescan stat
    save(Backdrop(t: l), "16-rescan-bg", opaque: true)
    save(VStack(spacing: 40) {
        Text("ALWAYS CURRENT").font(.system(size: 32, weight: .medium, design: .monospaced)).tracking(4).foregroundColor(l.accent)
        Text("Rescans in 0.25 s").font(.system(size: 200, weight: .semibold)).tracking(-5).foregroundColor(l.ink)
        Text("It re-reads only what changed since the last scan.")
            .font(.system(size: 64, weight: .regular)).foregroundColor(l.ink2)
    }.frame(width: W, height: H), "16-rescan-fg", opaque: false)

    // Privacy
    save(Backdrop(t: d), "17-private-bg", opaque: true)
    save(VStack(spacing: 46) {
        Image(systemName: "lock.fill").font(.system(size: 130, weight: .regular)).foregroundColor(d.accent)
        Text("100% on your Mac.").font(.system(size: 190, weight: .semibold)).tracking(-5).foregroundColor(d.ink)
        Text("No accounts. No uploads. No tracking.")
            .font(.system(size: 72, weight: .regular)).foregroundColor(d.ink2)
    }.frame(width: W, height: H), "17-private-fg", opaque: false)

    // Outro
    save(Backdrop(t: l), "18-outro-bg", opaque: true)
    save(VStack(spacing: 64) {
        Wordmark(t: l, size: 200)
        Text("Free up your Mac — calmly.")
            .font(.system(size: 72, weight: .regular)).foregroundColor(l.ink2)
        Text("freedisk.space").font(.system(size: 54, weight: .medium, design: .monospaced))
            .foregroundColor(l.accent)
            .padding(.horizontal, 44).padding(.vertical, 20)
            .background(Capsule().fill(l.accent.opacity(0.10)))
    }.frame(width: W, height: H), "18-outro-fg", opaque: false)
}

MainActor.assumeIsolated { renderAll() }
