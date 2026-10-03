import Foundation
import Testing
@testable import DiskMapApp
@testable import DiskMapCore

/// TASK-079 — only the app's own model writes storage history; tests and the
/// snapshot harness (a plain `ScanModel()`) never touch the user's file.
@MainActor
@Suite("Storage history in the app")
struct StorageHistoryAppTests {

    @Test func aPlainModelNeverWritesHistory() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("diskmap-history-app-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("big"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 60_000_000).write(to: root.appendingPathComponent("big/blob.bin"))
        let model = ScanModel()
        await model.scan(root, mode: .full)
        #expect(model.tree != nil)
        let history = StorageHistory()
        #expect(history.entries(for: root.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: history.primaryURL(for: root.path).path))
        #expect(model.weekComparison == nil)
    }

    @Test func theMenuBarLineSaysTheWeek() {
        let comparison = StorageHistory.Comparison(
            since: Date(), isWeek: true, freeDelta: -12_000_000_000, scannedDelta: 9_000_000_000,
            growers: [.init(path: "Library", before: 1_000_000_000, after: 9_000_000_000)], deniedChanged: false)
        #expect(MenuBarText.week(comparison) == "Free space −12 GB this week · Library +8 GB")
        let quiet = StorageHistory.Comparison(since: Date(), isWeek: true, freeDelta: 10, scannedDelta: 0, growers: [], deniedChanged: false)
        #expect(MenuBarText.week(quiet) == nil)
    }
}
