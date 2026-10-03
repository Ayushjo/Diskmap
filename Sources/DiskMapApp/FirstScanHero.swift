import AppKit
import DiskMapCore
import SwiftUI

/// First-run / unscanned / scanning hero for Overview (and shell needsScan).
struct FirstScanHero: View {
    @ObservedObject var model: ScanModel
    var pickFolder: () -> Void
    var onScanMac: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if model.isScanning {
                scanningBody
            } else {
                emptyBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DiskMapTheme.cream)
    }

    private var emptyBody: some View {
        VStack(spacing: DiskMapSpace.lg) {
            StorageMapIllustration(mode: .idle, size: 147)
                .accessibilityHidden(true)
                .padding(.bottom, DiskMapSpace.xs)

            VStack(spacing: DiskMapSpace.sm) {
                Text("Understand where your storage is going.")
                    .font(DiskMapType.title)
                    .foregroundStyle(DiskMapTheme.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Scan your Mac and DiskMap will map your files, folders, apps, and storage usage.")
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            HStack(spacing: DiskMapSpace.lg) {
                reassurance(symbol: "bolt.fill", label: "Fast")
                reassurance(symbol: "desktopcomputer", label: "Local")
                reassurance(symbol: "lock.fill", label: "Private")
            }
            .padding(.top, DiskMapSpace.xxs)

            HStack(spacing: DiskMapSpace.sm) {
                Button(action: onScanMac) {
                    Label("Scan This Mac", systemImage: "internaldrive")
                }
                .buttonStyle(InkButtonStyle())
                .accessibilityLabel("Scan This Mac")
                .keyboardShortcut(.defaultAction)

                Button("Choose Folder…", action: pickFolder)
                    .buttonStyle(InkButtonStyle(filled: false))
                    .accessibilityLabel("Choose Folder")
            }
            .padding(.top, DiskMapSpace.xs)

            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: DiskMapType.scaled(9)))
                Text("Nothing is uploaded. Your scan stays on this Mac.")
                    .font(DiskMapType.caption)
            }
            .foregroundStyle(DiskMapTheme.mutedLabel)

            featureHints
                .padding(.top, DiskMapSpace.md)
        }
        .frame(maxWidth: 620)
        .padding(.horizontal, DiskMapSpace.xl)
        .padding(.top, DiskMapSpace.xl)
        .padding(.bottom, 72)
    }

    /// Live scan view (TASK-044/046): what has been found so far, where the
    /// walk is, and how fast — instead of an indeterminate spinner and a
    /// count-based headline that said "Almost there…" at 400k items whatever
    /// the real progress was.
    private var scanningBody: some View {
        VStack(alignment: .leading, spacing: DiskMapSpace.lg) {
            HStack(alignment: .center, spacing: DiskMapSpace.md) {
                StorageMapIllustration(mode: .scanning, size: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(scanHeadline)
                        .font(.system(size: DiskMapType.scaled(20), weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                    Text(scanSubhead)
                        .font(DiskMapType.body)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            HStack(spacing: DiskMapSpace.xl) {
                liveStat(value: model.scannedCount.formatted(), label: "items")
                    .accessibilityIdentifier("scan-progress")
                liveStat(value: ByteFormat.string(model.liveProgress?.bytesFound ?? 0), label: "found")
                liveStat(
                    value: model.liveProgress.map { Int($0.itemsPerSecond).formatted() } ?? "—",
                    label: "items / s"
                )
            }

            if let folders = model.liveProgress?.topFolders, !folders.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Largest so far")
                        .font(DiskMapType.captionStrong)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                    let largest = max(folders.first?.bytes ?? 1, 1)
                    ForEach(folders.prefix(8), id: \.name) { folder in
                        HStack(spacing: 10) {
                            Text(folder.name)
                                .font(DiskMapType.small)
                                .foregroundStyle(DiskMapTheme.ink)
                                .lineLimit(1)
                                .frame(width: 150, alignment: .leading)
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(DiskMapTheme.info.opacity(0.75))
                                    .frame(width: max(2, geo.size.width * CGFloat(Double(folder.bytes) / Double(largest))))
                            }
                            .frame(height: 8)
                            Text(ByteFormat.string(folder.bytes))
                                .font(DiskMapType.caption.monospacedDigit())
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                                .frame(width: 80, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: folders)
            } else {
                ProgressView().controlSize(.small)
            }

            Button("Cancel Scan") {
                model.cancelScan()
            }
            .buttonStyle(InkButtonStyle(filled: false))
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(DiskMapSpace.xxl)
    }

    private func liveStat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: DiskMapType.scaled(18), weight: .semibold).monospacedDigit())
                .foregroundStyle(DiskMapTheme.ink)
                .contentTransition(.numericText())
            Text(label)
                .font(DiskMapType.caption)
                .foregroundStyle(DiskMapTheme.mutedLabel)
        }
        .accessibilityElement(children: .combine)
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


    private func reassurance(symbol: String, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(DiskMapType.microStrong)
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Text(label)
                .font(DiskMapType.captionMedium)
                .foregroundStyle(DiskMapTheme.mutedLabel)
        }
        .accessibilityElement(children: .combine)
    }

    private var featureHints: some View {
        HStack(spacing: DiskMapSpace.md) {
            hint(symbol: "doc.fill", title: "Biggest files")
            hint(symbol: "doc.on.doc", title: "Duplicates")
            hint(symbol: "clock", title: "Forgotten files")
            hint(symbol: "leaf", title: "Safe cleanup")
        }
        .opacity(0.85)
    }

    private func hint(symbol: String, title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(DiskMapType.micro)
            Text(title)
                .font(DiskMapType.caption)
        }
        .foregroundStyle(DiskMapTheme.mutedLabel)
    }
}
