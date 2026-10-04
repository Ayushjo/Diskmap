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

@Suite("Chart keyboard navigation")
struct ChartNavigationTests {
    // 2 × 2 grid: 1 2 / 3 4, plus a wide tile 5 under both.
    private let tiles: [(id: Int32, rect: CGRect)] = [
        (1, CGRect(x: 0, y: 0, width: 50, height: 50)), (2, CGRect(x: 50, y: 0, width: 50, height: 50)),
        (3, CGRect(x: 0, y: 50, width: 50, height: 50)), (4, CGRect(x: 50, y: 50, width: 50, height: 50)),
        (5, CGRect(x: 0, y: 100, width: 100, height: 30)),
    ]

    @Test func treemapArrowsGoToTheNeighbour() {
        #expect(ChartNavigation.neighbor(of: 1, toward: .right, in: tiles) == 2)
        #expect(ChartNavigation.neighbor(of: 1, toward: .down, in: tiles) == 3)
        #expect(ChartNavigation.neighbor(of: 4, toward: .left, in: tiles) == 3)
        #expect(ChartNavigation.neighbor(of: 3, toward: .down, in: tiles) == 5)
        #expect(ChartNavigation.neighbor(of: 2, toward: .right, in: tiles) == 2, "nothing further: stay")
        #expect(ChartNavigation.neighbor(of: nil, toward: .right, in: tiles) == 1, "nothing selected: the first tile")
    }

    @Test func slicesStepBetweenSiblingsAndLevels() {
        let grandchild = ChartSlice(id: "g", nodeID: 30, size: 5, label: "g", drillable: false, children: [])
        let big = ChartSlice(id: "b", nodeID: 10, size: 100, label: "big", drillable: true, children: [grandchild])
        let small = ChartSlice(id: "s", nodeID: 20, size: 40, label: "small", drillable: false, children: [])
        let other = ChartSlice(id: "o", nodeID: nil, size: 60, label: "Other", drillable: false, children: [], collapsedCount: 9)
        let slices = [small, other, big]
        #expect(ChartNavigation.step(from: nil, toward: .right, in: slices) == 10, "start at the largest")
        #expect(ChartNavigation.step(from: 10, toward: .right, in: slices) == 20, "next smaller, skipping Other")
        #expect(ChartNavigation.step(from: 20, toward: .right, in: slices) == 20)
        #expect(ChartNavigation.step(from: 20, toward: .left, in: slices) == 10)
        #expect(ChartNavigation.step(from: 10, toward: .down, in: slices) == 30)
        #expect(ChartNavigation.step(from: 30, toward: .up, in: slices) == 10)
        #expect(ChartNavigation.step(from: 10, toward: .up, in: slices) == 10, "top level stays")
    }
}
