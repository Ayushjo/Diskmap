import AppKit
import DiskMapCore
import SwiftUI

/// First-run / unscanned / scanning hero for Overview (and shell needsScan).
struct FirstScanHero: View {
    @ObservedObject var model: ScanModel
    var pickFolder: () -> Void
    var onScanMac: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(DustyPreference.key) private var showDusty = true
    @State private var pointer: CGPoint?
    @State private var scanHovered = false

    var body: some View {
        Group {
            if model.isScanning {
                scanningBody
            } else {
                emptyBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DiskMapTheme.canvas)
    }

    private var emptyBody: some View {
        VStack(alignment: .leading, spacing: DiskMapSpace.lg) {
            TreemapMark()
                .frame(width: 220, height: 132)
                .accessibilityHidden(true)
                .overlay(alignment: .topLeading) {
                    if showDusty {
                        // Dusty grips the top edge above the right-hand tiles.
                        let dusty = FirstRunDusty(pointer: pointer, cheering: scanHovered)
                        dusty.offset(x: 220 * 0.75 - dusty.width / 2, y: -dusty.aboveEdge)
                    }
                }
                .padding(.top, showDusty ? 56 : 0)
                .padding(.bottom, DiskMapSpace.xs)

            VStack(alignment: .leading, spacing: DiskMapSpace.sm) {
                MonoLabel("Local  ·  Fast  ·  Private")
                Text("See where your space went.")
                    .font(.system(size: DiskMapType.scaled(30), weight: .semibold))
                    .foregroundStyle(DiskMapTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("freedisk.space maps every file and folder on this Mac, then points out what’s worth a second look. Nothing leaves your Mac.")
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440, alignment: .leading)
            }

            HStack(spacing: DiskMapSpace.xs) {
                Button("Scan This Mac", action: onScanMac)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .onHover { scanHovered = $0 }
                Button("Choose Folder…", action: pickFolder)
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityLabel("Choose Folder")
            }
            .padding(.top, DiskMapSpace.xs)

            Hairline(dashed: true)
                .padding(.top, DiskMapSpace.md)
            HStack(spacing: DiskMapSpace.lg) {
                hint("01", "Biggest files")
                hint("02", "Duplicates")
                hint("03", "Forgotten files")
                hint("04", "Safe cleanup")
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(.horizontal, DiskMapSpace.xl)
        .padding(.bottom, 56)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .coordinateSpace(name: "firstRun")
        .onContinuousHover(coordinateSpace: .named("firstRun")) { phase in
            switch phase {
            case .active(let location): pointer = location
            case .ended: pointer = nil
            }
        }
    }

    /// Live scan view (TASK-044/046): what has been found so far, where the
    /// walk is, and how fast — instead of an indeterminate spinner.
    private var scanningBody: some View {
        VStack(alignment: .leading, spacing: DiskMapSpace.lg) {
            HStack(alignment: .bottom, spacing: DiskMapSpace.md) {
                VStack(alignment: .leading, spacing: DiskMapSpace.xs) {
                    MonoLabel(scanHeadline)
                    Text(model.scannedCount.formatted() + " items")
                        .font(DiskMapType.display)
                        .foregroundStyle(DiskMapTheme.ink)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .accessibilityIdentifier("scan-progress")
                    Text(scanSubhead)
                        .font(DiskMapType.figureSmall)
                        .foregroundStyle(DiskMapTheme.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // Takes all the room Dusty doesn't; long paths shorten here
                // instead of pushing him around.
                .frame(maxWidth: .infinity, alignment: .leading)
                if showDusty {
                    ScanningDusty(line: ScanningDusty.line(phase: model.scanPhase,
                                                           currentFolder: model.liveProgress?.currentFolder,
                                                           root: (model.pendingRootURL ?? model.rootURL)?.path))
                        .transition(.opacity)
                }
            }

            FigureStrip(figures: [
                Figure(label: "Found", value: ByteFormat.string(model.liveProgress?.bytesFound ?? 0)),
                Figure(label: "Items / s", value: model.liveProgress.map { Int($0.itemsPerSecond).formatted() } ?? "—"),
            ])
            .frame(maxWidth: 360, alignment: .leading)

            VStack(alignment: .leading, spacing: DiskMapSpace.xs) {
                SectionHeader(label: "Largest so far")
                if let folders = model.liveProgress?.topFolders, !folders.isEmpty {
                    let largest = max(folders.first?.bytes ?? 1, 1)
                    ForEach(folders.prefix(8), id: \.name) { folder in
                        HStack(spacing: DiskMapSpace.sm) {
                            Text(folder.name)
                                .font(DiskMapType.body)
                                .foregroundStyle(DiskMapTheme.ink)
                                .lineLimit(1)
                                .frame(width: 150, alignment: .leading)
                            ProportionBar(fraction: Double(folder.bytes) / Double(largest),
                                          tint: DiskMapTheme.accent.opacity(0.6))
                            MonoColumn(text: ByteFormat.string(folder.bytes), width: 76)
                        }
                        .frame(height: 26)
                        .accessibilityElement(children: .combine)
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: folders)
                } else {
                    ProgressView().controlSize(.small).padding(.vertical, DiskMapSpace.xs)
                }
            }

            Button("Cancel Scan") { model.cancelScan() }
                .buttonStyle(SecondaryButtonStyle())
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(DiskMapSpace.xxl)
    }

    private var scanHeadline: String {
        switch model.scanPhase {
        case .summarizing: return "Summarizing…"
        case .checkingChanges: return "Checking what changed…"
        default:
            guard let root = model.pendingRootURL ?? model.rootURL else { return "Scanning your Mac…" }
            if root.path == "/" { return "Scanning your Mac…" }
            if CanonicalPath.displayPath(absolutePath: root.path) == "~" { return "Scanning your home folder…" }
            return "Scanning “\(root.lastPathComponent)”…"
        }
    }

    private var scanSubhead: String {
        if model.scanPhase == .summarizing { return "Sizing folders and preparing the first screen." }
        if model.scanPhase == .checkingChanges { return "Starting from your last scan and re-reading only what macOS reports as changed." }
        guard let folder = model.liveProgress?.currentFolder, !folder.isEmpty else { return "Reading folder sizes." }
        return CanonicalPath.displayPath(absolutePath: folder)
    }


    private func hint(_ number: String, _ title: String) -> some View {
        HStack(spacing: 6) {
            Text(number)
                .font(DiskMapType.label)
                .foregroundStyle(DiskMapTheme.ink3)
            Text(title)
                .font(DiskMapType.secondary)
                .foregroundStyle(DiskMapTheme.ink2)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The launch site's treemap: soft gradient tiles from the data palette.
private struct TreemapMark: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height, gap: CGFloat = 4
            ZStack(alignment: .topLeading) {
                tile(0, x: 0, y: 0, w: w * 0.5 - gap / 2, h: h)
                tile(1, x: w * 0.5 + gap / 2, y: 0, w: w * 0.5 - gap / 2, h: h * 0.55 - gap / 2)
                tile(3, x: w * 0.5 + gap / 2, y: h * 0.55 + gap / 2, w: w * 0.28 - gap, h: h * 0.45 - gap / 2)
                tile(4, x: w * 0.78 + gap / 2, y: h * 0.55 + gap / 2, w: w * 0.22 - gap / 2, h: h * 0.25 - gap / 2)
                tile(5, x: w * 0.78 + gap / 2, y: h * 0.80 + gap / 2, w: w * 0.22 - gap / 2, h: h * 0.20 - gap / 2)
            }
        }
    }

    private func tile(_ index: Int, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> some View {
        let color = DiskMapTheme.data(index)
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(LinearGradient(colors: [color.opacity(0.75), color.opacity(0.95)], startPoint: .top, endPoint: .bottom))
            .frame(width: max(0, w), height: max(0, h))
            .offset(x: x, y: y)
    }
}
