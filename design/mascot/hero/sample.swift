import AppKit
let path = CommandLine.arguments[1]
guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let rep = NSBitmapImageRep(data: data) else { exit(1) }
func hex(_ x: Double, _ y: Double) -> String {   // points -> 2x pixels
    guard let c = rep.colorAt(x: Int(x * 2), y: Int(y * 2))?.usingColorSpace(.sRGB) else { return "?" }
    return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
}
var i = 2
while i < CommandLine.arguments.count {
    let p = CommandLine.arguments[i].split(separator: ",").map { Double($0)! }
    print(CommandLine.arguments[i], hex(p[0], p[1]))
    i += 1
}
