import Foundation
import Testing
@testable import DiskMapApp
@testable import DiskMapCore

/// TASK-060 — the Find screen's chips are query tokens.
@Suite("Find chips")
struct FindViewTests {

    @Test func everyChipIsAValidQueryToken() {
        for chip in FindView.chips {
            let parsed = FileQuery.parse(chip.token, home: "/Users/x", root: "/Users/x")
            #expect(parsed.problems.isEmpty, "\(chip.id)")
            #expect(parsed.query.isStructured, "\(chip.id) must switch ⌘K into query mode")
            let on = FileQuery.toggling(chip.token, in: "report")
            #expect(FileQuery.contains(chip.token, in: on))
            #expect(FileQuery.toggling(chip.token, in: on) == "report")
        }
    }

    @Test func everyExampleParsesCleanly() {
        for example in FindView.examples {
            #expect(FileQuery.parse(example, home: "/Users/x", root: "/Users/x").problems.isEmpty, "\(example)")
        }
    }

    @Test func chipUseIsCountedLocally() throws {
        let suite = "diskmap-find-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        FindView.recordChipUse("large", defaults: defaults)
        FindView.recordChipUse("large", defaults: defaults)
        FindView.recordChipUse("old", defaults: defaults)
        #expect(defaults.dictionary(forKey: FindView.chipUseKey) as? [String: Int] == ["large": 2, "old": 1])
    }

    /// Search merged into Find: one bare word (with or without type:) goes
    /// to the name index; anything else, or another sort, to FileQuery.
    @Test func bareWordsUseTheNameIndex() {
        func needle(_ text: String, _ sort: FileQuery.Sort = .largest) -> (String, FileSearchIndex.KindFilter)? {
            FindView.indexNeedle(for: FileQuery.parse(text, home: "/Users/x", root: "/Users/x").query, sort: sort)
        }
        #expect(needle("report")?.0 == "report")
        #expect(needle("report")?.1 == .all)
        #expect(needle("type:folder node_modules")?.1 == .folders)
        #expect(needle("type:file report")?.1 == .files)
        #expect(needle("report", .oldest) == nil)
        #expect(needle("two words") == nil)
        #expect(needle("report size>1GB") == nil)
        #expect(needle("-report") == nil)
        #expect(FindView.examples.allSatisfy { needle($0) == nil || $0.hasPrefix("type:") })
        #expect(FindView.examples.count == FindView.exampleMeanings.count)
    }
}
