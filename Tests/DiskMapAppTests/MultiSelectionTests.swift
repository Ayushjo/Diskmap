import AppKit
import Foundation
import Testing
@testable import DiskMapApp
@testable import DiskMapCore

/// ⌘-click / ⇧-click selection shared by Visualize and the ranked lists.
@MainActor
@Suite("Multi-selection")
struct MultiSelectionTests {

    /// root ─ a (dir, 300) ─ a1 (100), a2 (200) ; b (50) ; c (10)
    private func model() -> (ScanModel, a: Int32, a1: Int32, a2: Int32, b: Int32, c: Int32) {
        var tree = FileTree()
        let root = tree.addNode(name: "r", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        let a = tree.addNode(name: "a", parent: root, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        let a1 = tree.addNode(name: "a1", parent: a, isDirectory: false, logicalSize: 100, allocatedSize: 100, modifiedDaysSinceEpoch: 1)
        let a2 = tree.addNode(name: "a2", parent: a, isDirectory: false, logicalSize: 200, allocatedSize: 200, modifiedDaysSinceEpoch: 1)
        let b = tree.addNode(name: "b", parent: root, isDirectory: false, logicalSize: 50, allocatedSize: 50, modifiedDaysSinceEpoch: 1)
        let c = tree.addNode(name: "c", parent: root, isDirectory: false, logicalSize: 10, allocatedSize: 10, modifiedDaysSinceEpoch: 1)
        let model = ScanModel()
        model.tree = tree
        model.rootURL = URL(fileURLWithPath: "/r")
        let totals = tree.rollUpBoth()
        model.allocatedTotals = totals.allocated
        model.logicalTotals = totals.logical
        return (model, a, a1, a2, b, c)
    }

    @Test func commandClickBuildsASelectionAndPlainClickResetsIt() {
        let (model, a, _, _, b, c) = model()
        model.select(b, modifiers: [])
        #expect(model.multiSelection.isEmpty && model.selectedNode == b)
        model.select(c, modifiers: .command)
        #expect(model.multiSelection == [b, c], "⌘ adds to what was already selected")
        model.select(a, modifiers: .command)
        model.select(b, modifiers: .command)
        #expect(model.multiSelection == [c, a], "⌘ on a selected item removes it")
        model.select(b, modifiers: [])
        #expect(model.multiSelection.isEmpty)
    }

    @Test func shiftClickSelectsTheRangeInListOrder() {
        let (model, a, _, _, b, c) = model()
        let order = [a, b, c]
        model.select(a, ordered: order, modifiers: [])
        model.select(c, ordered: order, modifiers: .shift)
        #expect(model.multiSelection == [a, b, c])
    }

    @Test func aFolderAndItsContentsCountOnce() {
        let (model, a, a1, _, b, _) = model()
        model.multiSelection = [a, a1, b]
        #expect(Set(model.multiSelectionRoots) == [a, b])
        #expect(model.multiSelectionBytes == 350)
        #expect(model.multiSelectionPaths().sorted() == ["/r/a", "/r/b"])
    }
}
