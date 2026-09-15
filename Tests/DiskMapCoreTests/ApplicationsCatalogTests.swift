import Foundation
import Testing
@testable import DiskMapCore

@Suite("Applications catalog")
struct ApplicationsCatalogTests {
    @Test func appStoreReceiptClassifiesAsAppStore() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("DiskMapAppStoreTest-\(UUID().uuidString)", isDirectory: true)
        let app = tmp.appendingPathComponent("Demo.app", isDirectory: true)
        let receiptDir = app.appendingPathComponent("Contents/_MASReceipt", isDirectory: true)
        try FileManager.default.createDirectory(at: receiptDir, withIntermediateDirectories: true)
        try Data([0x1]).write(to: receiptDir.appendingPathComponent("receipt"))
        defer { try? FileManager.default.removeItem(at: tmp) }

        let source = ApplicationsCatalog.classifySource(bundlePath: app.path, bundleID: "com.example.demo")
        #expect(source == .appStore)
    }

    @Test func systemPathClassifiesAsSystem() {
        let source = ApplicationsCatalog.classifySource(
            bundlePath: "/System/Applications/Safari.app",
            bundleID: "com.apple.Safari"
        )
        #expect(source == .system)
        let status = ApplicationsCatalog.classifyStatus(source: source, totalBytes: 200_000_000, lastUsed: Date(), bundleID: "com.apple.Safari")
        #expect(status == .system)
    }

    @Test func largeStaleAppIsReviewFirst() {
        let old = Calendar.current.date(byAdding: .day, value: -200, to: Date())!
        let status = ApplicationsCatalog.classifyStatus(
            source: .other,
            totalBytes: 2_000_000_000,
            lastUsed: old,
            bundleID: "com.example.big"
        )
        #expect(status == .reviewFirst)
    }

    @Test func relatedKindDetectsDerivedData() {
        #expect(ApplicationsCatalog.relatedKind(forPath: "/Users/x/Library/Developer/Xcode/DerivedData/Foo") == .derivedData)
        #expect(ApplicationsCatalog.relatedKind(forPath: "/Users/x/Library/Caches/com.foo") == .caches)
    }

    @Test func summarizeCountsSources() {
        let apps = [
            ApplicationEntry(
                name: "A", publisher: nil, version: nil, bundleID: nil,
                bundlePath: "/Applications/A.app", bundleBytes: 100, relatedBytes: 50,
                source: .appStore, status: .keep, lastUsed: Date(), installed: nil,
                related: [], blurb: "", whyLarge: "", removalGuidance: "", sizePending: false
            ),
            ApplicationEntry(
                name: "B", publisher: nil, version: nil, bundleID: nil,
                bundlePath: "/Applications/B.app", bundleBytes: 2_000_000_000, relatedBytes: 0,
                source: .other, status: .reviewFirst, lastUsed: nil, installed: nil,
                related: [], blurb: "", whyLarge: "", removalGuidance: "", sizePending: false
            ),
        ]
        let summary = ApplicationsCatalog.summarize(apps)
        #expect(summary.appCount == 2)
        #expect(summary.totalBytes == 2_000_000_150)
        #expect(summary.appStoreCount == 1)
        #expect(summary.otherCount == 1)
        #expect(summary.reviewableBytes == 2_000_000_000)
        #expect(summary.largeCount == 1)
    }
}
