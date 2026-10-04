import Foundation
import Testing
@testable import DiskMapApp

/// AGENTS.md rule 2 (amended for TASK-083): nothing calls the network except
/// Sparkle in Updates.swift, and that is off unless the user turns it on.
@MainActor
@Suite("Network policy")
struct NetworkPolicyTests {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    @Test func onlyUpdatesSwiftMayTouchTheNetwork() throws {
        let forbidden = ["URLSession", "NWConnection", "NWPathMonitor", "URLRequest", "CFNetwork", "CFSocket",
                         "NSURLConnection", "import Network", "import Sparkle", "WKWebView", "SPUStandardUpdaterController"]
        let enumerator = try #require(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var checked = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            checked += 1
            if url.lastPathComponent == "Updates.swift" { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for word in forbidden where text.contains(word) {
                offenders.append("\(url.lastPathComponent): \(word)")
            }
        }
        #expect(checked > 100, "the source folder was found")
        #expect(offenders.isEmpty, "networking outside Updates.swift: \(offenders)")
    }

    @Test func automaticChecksAreOffByDefault() {
        #expect(Updates.automaticDefault == false)
        // A plain test run has no update feed: it could not check even if asked.
        #expect(Updates.shared.isConfigured == false)
    }
}
