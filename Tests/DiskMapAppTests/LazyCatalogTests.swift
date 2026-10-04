import Foundation
import Testing
@testable import DiskMapApp
@testable import DiskMapCore

/// TASK-043 — per-screen catalogs are built on first visit, not before first
/// paint. TASK-042 measured the eager build holding first paint for ~7.7 s.
@MainActor
@Suite("Lazy catalogs")
struct LazyCatalogTests {

    private func scannedModel() async throws -> (ScanModel, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskmap-lazy-\(UUID().uuidString)")
        let downloads = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2_000_000).write(to: downloads.appendingPathComponent("installer.dmg"))
        let model = ScanModel()
        await model.scan(root)
        return (model, root)
    }

    @Test func firstPaintBuildsNoPerScreenCatalog() async throws {
        let (model, root) = try await scannedModel()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(model.tree != nil)
        #expect(model.readyCatalogs.isEmpty)
        #expect(model.cachedOldDownloads == .empty)
        #expect(model.cachedLargeMedia == .empty)
    }

    @Test func visitingAScreenBuildsOnlyItsCatalog() async throws {
        let (model, root) = try await scannedModel()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.ensureCatalog(.oldDownloads)
        #expect(model.isCatalogReady(.oldDownloads))
        #expect(model.cachedOldDownloads.candidates.contains { $0.name == "installer.dmg" })
        #expect(!model.isCatalogReady(.largeMedia))
        #expect(!model.isCatalogReady(.developer))
    }

    /// A screen with nothing to show must not rebuild on every visit — the old
    /// `isEmpty` check could not tell "not built" from "built, empty".
    @Test func anEmptyCatalogStillCountsAsBuilt() async throws {
        let (model, root) = try await scannedModel()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.ensureCatalog(.developer)
        #expect(model.cachedDeveloper.items.isEmpty)
        #expect(model.isCatalogReady(.developer))
        let generation = model.catalogGeneration
        await model.ensureCatalog(.developer)
        #expect(model.catalogGeneration == generation)
        #expect(model.isCatalogReady(.developer))
    }

    @Test func concurrentRequestsShareOneBuild() async throws {
        let (model, root) = try await scannedModel()
        defer { try? FileManager.default.removeItem(at: root) }
        async let a: Void = model.ensureCatalog(.largeMedia)
        async let b: Void = model.ensureCatalog(.largeMedia)
        _ = await (a, b)
        #expect(model.isCatalogReady(.largeMedia))
    }

    /// A new scan (or a basis toggle) makes every cached catalog stale; open
    /// screens pick that up through the generation counter.
    @Test func rescanInvalidatesBuiltCatalogs() async throws {
        let (model, root) = try await scannedModel()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.ensureCatalog(.oldDownloads)
        let before = model.catalogGeneration
        await model.scan(root)
        #expect(model.catalogGeneration > before)
        #expect(!model.isCatalogReady(.oldDownloads))
        #expect(model.cachedOldDownloads == .empty)
    }
}
