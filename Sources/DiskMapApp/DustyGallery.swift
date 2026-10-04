import AppKit
import DiskMapCore
import SwiftUI

/// Developer tool (`--dusty-gallery`, with the snapshot harness): every place
/// Dusty appears, at its real size, as one image per appearance.
struct DustyGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            section("Poses") {
                HStack(alignment: .bottom, spacing: 18) {
                    ForEach([DustyPose.hello, .happy, .proud, .curious, .sleepy, .oops, .focus, .shake], id: \.self) { pose in
                        labelled(pose.rawValue) { Dusty(pose: pose, width: 96) }
                    }
                }
                HStack(alignment: .bottom, spacing: 18) {
                    ForEach([DustyPose.smallHello, .smallCurious, .smallOops, .smallDusty], id: \.self) { pose in
                        labelled("\(pose.rawValue) 40/26/18") {
                            HStack(alignment: .bottom, spacing: 8) {
                                Dusty(pose: pose, width: 40); Dusty(pose: pose, width: 26); Dusty(pose: pose, width: 18)
                            }
                        }
                    }
                    labelled("broom") { Dusty(pose: .hello, width: 96, broom: true) }
                    labelled("specks") { Dusty(pose: .shake, width: 96, specks: 1) }
                }
            }
            HStack(alignment: .top, spacing: 28) {
                section("First run") {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 56)
                        RoundedRectangle(cornerRadius: 6).fill(DiskMapTheme.data(1).opacity(0.85))
                            .frame(width: 220, height: 132)
                            .overlay(alignment: .topLeading) {
                                let dusty = FirstRunDusty(pointer: CGPoint(x: 40, y: 200), cheering: false)
                                dusty.offset(x: 220 * 0.75 - dusty.width / 2, y: -dusty.aboveEdge)
                            }
                    }
                }
                section("Scanning") {
                    HStack(alignment: .bottom, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            MonoLabel("Scanning your Mac…")
                            Text("1,284,302 items").font(DiskMapType.display).foregroundStyle(DiskMapTheme.ink)
                            Text("~/Library/Caches/com.apple.Safari").font(DiskMapType.figureSmall).foregroundStyle(DiskMapTheme.ink3)
                        }
                        ScanningDusty(line: ScanningDusty.line(phase: .walking, currentFolder: "/Users/alex/Library/Caches", root: "/Users/alex"))
                    }
                }
                section("Menu bar panel") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { MonoLabel("MACINTOSH HD"); Spacer(); Dusty(pose: .smallHello, width: 26) }
                        HStack { MonoLabel("MACINTOSH HD"); Spacer(); Dusty(pose: .smallDusty, width: 26) }
                    }
                    .frame(width: 240)
                }
            }
            HStack(alignment: .top, spacing: 20) {
                frame("Safe to Review", 300) { DiskMapEmptyState(symbol: "leaf", title: "Nothing to clean up", message: "freedisk.space didn’t find high-confidence cleanup candidates in this scan.", dusty: .proud) }
                frame("Duplicates", 300) { DiskMapEmptyState(symbol: "doc.on.doc", title: "No duplicates found", message: "Nothing in this scan is stored twice.", primaryTitle: "Search Again", primaryAction: {}, dusty: .happy) }
                frame("Developer Storage", 300) { DiskMapEmptyState(symbol: "folder", title: "No projects found", message: "No project-scoped folders such as node_modules, Pods or .venv in this scan.", dusty: .curious) }
            }
            HStack(alignment: .top, spacing: 20) {
                frame("Snapshots", 460, height: 120) {
                    HStack(spacing: DiskMapSpace.md) {
                        DustyArrival(pose: .sleepy, width: 76)
                        Text("Save a snapshot now; compare it with a later scan to see what grew or shrank.")
                            .font(DiskMapType.body).foregroundStyle(DiskMapTheme.ink2)
                    }
                    .padding(16)
                }
                frame("Overview notice", 460, height: 120) {
                    DiskMapNoticeBanner(symbol: "lock", tint: DiskMapTheme.review, title: "3 folders couldn’t be read",
                                        detail: "Totals are missing whatever they hold. Grant Full Disk Access, then rescan.",
                                        actionTitle: "Grant access", action: {}, dusty: .smallOops)
                        .padding(16)
                }
            }
            HStack(alignment: .top, spacing: 20) {
                frame("Cleanup, after Move to Trash", 560, height: 360) {
                    CleanupSuccessView(count: 3, freedLine: "24.2 GB is freed when you empty the Trash.",
                                       details: ["Moved to Trash: ~/Installers (7.8 GB)"], onPutBack: {}, onDone: {})
                }
                frame("Explain my storage", 380, height: 90) {
                    HStack(spacing: DiskMapSpace.sm) {
                        Dusty(pose: .smallCurious, width: 40)
                        VStack(alignment: .leading, spacing: 4) {
                            MonoLabel("From your last scan")
                            Text("Explain my storage").font(DiskMapType.title).foregroundStyle(DiskMapTheme.ink)
                        }
                        Spacer()
                    }
                    .padding(16)
                }
                frame("About", 340, height: 420) { AboutView() }
            }
        }
        .padding(32)
        .background(DiskMapTheme.canvas)
        .environment(\.dustyStill, true)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MonoLabel(title)
            content()
        }
    }

    private func labelled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 6) {
            content()
            Text(title).font(DiskMapType.figureSmall).foregroundStyle(DiskMapTheme.ink3)
        }
    }

    private func frame<C: View>(_ title: String, _ width: CGFloat, height: CGFloat = 300, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MonoLabel(title)
            content()
                .frame(width: width, height: height)
                .background(DiskMapTheme.canvas)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(DiskMapTheme.line, lineWidth: 1))
        }
    }

    @MainActor
    static func write(to url: URL, dark: Bool) {
        let renderer = ImageRenderer(content: DustyGallery().environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
