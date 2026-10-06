import Foundation
import Testing
@testable import DiskMapApp
@testable import DiskMapCore

/// Bulk adds confirm with every path, and leave risky items out
/// (docs/MAC-FIXES-FROM-WINDOWS.md §3.2, §4.2).
@MainActor
@Suite("Stage confirmation")
struct StageConfirmationTests {
    private func request(_ path: String, _ size: Int64 = 1_000) -> CleanupStageRequest {
        CleanupStageRequest(url: URL(fileURLWithPath: path), size: size, reason: "test")
    }

    @Test func riskyItemsAreLeftOutOfBulkAdds() {
        let (safe, skipped) = ScanModel.splitForBulkStage([
            request("/Users/me/code/app/node_modules"),
            request("/Users/me/Downloads/old.zip"),
            request("/Users/me/code/app/.git"),
            request("/Users/me/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"),
            request("/Applications/Slack.app"),
            request("/Users/me/Library/Mobile Documents/com~apple~CloudDocs/a.pdf"),
        ])
        #expect(safe.map(\.url.lastPathComponent) == ["node_modules", "old.zip"])
        #expect(skipped.map(\.request.url.lastPathComponent) == [".git", "Docker.raw", "Slack.app", "a.pdf"])
        #expect(skipped.allSatisfy { $0.verdict.advice.isRisky })
        // Applications adds apps on purpose.
        let apps = ScanModel.splitForBulkStage([request("/Applications/Slack.app"), request("/Applications/Xcode.app")],
                                               allowing: ["apps", "devtools"])
        #expect(apps.safe.count == 2 && apps.skipped.isEmpty)
    }

    @Test func cancellingABulkAddStagesNothing() async {
        let model = ScanModel()
        let requests = [request("/Users/me/Downloads/a.zip"), request("/Users/me/Downloads/b.zip", 5_000)]
        let task = Task { await model.confirmStageMany(requests, title: "Test") }
        for _ in 0..<10_000 where model.pendingBulkStage == nil { await Task.yield() }
        guard let proposal = model.pendingBulkStage else { Issue.record("no confirmation sheet"); return }
        #expect(proposal.safe.count == 2)
        #expect(proposal.skipped.isEmpty)
        proposal.resolve(false)
        #expect(await task.value == nil)
        #expect(model.pendingBulkStage == nil)
        #expect(await model.cleanupQueue.allItems().isEmpty)
    }

    @Test func onlyRiskyItemsShowNoSheetAndSayWhy() async {
        let model = ScanModel()
        let result = await model.confirmStageMany([request("/Users/me/a/.git"), request("/Applications/Slack.app")], title: "Test")
        #expect(result == nil)
        #expect(model.pendingBulkStage == nil)
        #expect(model.toastMessage?.contains("one at a time") == true)
    }

    @Test func aRiskyItemOnItsOwnAsksAndWhatMacOSManagesIsRefused() async {
        let model = ScanModel()
        let task = Task { await model.stageOne(request("/Users/me/Library/Containers/com.docker.docker")) }
        for _ in 0..<10_000 where model.pendingRiskyStage == nil { await Task.yield() }
        guard model.pendingRiskyStage != nil else { Issue.record("no warning sheet"); return }
        #expect(model.pendingRiskyStage?.verdict.instead?.contains("docker system prune") == true)
        model.pendingRiskyStage?.resolve(false)
        #expect(await task.value == nil)
        #expect(await model.cleanupQueue.allItems().isEmpty)

        let refused = await model.stageOne(request("/Users/me/Library/Mobile Documents/com~apple~CloudDocs/x.pdf"))
        #expect(refused == nil)
        #expect(model.pendingRiskyStage == nil)
        #expect(model.toastMessage?.hasPrefix("macOS manages this") == true)
    }
}
