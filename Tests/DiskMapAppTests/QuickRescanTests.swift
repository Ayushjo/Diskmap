import Foundation
import Testing
@testable import DiskMapApp
@testable import DiskMapCore

/// TASK-061 — the app's Rescan starts from the cached last scan.
@MainActor
@Suite("Quick rescan")
struct QuickRescanTests {

    @Test func secondScanIsQuickAndMatchesTheDisk() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("diskmap-quick-\(UUID().uuidString)")
        let root = base.appendingPathComponent("root")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 40_000).write(to: root.appendingPathComponent("a/one.bin"))

        let model = ScanModel(scanCache: ScanCache(directory: base.appendingPathComponent("cache"), slot: "test"))
        await model.scan(root)
        guard case .full(_, let reason) = model.lastScanKind else { Issue.record("first scan must be full"); return }
        #expect(reason?.contains("no earlier scan") == true)
        await model.waitForCacheSave()

        try Data(repeating: 2, count: 90_000).write(to: root.appendingPathComponent("a/two.bin"))
        await model.scan(root)
        guard case .quick = model.lastScanKind else { Issue.record("second scan must be quick, got \(String(describing: model.lastScanKind))"); return }
        let tree = try #require(model.tree)
        #expect((1..<tree.count).contains { tree.name(of: Int32($0)) == "two.bin" })
        let full = await ScanEngine().scan(root: root)
        #expect(model.allocatedTotals.first == full.tree.rollUpBoth().allocated.first)

        await model.scan(root, mode: .full)
        guard case .full(_, nil) = model.lastScanKind else { Issue.record("explicit full rescan"); return }
    }

    @Test func modelsWithoutACacheAlwaysWalk() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("diskmap-nocache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = ScanModel()
        await model.scan(root)
        await model.scan(root)
        guard case .full(_, nil) = model.lastScanKind else { Issue.record("no cache → plain full scans"); return }
    }

    @Test func scanKindCopyIsHonest() {
        #expect(OverviewView.scanKindText(.quick(seconds: 0.72, changedFolders: 6, walkedFolders: 0))
                == "Updated from your last scan in 0.7 s — 6 changed folders re-read, unchanged ones spot-checked.")
        #expect(OverviewView.scanKindText(.quick(seconds: 0.31, changedFolders: 0, walkedFolders: 0))
                == "Updated from your last scan in 0.3 s — nothing changed; a sample of folders was re-read to confirm.")
        #expect(OverviewView.scanKindText(.full(seconds: 11.26, fallbackReason: "periodic full rescan"))
                == "Full scan in 11.3 s. (Walked in full: periodic full rescan.)")
    }
}
