import Foundation
import Testing
@testable import DiskMapApp
@testable import DiskMapCore

/// Milestone 15 — keyboard, drop to scan, menu bar.
@MainActor
@Suite("Native affordances")
struct NativeAffordanceTests {

    @Test func numberedShortcutsFollowTheSidebar() {
        let numbered = KeyboardCommands.numberedDestinations
        #expect(numbered.count == 9)
        #expect(numbered.first == .overview)
        #expect(numbered == Array(AppNavSection.allCases.flatMap(\.items).prefix(9)))
    }

    @Test func enclosingAndOpenFolderMoveThroughTheTree() {
        var tree = FileTree()
        let root = tree.addNode(name: "r", parent: -1, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        let folder = tree.addNode(name: "a", parent: root, isDirectory: true, logicalSize: 0, allocatedSize: 0, modifiedDaysSinceEpoch: 1)
        let file = tree.addNode(name: "f", parent: folder, isDirectory: false, logicalSize: 5, allocatedSize: 5, modifiedDaysSinceEpoch: 1)
        let model = ScanModel()
        model.tree = tree
        model.selectedNode = folder
        model.openSelectedFolder()
        #expect(model.currentNode == folder)
        model.selectedNode = file
        model.openSelectedFolder()
        #expect(model.currentNode == folder, "a file opens its folder")
        model.goToEnclosingFolder()
        #expect(model.currentNode == root)
        #expect(model.selectedNode == folder, "coming back up selects where you were")
        model.goToEnclosingFolder()
        #expect(model.currentNode == root, "the root has nowhere to go")
    }

    @Test func onlyFoldersAreScannedFromADrop() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("diskmap-drop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("folder")
        let app = base.appendingPathComponent("Thing.app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let file = base.appendingPathComponent("file.txt")
        try Data([1]).write(to: file)
        #expect(scannableFolder([file]) == nil)
        #expect(scannableFolder([app]) == nil, "an app bundle is not a folder to scan")
        #expect(scannableFolder([file, folder])?.path == folder.standardizedFileURL.path)
        #expect(scannableFolder([URL(string: "https://example.com")!]) == nil)
    }

    @Test func menuBarDeltaIgnoresNoise() {
        let gb: UInt64 = 1_000_000_000
        #expect(MenuBarText.delta(previousFree: 30 * gb, currentFree: 30 * gb + 10_000_000) == "Free space is about the same as at your last scan.")
        #expect(MenuBarText.delta(previousFree: 30 * gb, currentFree: 27 * gb) == "3 GB less free than at your last scan.")
        #expect(MenuBarText.delta(previousFree: 20 * gb, currentFree: 22 * gb) == "2 GB more free than at your last scan.")
        #expect(MenuBarText.isLow(VolumeStats(volumeName: "x", totalBytes: 100, freeBytes: 9, usedBytes: 91)))
        #expect(!MenuBarText.isLow(VolumeStats(volumeName: "x", totalBytes: 100, freeBytes: 20, usedBytes: 80)))
    }

    @Test func lastScanRecordRoundTrips() throws {
        let suite = "diskmap-lastscan-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(LastScanRecord.load(from: defaults) == nil)
        let record = LastScanRecord(rootPath: "/Users/x", scannedAt: Date(timeIntervalSince1970: 1_000), freeBytes: 42, scannedBytes: 7)
        record.save(to: defaults)
        #expect(LastScanRecord.load(from: defaults) == record)
    }

    @Test func testModelsDoNotRecordTheLastScan() {
        #expect(!ScanModel().recordsLastScan)
        #expect(ScanModel.shared.recordsLastScan)
    }
}
