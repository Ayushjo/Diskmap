import Foundation
import Testing
@testable import DiskMapApp

@MainActor
@Suite("Text size")
struct TextSizeTests {
    @Test func scalesAndSteps() {
        #expect(TextSize.allCases.map(\.scale) == [0.9, 1.0, 1.15, 1.3])
        #expect(TextSize.standard.bigger == .larger)
        #expect(TextSize.largest.bigger == .largest)
        #expect(TextSize.smaller.smaller == .smaller)
        #expect(TextSize.largest.smaller == .larger)
    }

    @Test func tokensFollowTheScale() {
        let saved = DiskMapType.scale
        defer { DiskMapType.scale = saved }
        DiskMapType.scale = TextSize.largest.scale
        #expect(DiskMapType.scaled(13) == 13 * 1.3)
        #expect(DiskMapMetric.sidebarWidth == 260)
        DiskMapType.scale = TextSize.smaller.scale
        #expect(DiskMapMetric.sidebarWidth == 200, "the sidebar never gets narrower than the default")
    }
}
