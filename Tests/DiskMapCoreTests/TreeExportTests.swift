import Foundation
import Testing
@testable import DiskMapCore

/// TASK-057/058 — exports and the CLI's unit parsing.
@Suite("Tree export")
struct TreeExportTests {

    private func scanned() async throws -> (FileTree, URL, (logical: [Int64], allocated: [Int64])) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("diskmap-export-\(UUID().uuidString)")
        for (rel, bytes) in [("big/movie.mov", 300_000), ("big/deep/er/clip.mp4", 120_000), ("small/a,b \"q\".txt", 100), ("readme.md", 2_000)] {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 3, count: bytes).write(to: url)
        }
        let tree = await ScanEngine().scan(root: root).tree
        return (tree, root, tree.rollUpBoth())
    }

    private func render(_ tree: FileTree, _ root: URL, _ totals: (logical: [Int64], allocated: [Int64]),
                        _ format: ExportFormat, _ options: ExportOptions = ExportOptions()) -> String {
        var text = ""
        TreeExporter.export(tree: tree, root: root, allocated: totals.allocated, logical: totals.logical,
                            format: format, options: options) { text += $0 }
        return text
    }

    @Test func ndjsonHasOneParseableRowPerNode() async throws {
        let (tree, root, totals) = try await scanned()
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = render(tree, root, totals, .ndjson).split(separator: "\n")
        #expect(lines.count == tree.count)
        let rows = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        #expect(rows.first??["path"] as? String == root.path)
        #expect(rows.contains { ($0?["path"] as? String)?.hasSuffix("a,b \"q\".txt") == true }, "quotes survive JSON escaping")
        // Largest first, depth-first: the big folder's subtree comes before "small".
        let order = rows.compactMap { ($0?["path"] as? String).map { ($0 as NSString).lastPathComponent } }
        #expect((order.firstIndex(of: "big") ?? 99) < (order.firstIndex(of: "small") ?? -1))
    }

    @Test func csvQuotesAwkwardNames() async throws {
        let (tree, root, totals) = try await scanned()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = render(tree, root, totals, .csv)
        #expect(text.hasPrefix("path,type,size_bytes,logical_bytes,modified\n"))
        #expect(text.contains("a,b \"\"q\"\".txt\""), "comma and quote require RFC 4180 quoting")
        #expect(text.split(separator: "\n").count == tree.count + 1)
        let rootRow = text.split(separator: "\n")[1]
        #expect(rootRow.hasSuffix(TreeExporter.isoDay(tree.modifiedDay[0])) && tree.modifiedDay[0] > 0,
                "the scan root has its own date (from the walk's root lstat)")
    }

    @Test func nestedJSONSumsAndFilters() async throws {
        let (tree, root, totals) = try await scanned()
        defer { try? FileManager.default.removeItem(at: root) }
        let all = try #require(try JSONSerialization.jsonObject(with: Data(render(tree, root, totals, .json).utf8)) as? [String: Any])
        let rootNode = try #require(all["tree"] as? [String: Any])
        #expect(rootNode["size"] as? Int64 == totals.allocated[0] || (rootNode["size"] as? Int).map(Int64.init) == totals.allocated[0])

        let filtered = render(tree, root, totals, .json, ExportOptions(minBytes: 50_000))
        #expect(!filtered.contains("readme.md"), "below --min-size")
        #expect(filtered.contains("movie.mov"))

        let shallow = render(tree, root, totals, .json, ExportOptions(maxDepth: 1))
        #expect(shallow.contains("\"truncated\":true"))
        #expect(!shallow.contains("clip.mp4"))
    }

    /// ncdu: directories are arrays whose first element describes them;
    /// every node appears exactly once; asize/dsize are logical/allocated.
    @Test func ncduStructureCoversEveryNode() async throws {
        let (tree, root, totals) = try await scanned()
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(render(tree, root, totals, .ncdu).utf8)) as? [Any])
        #expect(doc[0] as? Int == 1 && doc[1] as? Int == 1)
        let rootDir = try #require(doc[3] as? [Any])
        func count(_ node: Any) -> Int {
            if let dir = node as? [Any] { return 1 + dir.dropFirst().map(count).reduce(0, +) }
            return 1
        }
        #expect(count(rootDir) == tree.count)
        #expect((rootDir[0] as? [String: Any])?["name"] as? String == root.path)
    }

    @Test func isoDayMatchesTheCalendar() {
        #expect(TreeExporter.isoDay(0) == "")
        #expect(TreeExporter.isoDay(1) == "1970-01-02")
        #expect(TreeExporter.isoDay(19_723) == "2024-01-01")
        #expect(TreeExporter.isoDay(19_782) == "2024-02-29")   // leap day
        #expect(TreeExporter.isoDay(20_724) == "2026-09-28")
        #expect(TreeExporter.isoDay(19_723) == "2024-01-01", "cached value is identical")
    }

    @Test func jsonEscapingIsCorrectOnBothPaths() throws {
        for s in ["plain.txt", "tab\there", "quote\"back\\slash", "ctrl\u{01}char", "ünïcødé 🎬"] {
            let decoded = try JSONSerialization.jsonObject(with: Data("[\(TreeExporter.jsonString(s))]".utf8)) as? [String]
            #expect(decoded == [s])
        }
    }

    @Test func humanSizes() {
        #expect(HumanUnits.bytes("50GB") == 50_000_000_000)
        #expect(HumanUnits.bytes("1.5 TB") == 1_500_000_000_000)
        #expect(HumanUnits.bytes("500m") == 500_000_000)
        #expect(HumanUnits.bytes("2GiB") == 2_147_483_648)
        #expect(HumanUnits.bytes("123") == 123)
        #expect(HumanUnits.bytes("lots") == nil)
        #expect(HumanUnits.bytes("5XB") == nil)
    }

    @Test func humanAges() {
        #expect(HumanUnits.days("30d") == 30)
        #expect(HumanUnits.days("2w") == 14)
        #expect(HumanUnits.days("6m") == 180)
        #expect(HumanUnits.days("1y") == 365)
        #expect(HumanUnits.days("soon") == nil)
    }
}
