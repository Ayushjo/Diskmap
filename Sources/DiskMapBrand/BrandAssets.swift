import AppKit
import Foundation

/// The selected Dusty logo mark. The app and icon renderer load one vector asset.
public enum DiskMapBrand {
    public static let peekMark: NSImage? = {
        guard let url = Bundle.module.url(forResource: "dusty-peek-mark", withExtension: "svg") else {
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
