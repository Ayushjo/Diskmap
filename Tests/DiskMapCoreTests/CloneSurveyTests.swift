import Foundation
import Testing
@testable import DiskMapCore

/// Sampling for cloned copies after a scan that didn't read clone facts.
/// Real `cp -c` clones on the (APFS) temp volume, as in CloneScanTests.
@Suite("Clone survey")
struct CloneSurveyTests {

    final class Fixture {
        let root: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("diskmap-clonesurvey-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        func write(_ rel: String, seed: UInt8) throws {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: seed, count: 64 * 1024).write(to: url)
        }

        func clone(_ source: String, _ rel: String) throws {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let cp = Process()
            cp.executableURL = URL(fileURLWithPath: "/bin/cp")
            cp.arguments = ["-c", root.appendingPathComponent(source).path, url.path]
            try cp.run()
            cp.waitUntilExit()
            #expect(cp.terminationStatus == 0)
        }

        /// media/chat: one original and 9 clones. plain: 10 distinct files.
        func build() throws {
            try write("media/chat/0.bin", seed: 1)
            for k in 1..<10 { try clone("media/chat/0.bin", "media/chat/\(k).bin") }
            for k in 0..<10 { try write("plain/\(k).bin", seed: UInt8(10 + k)) }
        }
    }

    private static func node(_ tree: FileTree, _ name: String) -> Int32? {
        (0..<tree.count).first { tree.name(of: Int32($0)) == name }.map(Int32.init)
    }

    @Test func findsTheClonedFolderAndNotThePlainOne() async throws {
        let f = try Fixture()
        try f.build()
        let tree = await ScanEngine().scan(root: f.root, sharing: .off).tree
        let totals = tree.rollUpBoth().allocated
        let survey = CloneSurvey.run(tree: tree, root: f.root, allocated: totals, points: 400)
        #expect(survey.filesChecked == 20)

        let chat = try #require(Self.node(tree, "chat"))
        let plain = try #require(Self.node(tree, "plain"))
        // 10 copies of one file: 9 of them are the same blocks again.
        let shared = try #require(survey.sharedBytes(of: chat, total: totals[Int(chat)], minimumBytes: 0))
        let expected = Double(totals[Int(chat)]) * 0.9
        #expect(abs(Double(shared) - expected) <= expected * 0.1, "\(shared) vs \(expected)")
        #expect(survey.sharedBytes(of: plain, total: totals[Int(plain)], minimumBytes: 0) == nil)
        #expect(survey.estimates[plain] == nil)

        // The answer is the clone folder itself, not the folders above it.
        let folders = survey.inflatedFolders(tree: tree, totals: totals, minimumBytes: 0)
        #expect(folders.map(\.id) == [chat])
    }

    @Test func nothingToSayWhenTheScanReadCloneFacts() async throws {
        let f = try Fixture()
        try f.build()
        let tree = await ScanEngine().scan(root: f.root, sharing: .refcount).tree
        let survey = CloneSurvey.run(tree: tree, root: f.root, allocated: tree.rollUpBoth().allocated)
        #expect(survey == .empty)
    }

    @Test func sampleIsByteWeightedAndRepeatable() async throws {
        let f = try Fixture()
        try f.build()
        let tree = await ScanEngine().scan(root: f.root, sharing: .off).tree
        let totals = tree.rollUpBoth().allocated
        // Every file is reported as one of two copies: half of everything is shared.
        let half = CloneSurvey.sample(tree: tree, root: f.root, allocated: totals, points: 1000) { _ in 2 }
        let again = CloneSurvey.sample(tree: tree, root: f.root, allocated: totals, points: 1000) { _ in 2 }
        #expect(half == again)
        let rootShared = try #require(half.estimates[0]).sharedBytes
        #expect(abs(Double(rootShared) - Double(totals[0]) / 2) <= Double(totals[0]) * 0.02)
        #expect(abs((half.pointsByFolder[0] ?? 0) - 1000) <= 1, "integer step rounds down")
        // Too few points in a folder: no claim.
        let sparse = CloneSurvey.sample(tree: tree, root: f.root, allocated: totals, points: 4) { _ in 2 }
        let chat = try #require(Self.node(tree, "chat"))
        #expect(sparse.sharedBytes(of: chat, total: totals[Int(chat)], minimumBytes: 0) == nil)
        // An unreadable file counts as unshared.
        let none = CloneSurvey.sample(tree: tree, root: f.root, allocated: totals, points: 100) { _ in nil }
        #expect(none.estimates.isEmpty)
    }
}
