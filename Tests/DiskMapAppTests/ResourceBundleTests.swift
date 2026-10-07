import Foundation
import Testing
@testable import DiskMapBrand

/// A packaged app keeps its SwiftPM resource bundles in `Contents/Resources`,
/// where the generated `Bundle.module` never looks: it falls back to the build
/// folder of the Mac that compiled it and traps anywhere else. 0.2.2 crashed on
/// other Macs on the first resize, maximize or sidebar toggle (the sidebar
/// wordmark loading the Dusty logo through `Bundle.module`).
@Suite("Resource bundles")
struct ResourceBundleTests {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    /// A fake `freedisk.space.app` with the brand bundle where build-adhoc.sh puts it.
    @Test func brandLogoIsFoundInAPackagedAppsResources() throws {
        let real = try #require(Bundle.module.bundleURL as URL?)
        #expect(real.lastPathComponent == DiskMapBrandResources.bundleName)

        let app = FileManager.default.temporaryDirectory.appendingPathComponent("brand-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: app) }
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: real, to: resources.appendingPathComponent(DiskMapBrandResources.bundleName))

        let found = try #require(DiskMapBrandResources.packagedBundle(resourceURL: resources, bundleURL: app))
        #expect(found.url(forResource: "dusty-peek-mark", withExtension: "svg") != nil)
    }

    /// With no bundle anywhere the lookup reports nil (the drawn fallback mark), never traps.
    @Test func missingBundleIsNilNotACrash() {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString)")
        #expect(DiskMapBrandResources.packagedBundle(resourceURL: empty, bundleURL: empty) == nil)
    }

    @Test func logoLoads() {
        #expect(DiskMapBrand.peekMark != nil)
    }

    /// `Bundle.module` only inside the two lookup helpers that try the packaged places first.
    @Test func bundleModuleOnlyBehindThePackagedLookups() throws {
        let allowed: Set<String> = ["Resources.swift", "BrandAssets.swift"]
        let enumerator = try #require(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" && !allowed.contains(url.lastPathComponent) {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("Bundle.module") { offenders.append(url.lastPathComponent) }
        }
        #expect(offenders.isEmpty, "Bundle.module crashes in a packaged app; use the packaged lookup: \(offenders)")
    }
}
