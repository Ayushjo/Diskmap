import Foundation
import Testing
@testable import DiskMapCore

/// TASK-081 — Find queries kept in the sidebar.
@Suite("Saved searches")
struct SavedSearchTests {

    @Test func theListRoundTripsAndIsCapped() {
        let list = (0..<25).map { SavedSearch(name: "s\($0)", query: "size>\($0)MB", sort: .oldest) }
        let decoded = SavedSearches.decode(SavedSearches.encode(list))
        #expect(decoded.count == SavedSearches.limit)
        #expect(decoded.first == list.first)
        #expect(decoded.first?.fileSort == .oldest)
        #expect(SavedSearches.decode(nil).isEmpty)
        #expect(SavedSearches.decode("not json").isEmpty)
    }

    @Test func totalsMatchFind() {
        var tree = FileTree()
        _ = tree.addNode(name: "r", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        let dl = tree.addNode(name: "Downloads", parent: 0, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "a.mp4", parent: dl, isDirectory: false, logicalSize: 0, allocatedSize: 2_000_000_000, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "b.mp4", parent: 0, isDirectory: false, logicalSize: 0, allocatedSize: 500_000_000, modifiedDaysSinceEpoch: 0)
        _ = tree.addNode(name: "app.log", parent: 0, isDirectory: false, logicalSize: 0, allocatedSize: 60_000_000, modifiedDaysSinceEpoch: 0)
        let totals = tree.rollUpBoth().allocated
        let root = URL(fileURLWithPath: "/Users/t", isDirectory: true)
        let context = FileQuery.Context(home: "/Users/t")
        let list = [SavedSearch(name: "Big videos", query: "kind:video size>1GB"),
                    SavedSearch(name: "Logs", query: "name:*.log size>50MB"),
                    SavedSearch(name: "Videos", query: "ext:mp4")]
        let result = SavedSearches.totals(list, tree: tree, root: root, totals: totals, context: context)
        for search in list {
            let run = FileQuery.parse(search.query, home: "/Users/t", root: root.path).query
                .run(tree: tree, root: root, totals: totals, context: context)
            #expect(result[search.id] == SavedSearches.Total(count: run.matchCount, bytes: run.matchedBytes))
        }
        #expect(result[list[0].id]?.count == 1)
        #expect(result[list[2].id]?.bytes == 2_500_000_000)
    }

    @Test func defaultNamesSayWhatTheQueryMeans() {
        let name = SavedSearches.defaultName(for: "kind:video size>1GB", home: "/Users/t", root: "/Users/t")
        #expect(!name.isEmpty)
        #expect(name.first?.isUppercase == true)
        #expect(name.count <= 40)
        #expect(name.localizedCaseInsensitiveContains("1 GB"))
        #expect(SavedSearches.starters.count == 3)
    }
}
