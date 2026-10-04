import Foundation
import Testing
@testable import DiskMapCore

/// TASK-059 — the query language behind ⌘K, Find and `diskmap find`.
@Suite("File query")
struct FileQueryTests {

    static let home = "/Users/alex"

    private func parse(_ text: String, root: String = "/Users/alex") -> FileQuery.Parsed {
        FileQuery.parse(text, home: Self.home, root: root)
    }

    // MARK: Parsing

    @Test func parsesTheTicketExamples() {
        let a = parse("ext:mp4 size>500mb age>1y path:~/Downloads")
        #expect(a.problems.isEmpty)
        #expect(a.query.extensions == ["mp4"])
        #expect(a.query.sizeBounds == [.init(comparison: .greater, value: 500_000_000)])
        #expect(a.query.ageBounds == [.init(comparison: .greater, value: 365)])
        #expect(a.query.paths == ["/Users/alex/Downloads"])
        #expect(a.query.effectiveType == .files)

        let b = parse("name:*.log size>=100MB")
        #expect(b.query.namePatterns == ["*.log"])
        #expect(b.query.sizeBounds == [.init(comparison: .greaterOrEqual, value: 100_000_000)])
    }

    @Test func plainWordsStayPlain() {
        let parsed = parse("Invoice 2024 -draft sizeable 10:30")
        #expect(parsed.problems.isEmpty)
        #expect(parsed.query.words == ["invoice", "2024", "sizeable", "10:30"], "unknown keys are just words")
        #expect(parsed.query.excludedWords == ["draft"])
        #expect(parsed.query.effectiveType == .any)
        #expect(!parse("report").query.isStructured)
        #expect(parse("report ext:pdf").query.isStructured)
    }

    @Test func badValuesAreReportedAndLeftOut() {
        let parsed = parse("size> ext:mp4 age<soon kind:spreadsheets type:blob in:nowhere size:1gb")
        #expect(parsed.query.extensions == ["mp4"], "the good token still applies")
        #expect(parsed.query.sizeBounds.isEmpty && parsed.query.ageBounds.isEmpty)
        #expect(parsed.problems.map(\.token) == ["size>", "age<soon", "kind:spreadsheets", "type:blob", "in:nowhere", "size:1gb"])
    }

    @Test func pathsExpandAndQuote() {
        #expect(parse("path:\"~/My Movies\"").query.paths == ["/Users/alex/My Movies"])
        #expect(parse("path:Projects/app", root: "/Volumes/Work").query.paths == ["/Volumes/Work/Projects/app"])
        #expect(parse("path:/tmp/../var/").query.paths == ["/var"])
        #expect(FileQuery.tokenize("a path:\"x y\" b") == ["a", "path:\"x y\"", "b"])
    }

    @Test func chipsToggleTokens() {
        var text = "report"
        text = FileQuery.toggling("size>500MB", in: text)
        #expect(text == "report size>500MB")
        #expect(FileQuery.contains("SIZE>500mb", in: text))
        text = FileQuery.toggling("size>500mb", in: text)
        #expect(text == "report")
    }

    @Test func describesInPlainLanguage() {
        let parts = parse("ext:mp4,mov size>500MB age>1y in:downloads").query.describe(home: Self.home)
        #expect(parts == ["Files", "larger than 500 MB", "untouched for 1 year+", ".mp4 or .mov", "in ~/Downloads"])
        #expect(parse("type:folder").query.describe(home: Self.home) == ["Folders"])
    }

    // MARK: Running

    final class Fixture {
        let root: URL
        let tree: FileTree
        let totals: [Int64]
        init() async throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("diskmap-query-\(UUID().uuidString)")
            let old = Date().addingTimeInterval(-400 * 86_400)
            for (rel, bytes, date) in [
                ("Downloads/movie.mp4", 900_000, old),
                ("Downloads/clip.MOV", 300_000, Date()),
                ("Downloads/setup.dmg", 700_000, old),
                ("Downloads/notes.txt", 2_000, Date()),
                ("Library/Caches/com.app/blob.bin", 500_000, Date()),
                (".cache/pip/wheel.whl", 200_000, Date()),
                ("code/app/build.log", 150_000, Date()),
                ("code/app/node_modules/x.mp4/readme.md", 1_000, Date()),   // a folder named like a video
                ("Pictures/photo.heic", 50_000, old),
            ] as [(String, Int, Date)] {
                let url = root.appendingPathComponent(rel)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 7, count: bytes).write(to: url)
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            }
            let scanned = await ScanEngine().scan(root: root).tree
            tree = scanned
            totals = scanned.rollUpBoth().logical
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        func run(_ text: String, sort: FileQuery.Sort = .largest, duplicates: Set<Int32>? = nil, limit: Int = 500) -> (names: [String], result: FileQuery.Result) {
            let parsed = FileQuery.parse(text, home: root.path, root: root.path)
            let result = parsed.query.run(tree: tree, root: root, totals: totals,
                                          context: .init(home: root.path, duplicateFileIDs: duplicates),
                                          sort: sort, limit: limit)
            return (result.ids.map { tree.name(of: $0) }, result)
        }
    }

    @Test func filtersCombine() async throws {
        let f = try await Fixture()
        #expect(f.run("ext:mp4,mov").names == ["movie.mp4", "clip.MOV"], "case-insensitive, largest first")
        #expect(f.run("ext:mp4 age>1y").names == ["movie.mp4"])
        #expect(f.run("size>600KB in:downloads").names == ["movie.mp4", "setup.dmg"])
        #expect(f.run("kind:media").names == ["movie.mp4", "clip.MOV", "photo.heic"])
        #expect(f.run("name:*.log").names == ["build.log"])
        #expect(f.run("kind:video").names.contains("x.mp4") == false, "folders never match a kind")
    }

    @Test func cachesMeanTheSameFoldersAsTheCachesScreenPlusDotCache() async throws {
        let f = try await Fixture()
        #expect(Set(f.run("in:caches type:file").names) == ["blob.bin", "wheel.whl"])
    }

    @Test func folderMatchesDoNotDoubleCountBytes() async throws {
        let f = try await Fixture()
        let (names, result) = f.run("type:folder in:downloads")
        #expect(names == ["Downloads"])
        let downloads = try #require(f.run("path:Downloads type:folder").result.ids.first)
        #expect(result.matchedBytes == f.totals[Int(downloads)])
        let nested = f.run("type:folder a")   // "app", "Caches", "com.app", "cache"… nest inside each other
        #expect(nested.result.matchedBytes <= f.totals[0])
    }

    @Test func sortsAndLimits() async throws {
        let f = try await Fixture()
        let oldest = f.run("type:file", sort: .oldest).names
        #expect(Set(oldest.prefix(3)) == ["movie.mp4", "setup.dmg", "photo.heic"])
        let limited = f.run("type:file", limit: 2)
        #expect(limited.names == ["movie.mp4", "setup.dmg"])
        #expect(limited.result.matchCount == 9)
    }

    @Test func duplicatesNeedTheFinderToHaveRun() async throws {
        let f = try await Fixture()
        let before = f.run("is:duplicate")
        #expect(before.result.matchCount == 0)
        #expect(before.result.notes == ["Duplicates haven't been searched in this scan yet"])
        let movie = try #require(f.run("movie").result.ids.first)
        #expect(f.run("is:duplicate", duplicates: [movie]).names == ["movie.mp4"])
    }

    @Test func pathsOutsideOrMissingAreExplained() async throws {
        let f = try await Fixture()
        #expect(f.run("path:/etc").result.notes.first?.hasSuffix("is outside this scan") == true)
        #expect(f.run("path:Nope").result.notes.first?.hasSuffix("isn't in this scan") == true)
    }

    /// The fast evaluator (per-name verdicts, forward place pass, heap)
    /// against the obvious one: build every path, test every node.
    @Test func agreesWithANaiveEvaluator() async throws {
        let f = try await Fixture()
        for text in ["ext:mp4", "in:downloads", "in:caches", "a", "-log type:file", "size<100KB", "kind:archive,image age>30d", "type:any o"] {
            let parsed = FileQuery.parse(text, home: f.root.path, root: f.root.path).query
            let fast = Set(parsed.run(tree: f.tree, root: f.root, totals: f.totals,
                                      context: .init(home: f.root.path), limit: 10_000).ids)
            var naive = Set<Int32>()
            let today = AgeMap.today()
            for index in 1..<f.tree.count {
                let id = Int32(index)
                let path = f.tree.path(of: id, root: f.root).path
                let name = f.tree.name(of: id).lowercased()
                let isDir = f.tree.isDirectory[index]
                switch parsed.effectiveType {
                case .files where isDir, .folders where !isDir: continue
                default: break
                }
                let components = path.dropFirst(f.root.path.count).split(separator: "/").map { $0.lowercased() }
                if parsed.places.contains(.downloads), !path.hasPrefix(f.root.path + "/Downloads") { continue }
                if parsed.places.contains(.caches), !components.dropLast(isDir ? 0 : 1).contains(where: { ["caches", ".cache", "deriveddata"].contains($0) }) { continue }
                if parsed.sizeBounds.contains(where: { !$0.comparison.holds(f.totals[index], $0.value) }) { continue }
                if !parsed.ageBounds.isEmpty {
                    let day = f.tree.modifiedDay[index]
                    if day == 0 || parsed.ageBounds.contains(where: { !$0.comparison.holds(Int64(today - day), $0.value) }) { continue }
                }
                if !parsed.words.allSatisfy({ name.contains($0) }) || parsed.excludedWords.contains(where: { name.contains($0) }) { continue }
                let ext = (name as NSString).pathExtension
                if !parsed.extensions.isEmpty, isDir || !parsed.extensions.contains(ext) { continue }
                if !parsed.kinds.isEmpty {
                    let exts = parsed.kinds.reduce(into: Set<String>()) { $0.formUnion(FileQuery.kindExtensions[$1] ?? []) }
                    if isDir || !exts.contains(ext) { continue }
                }
                naive.insert(id)
            }
            #expect(fast == naive, "\(text)")
        }
    }

    /// The byte-level fast path must agree with the String path wherever it
    /// answers, and must decline (nil) for non-ASCII names.
    @Test func asciiMatcherAgreesWithStringMatching() throws {
        let names = ["Report-2024.PDF", "build.log", "Movie.MP4", ".mp4", "x.tar.gz", "README", "notes.txt",
                     "café.log", "Ünïcode.mp4", "a[1].log", "noext.", "LOG", "clip.mov"]
        for text in ["log", "-log", "name:*.log", "name:rep*", "name:*[0-9]*", "ext:mp4,gz", "kind:media",
                     "kind:archive -x", "name:ead report", "café", "log -ü", "ext:mp4 -é", "name:*e?d*", "name:re*.pdf"] {
            let query = FileQuery.parse(text, home: "/h", root: "/h").query
            let kinds = query.kinds.reduce(into: Set<String>()) { $0.formUnion(FileQuery.kindExtensions[$1] ?? []) }
            let matcher = try #require(ASCIINameMatcher(query: query, kindSet: kinds))
            for name in names {
                let fast = Array(name.utf8).withUnsafeBufferPointer { matcher.matches($0) }
                if name.utf8.contains(where: { $0 >= 0x80 }) {
                    #expect(fast == nil, "\(name) must fall back")
                } else {
                    #expect(fast == query.nameMatches(name, kindSet: kinds), "\(text) on \(name)")
                }
            }
        }
        // Non-ASCII words: an ASCII name is a definite no; a non-ASCII name falls back.
        let cafe = try #require(ASCIINameMatcher(query: FileQuery.parse("café -ü", home: "/h", root: "/h").query, kindSet: []))
        #expect(Array("cafe.txt".utf8).withUnsafeBufferPointer { cafe.matches($0) } == false)
        #expect(Array("café.txt".utf8).withUnsafeBufferPointer { cafe.matches($0) } == nil)
        let nonASCIIExclusion = try #require(ASCIINameMatcher(query: FileQuery.parse("log -ü", home: "/h", root: "/h").query, kindSet: []))
        #expect(Array("build.log".utf8).withUnsafeBufferPointer { nonASCIIExclusion.matches($0) } == true)
        #expect(ASCIINameMatcher(query: FileQuery.parse("name:[!é]*", home: "/h", root: "/h").query, kindSet: []) == nil)
    }

    @Test func globLiteralPrefilter() {
        #expect(ASCIINameMatcher.longestLiteral(in: "*.log") == Array(".log".utf8))
        #expect(ASCIINameMatcher.longestLiteral(in: "report-*-final?.pdf") == Array("report-".utf8))
        #expect(ASCIINameMatcher.longestLiteral(in: "*[0-9].log") == [], "brackets: no prefilter")
        #expect(ASCIINameMatcher.longestLiteral(in: "*") == [])
    }

    @Test func topKMatchesAFullSort() {
        var generator = SystemRandomNumberGenerator()
        let values = (0..<5_000).map { _ in Int64.random(in: 0..<1_000, using: &generator) }
        let before: (Int32, Int32) -> Bool = { values[Int($0)] != values[Int($1)] ? values[Int($0)] > values[Int($1)] : $0 < $1 }
        var top = TopK(limit: 37, before: before)
        for id in 0..<Int32(values.count) { top.insert(id) }
        #expect(top.sorted() == Array((0..<Int32(values.count)).sorted(by: before).prefix(37)))
    }
}
