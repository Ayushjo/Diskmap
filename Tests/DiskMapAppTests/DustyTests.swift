import CoreGraphics
import Foundation
import Testing
@testable import DiskMapApp

/// Dusty, the mascot: the generated art decodes whole, and the parts that move
/// can move (design/mascot/export_app.py → Kit/DustyArt.swift).
@Suite("Dusty")
struct DustyTests {
    private let library = DustyLibrary.shared

    @Test func everyPoseDecodesWithItsShapes() {
        for pose in DustyPose.allCases {
            let ops = library.poses[pose]?.ops ?? []
            #expect(ops.count >= 25, "\(pose) has \(ops.count) shapes")
            #expect(ops.allSatisfy { !$0.path.isEmpty }, "\(pose) has an empty shape")
            // Every shape sits on Dusty's 240-unit grid (a little overflow for sparkles and marks).
            for op in ops where op.clips.isEmpty {
                let box = op.path.boundingRect
                #expect(box.minX > -20 && box.maxX < 260 && box.minY > -20 && box.maxY < 260, "\(pose) shape at \(box)")
            }
        }
    }

    @Test func shadingIsClippedToTheBody() {
        // Without the clip, the lower-body shade spills out as a lavender blob.
        for pose in DustyPose.allCases {
            let clipped = library.poses[pose]?.ops.filter { !$0.clips.isEmpty } ?? []
            #expect(!clipped.isEmpty, "\(pose) has no clipped shading")
        }
        // Peeking poses also hide below the ledge their paws grip.
        for pose in DustyPose.allCases where pose.isPeek {
            let ops = library.poses[pose]?.ops ?? []
            #expect(ops.contains { $0.clips.count >= 2 }, "\(pose) isn't clipped at the ledge")
            let paws = ops.filter { $0.role == .pawL || $0.role == .pawR }
            #expect(!paws.isEmpty && paws.allSatisfy { $0.clips.isEmpty }, "\(pose)'s paws should sit over the ledge")
        }
    }

    @Test func theMovingPartsHavePivots() {
        for pose in DustyPose.allCases {
            let ops = library.poses[pose]?.ops ?? []
            #expect(ops.contains { $0.role == .earL } && ops.contains { $0.role == .earR }, "\(pose) is missing an ear")
        }
        // Open, dot eyes blink around their own centres.
        for pose in [DustyPose.hello, .curious, .oops, .focus, .peekHello, .smallHello] {
            let eyes = library.poses[pose]?.ops.filter { $0.role == .eye } ?? []
            #expect(eyes.count >= 2, "\(pose) has no eyes to blink")
            let centres = Set(eyes.map { "\(Int($0.pivot.x.rounded())),\(Int($0.pivot.y.rounded()))" })
            #expect(centres.count == 2, "\(pose) blinks around \(centres.count) centres, not one per eye")
        }
        // The broom swings from the paw that holds it.
        let broom = library.broom.ops.filter { $0.role == .broom }
        #expect(!broom.isEmpty)
        #expect(broom.allSatisfy { $0.pivot == library.grip })
        // Every speck knows where it flies when Dusty shakes.
        let specks = library.specks.ops.filter { $0.role == .speck }
        #expect(specks.count >= 12)
        #expect(specks.allSatisfy { $0.fly != .zero })
    }

    @Test func scanningLineNamesTheTopLevelFolder() {
        #expect(ScanningDusty.line(phase: .walking, currentFolder: "/Users/a/Library/Caches/x", root: "/Users/a") == "Sniffing through Library…")
        #expect(ScanningDusty.line(phase: .walking, currentFolder: "/Users/a", root: "/Users/a") == "Sniffing through a…")
        #expect(ScanningDusty.line(phase: .walking, currentFolder: nil, root: "/") == "Getting started…")
        #expect(ScanningDusty.line(phase: .walking, currentFolder: "/Applications/Xcode.app", root: "/") == "Sniffing through Applications…")
        // Quiet while the headline already says what's happening.
        #expect(ScanningDusty.line(phase: .checkingChanges, currentFolder: "/x", root: "/").isEmpty)
        #expect(ScanningDusty.line(phase: .summarizing, currentFolder: "/x", root: "/").isEmpty)
    }

    @Test func peekPosesEndAtTheLedge() {
        for pose in DustyPose.allCases {
            #expect(pose.viewBox.height == (pose.isPeek ? 184 : 216))
            #expect(pose.height(forWidth: 240) == pose.viewBox.height)
        }
        #expect(library.edge == 172)
    }
}
