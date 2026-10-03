import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// ImageDiff — visual regression check (TASK-084).
//
//   ImageDiff <baseline-dir> <candidate-dir> [<diff-dir>] [--tolerance 8] [--max-percent 0.5]
//
// Compares every PNG in the baseline with the same name in the candidate,
// pixel by pixel. A pixel differs when any channel is off by more than
// `tolerance` (0–255). A file fails when more than `max-percent` of its
// pixels differ, or its size changed, or it is missing. Diff images (changed
// pixels in red over a faded copy) go to <diff-dir>. Exit 0 when all pass.

var positional: [String] = []
var tolerance = 8
var maxPercent = 0.5
var rest = Array(CommandLine.arguments.dropFirst())
while !rest.isEmpty {
    let token = rest.removeFirst()
    switch token {
    case "--tolerance": tolerance = Int(rest.first ?? "") ?? tolerance; if !rest.isEmpty { rest.removeFirst() }
    case "--max-percent": maxPercent = Double(rest.first ?? "") ?? maxPercent; if !rest.isEmpty { rest.removeFirst() }
    default: positional.append(token)
    }
}
guard positional.count >= 2 else {
    FileHandle.standardError.write(Data("usage: ImageDiff <baseline-dir> <candidate-dir> [<diff-dir>] [--tolerance 8] [--max-percent 0.5]\n".utf8))
    exit(2)
}
let baselineDir = URL(fileURLWithPath: positional[0])
let candidateDir = URL(fileURLWithPath: positional[1])
let diffDir = positional.count > 2 ? URL(fileURLWithPath: positional[2]) : nil

struct Bitmap {
    var width: Int
    var height: Int
    var pixels: [UInt8]   // RGBA8
}

func load(_ url: URL) -> Bitmap? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
        guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return drawn ? Bitmap(width: width, height: height, pixels: pixels) : nil
}

func save(_ bitmap: Bitmap, to url: URL) {
    var pixels = bitmap.pixels
    pixels.withUnsafeMutableBytes { raw in
        guard let context = CGContext(data: raw.baseAddress, width: bitmap.width, height: bitmap.height, bitsPerComponent: 8,
                                      bytesPerRow: bitmap.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

let names = ((try? FileManager.default.contentsOfDirectory(atPath: baselineDir.path)) ?? [])
    .filter { $0.hasSuffix(".png") }.sorted()
guard !names.isEmpty else {
    FileHandle.standardError.write(Data("no baseline PNGs in \(baselineDir.path)\n".utf8))
    exit(2)
}
if let diffDir { try? FileManager.default.createDirectory(at: diffDir, withIntermediateDirectories: true) }

var failures = 0
for name in names {
    guard let base = load(baselineDir.appendingPathComponent(name)) else { print("FAIL \(name): baseline unreadable"); failures += 1; continue }
    guard let candidate = load(candidateDir.appendingPathComponent(name)) else { print("FAIL \(name): missing"); failures += 1; continue }
    guard base.width == candidate.width, base.height == candidate.height else {
        print("FAIL \(name): size \(candidate.width)×\(candidate.height), baseline \(base.width)×\(base.height)")
        failures += 1
        continue
    }
    var changed = 0
    var diff = base
    for index in stride(from: 0, to: base.pixels.count, by: 4) {
        var off = false
        for channel in 0..<3 where abs(Int(base.pixels[index + channel]) - Int(candidate.pixels[index + channel])) > tolerance {
            off = true
        }
        if off {
            changed += 1
            diff.pixels[index] = 255; diff.pixels[index + 1] = 0; diff.pixels[index + 2] = 0; diff.pixels[index + 3] = 255
        } else {
            for channel in 0..<3 { diff.pixels[index + channel] = UInt8(155 + Int(base.pixels[index + channel]) * 100 / 255) }
        }
    }
    let percent = Double(changed) * 100 / Double(base.width * base.height)
    let passed = percent <= maxPercent
    print(String(format: "%@ %@: %.3f%% of pixels differ", passed ? "ok  " : "FAIL", name, percent))
    if !passed {
        failures += 1
        if let diffDir { save(diff, to: diffDir.appendingPathComponent(name.replacingOccurrences(of: ".png", with: "-diff.png"))) }
    }
}
print("\(names.count - failures) of \(names.count) match")
exit(failures == 0 ? 0 : 1)
