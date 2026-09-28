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
}
