import Foundation
import Testing
@testable import DiskMapApp
@testable import DiskMapCore

/// TASK-058 — the app side of export: Copy Paths and File ▸ Export Scan….
@Suite("Export and Copy Paths")
struct ExportAndCopyTests {

    @Test func plainPathsAreLeftAlone() {
        #expect(shellQuoted("/Users/alex/Downloads/big-file_v2.dmg") == "/Users/alex/Downloads/big-file_v2.dmg")
    }

    /// What a terminal would do with the pasted text: run it through `sh`
    /// and check each argument comes back byte-for-byte.
    @Test func awkwardPathsSurviveAShell() throws {
        let paths = ["/tmp/My Movies/clip (1).mov", "/tmp/it's here", "/tmp/$HOME `x` \"q\"", "/tmp/ünï 🎬"]
        let script = "for a in " + paths.map(shellQuoted).joined(separator: " ") + "; do printf '%s\\n' \"$a\"; done"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(output.split(separator: "\n").map(String.init) == paths)
    }

    @Test func exportWritesTheWholeFileAndReportsItsSize() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("diskmap-appexport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 50_000).write(to: root.appendingPathComponent("a/x.bin"))
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("diskmap-export-\(UUID().uuidString).csv")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: out)
        }
        let tree = await ScanEngine().scan(root: root).tree
        let totals = tree.rollUpBoth()
        let result = ExportScan.write(tree: tree, root: root, allocated: totals.allocated, logical: totals.logical,
                                      format: .csv, to: out)
        let bytes = try result.get()
        let text = try String(contentsOf: out, encoding: .utf8)
        #expect(Int64(text.utf8.count) == bytes)
        #expect(text.split(separator: "\n").count == tree.count + 1)
        #expect(text.contains("/a/x.bin,file,"))
    }

    @Test func exportIntoAMissingFolderFailsCleanly() async throws {
        var tree = FileTree()
        _ = tree.addNode(name: "r", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        let out = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/scan.json")
        let result = ExportScan.write(tree: tree, root: URL(fileURLWithPath: "/r"), allocated: [0], logical: [0],
                                      format: .json, to: out)
        #expect((try? result.get()) == nil)
    }
}
