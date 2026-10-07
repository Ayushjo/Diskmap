import AppKit
import Foundation

/// Finds DiskMapBrand's bundled SVG — the same fix as `DiskMapResources` in
/// DiskMapCore (TASK-063).
///
/// SwiftPM's generated `Bundle.module` looks only at
/// `<main bundle>/DiskMap_DiskMapBrand.bundle` and then at the absolute build
/// path on the machine that compiled it, and traps when neither exists. In a
/// `.app` the resource bundle lives in `Contents/Resources`, so a packaged
/// app found the logo only on the Mac that built it and crashed everywhere
/// else the first time SwiftUI laid out the sidebar wordmark (a resize,
/// maximize or sidebar toggle). Look in the packaged places first;
/// `Bundle.module` stays the last resort for `swift run` and tests.
enum DiskMapBrandResources {
    static let bundleName = "DiskMap_DiskMapBrand.bundle"

    /// The packaged locations, in order: `Contents/Resources` in an app, then
    /// beside the executable (`swift run`).
    static func packagedBundle(resourceURL: URL?, bundleURL: URL) -> Bundle? {
        let candidates = [resourceURL?.appendingPathComponent(bundleName), bundleURL.appendingPathComponent(bundleName)]
        for case let url? in candidates {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return nil
    }

    static let bundle: Bundle = packagedBundle(resourceURL: Bundle.main.resourceURL, bundleURL: Bundle.main.bundleURL) ?? Bundle.module
}

/// The selected Dusty logo mark. The app and icon renderer load one vector asset.
public enum DiskMapBrand {
    public static let peekMark: NSImage? = {
        guard let url = DiskMapBrandResources.bundle.url(forResource: "dusty-peek-mark", withExtension: "svg") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    /// Resolve the SVG at the requested output size before SwiftUI composites
    /// it into a large icon. Otherwise ImageRenderer can enlarge the SVG's
    /// small intrinsic bitmap representation and soften the outline.
    public static func rasterizedPeekMark(pixelsTall: Int) -> NSImage? {
        guard let peekMark, pixelsTall > 0 else { return nil }
        let width = Int((CGFloat(pixelsTall) * 95 / 144).rounded(.up))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: pixelsTall,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        peekMark.draw(in: NSRect(x: 0, y: 0, width: width, height: pixelsTall),
                      from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: width, height: pixelsTall))
        image.addRepresentation(bitmap)
        return image
    }
}
