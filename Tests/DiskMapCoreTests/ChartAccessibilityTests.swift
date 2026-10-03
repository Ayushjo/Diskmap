import Foundation
import Testing
@testable import DiskMapCore

@Suite("ChartAccessibility")
struct ChartAccessibilityTests {
    private func bytes(_ value: Int64) -> String { "\(value) B" }

    @Test func biggestFirstWithShares() {
        let items = [
            ChartAccessibility.Item(id: 3, name: "small", size: 5, drillable: false),
            ChartAccessibility.Item(id: 1, name: "big", size: 600, drillable: true),
            ChartAccessibility.Item(id: 2, name: "mid", size: 395, drillable: false),
            ChartAccessibility.Item(id: 4, name: "empty", size: 0, drillable: false),
        ]
        let entries = ChartAccessibility.entries(items, total: 1_000, format: bytes)
        #expect(entries.map(\.id) == [1, 2, 3])
        #expect(entries[0].label == "big, 600 B, 60 percent")
        #expect(entries[0].drillable)
        #expect(entries[2].label == "small, 5 B, less than 1 percent")
    }

    @Test func limitAndStableTies() {
        let items = (0..<100).map { ChartAccessibility.Item(id: Int32(99 - $0), name: "f\($0)", size: 10, drillable: false) }
        let entries = ChartAccessibility.entries(items, total: 1_000, limit: 60, format: bytes)
        #expect(entries.count == 60)
        #expect(entries.first?.id == 0)
        #expect(entries.last?.id == 59)
    }

    @Test func slicesFlattenWithoutOther() {
        let child = ChartSlice(id: "c", nodeID: 5, size: 40, label: "child", drillable: false, children: [])
        let other = ChartSlice(id: "o", nodeID: nil, size: 10, label: "Other", drillable: false, children: [], collapsedCount: 7)
        let parent = ChartSlice(id: "p", nodeID: 2, size: 50, label: "parent", drillable: true, children: [child, other])
        let items = ChartAccessibility.items(in: [parent])
        #expect(Set(items.map(\.id)) == [2, 5])
        #expect(items.first { $0.id == 2 }?.drillable == true)
    }
}
