import AppKit
import DiskMapCore
import SwiftUI

// The few places Dusty appears beyond empty states (design/mascot rules: calm,
// rare, one per screen, never on a step that removes files, optional).

// MARK: - First run: peeking over the treemap

/// Dusty peeking over the top edge of the first-run treemap. He watches the
/// pointer, cheers while it's on Scan This Mac, and hops when clicked.
struct FirstRunDusty: View {
    /// The pointer, in the hero's "firstRun" coordinate space (nil = away).
    var pointer: CGPoint?
    var cheering: Bool
    var width: CGFloat = 78
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dustyStill) private var still
    private var reduceMotion: Bool { systemReduceMotion || still }
    @State private var eyes: CGPoint = .zero
    @State private var risen = false
    @State private var hopping = false

    private var scale: CGFloat { width / 240 }
    /// How far Dusty rises above the edge he grips.
    var aboveEdge: CGFloat { DustyLibrary.shared.edge * scale }

    var body: some View {
        let height = DustyPose.peekHello.height(forWidth: width)
        Dusty(pose: cheering || hopping ? .peekHappy : .peekHello, width: width, gaze: gaze)
            .offset(y: (risen || reduceMotion ? 0 : aboveEdge * 0.7) - (hopping ? 7 : 0))
            // Anything below the paws stays behind the treemap while he rises.
            .frame(width: width, height: height, alignment: .top)
            .mask(alignment: .bottom) { Rectangle().frame(width: width * 3, height: height * 3) }
            .background(GeometryReader { geo in
                Color.clear.onAppear { eyes = CGPoint(x: geo.frame(in: .named("firstRun")).midX, y: geo.frame(in: .named("firstRun")).minY + height * 0.82) }
                    .onChange(of: geo.frame(in: .named("firstRun"))) { _, f in eyes = CGPoint(x: f.midX, y: f.minY + height * 0.82) }
            })
            .contentShape(Rectangle())
            .onTapGesture { hop() }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.spring(response: 0.55, dampingFraction: 0.62).delay(0.35)) { risen = true }
            }
            .accessibilityHidden(true)
    }

    private var gaze: CGSize? {
        guard let pointer else { return nil }
        let dx = pointer.x - eyes.x, dy = pointer.y - eyes.y
        let d = max(1, hypot(dx, dy)), reach = min(1, d / 220)
        return CGSize(width: dx / d * reach, height: dy / d * reach)
    }

    private func hop() {
        guard !hopping else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { hopping = true }
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { hopping = false }
        }
    }
}

// MARK: - Scanning: sweeping beside the counter

/// Dusty sweeping while a scan runs, with what he's "sniffing through".
struct ScanningDusty: View {
    var line: String
    var width: CGFloat = 84
    /// A fixed column, so Dusty stays put whatever the path or line length.
    static let columnWidth: CGFloat = 210

    var body: some View {
        VStack(spacing: 6) {
            Dusty(pose: .focus, width: width, sweeping: true)
            // Quiet while the headline already says what's happening; the line's
            // height is kept either way so he doesn't bob when it comes and goes.
            Text(line.isEmpty ? " " : line)
                .font(DiskMapType.secondary)
                .foregroundStyle(DiskMapTheme.ink3)
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(line.isEmpty ? 0 : 1)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.25), value: line)
        }
        .frame(width: Self.columnWidth)
        .accessibilityHidden(true)
    }

    /// "Sniffing through Library…": the top-level folder under the scan root.
    static func line(phase: ScanModel.ScanPhase?, currentFolder: String?, root: String?) -> String {
        switch phase {
        case .summarizing?, .checkingChanges?: return ""
        default: break
        }
        guard let folder = currentFolder, !folder.isEmpty else { return "Getting started…" }
        var relative = folder
        if let root, folder.hasPrefix(root) { relative = String(folder.dropFirst(root.count)) }
        let first = relative.split(separator: "/").first.map(String.init)
            ?? root.map { ($0 as NSString).lastPathComponent } ?? folder
        return "Sniffing through \(first.isEmpty ? "your Mac" : first)…"
    }
}

// MARK: - After Move to Trash: the success moment

/// Shown in Cleanup right after items went to the Trash (never before):
/// Dusty shakes the dust off, then stands proud.
struct CleanupSuccessView: View {
    var count: Int
    /// The commit's own last line, e.g. "24.2 GB is freed when you empty the Trash."
    var freedLine: String
    var details: [String]
    var onPutBack: () -> Void
    var onDone: () -> Void
    @AppStorage(DustyPreference.key) private var showDusty = true
    @State private var showDetails = false

    var body: some View {
        VStack(spacing: DiskMapSpace.sm) {
            if showDusty {
                DustyShakeOff(width: DiskMapType.scaled(104))
                    .padding(.bottom, DiskMapSpace.xs)
            } else {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: DiskMapType.scaled(22), weight: .regular))
                    .foregroundStyle(DiskMapTheme.accent)
                    .accessibilityHidden(true)
            }
            Text("\(countLabel(count, "item")) moved to the Trash")
                .font(DiskMapType.heading)
                .foregroundStyle(DiskMapTheme.ink)
            if !freedLine.isEmpty {
                Text(freedLine)
                    .font(DiskMapType.figure)
                    .foregroundStyle(DiskMapTheme.ink2)
                    .multilineTextAlignment(.center)
            }
            Text("Changed your mind? Put Back returns them exactly where they were.")
                .font(DiskMapType.secondary)
                .foregroundStyle(DiskMapTheme.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: DiskMapSpace.xs) {
                Button("Put Back", action: onPutBack)
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Move them from the Trash back where they were. Nothing that is there now is replaced.")
                Button("Done", action: onDone)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, DiskMapSpace.xs)
            if !details.isEmpty {
                Button(showDetails ? "Hide details" : "Show what moved") {
                    withAnimation(.easeOut(duration: 0.15)) { showDetails.toggle() }
                }
                .buttonStyle(LinkButtonStyle())
                .font(DiskMapType.secondary)
                .padding(.top, DiskMapSpace.xs)
                if showDetails {
                    ScrollView {
                        Text(details.joined(separator: "\n"))
                            .font(DiskMapType.figureSmall)
                            .foregroundStyle(DiskMapTheme.ink2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: 520, maxHeight: 120)
                }
            }
        }
        .padding(DiskMapSpace.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// Dusty shaking the dust off: specks fly, a wiggle, then a proud pose.
struct DustyShakeOff: View {
    var width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dustyStill) private var still
    private var reduceMotion: Bool { systemReduceMotion || still }
    @State private var start: Date?
    @State private var done = false

    var body: some View {
        Group {
            if done || reduceMotion {
                DustyArrival(pose: .proud, width: width)
            } else {
                // Only for the first ~0.9 s.
                TimelineView(.animation) { timeline in
                    let t = start.map { timeline.date.timeIntervalSince($0) } ?? 0
                    let wiggle = t < 0.75 ? sin(t * 2 * .pi * 6.5) * 9 * (1 - t / 0.75) : 0
                    let fly = min(1, max(0, (t - 0.12) / 0.6))
                    Dusty(pose: .shake, width: width, specks: 1, specksFly: fly, lively: false)
                        .rotationEffect(.degrees(wiggle), anchor: .bottom)
                }
            }
        }
        .frame(width: width, height: DustyPose.proud.height(forWidth: width))
        .task {
            guard !reduceMotion else { return }
            start = Date()
            try? await Task.sleep(nanoseconds: 900_000_000)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { done = true }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - About

struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About freedisk.space") { openWindow(id: AboutView.windowID) }
        }
    }
}

/// freedisk.space ▸ About: Dusty with his broom, the name and the version.
struct AboutView: View {
    static let windowID = "about"
    @AppStorage(DustyPreference.key) private var showDusty = true

    var body: some View {
        VStack(spacing: DiskMapSpace.sm) {
            if showDusty {
                Dusty(pose: .hello, width: 132, broom: true)
                    .padding(.bottom, DiskMapSpace.xs)
            }
            DiskMapWordmark()
                .frame(height: 26)
            Text(Self.version)
                .font(DiskMapType.figureSmall)
                .foregroundStyle(DiskMapTheme.ink3)
                .textSelection(.enabled)
            Text("See where your space went. Nothing leaves your Mac.")
                .font(DiskMapType.secondary)
                .foregroundStyle(DiskMapTheme.ink2)
                .multilineTextAlignment(.center)
                .padding(.top, DiskMapSpace.xs)
            MonoLabel("Local  ·  Fast  ·  Private")
                .padding(.top, DiskMapSpace.xs)
            Text("© 2026 freedisk.space · Open source")
                .font(DiskMapType.figureSmall)
                .foregroundStyle(DiskMapTheme.ink3)
                .padding(.top, DiskMapSpace.sm)
        }
        .padding(.horizontal, 36)
        .padding(.top, 28)
        .padding(.bottom, 26)
        .frame(width: 340)
        .background(DiskMapTheme.canvas)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "Development build" }
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(short) (\($0))" } ?? "Version \(short)"
    }
}
