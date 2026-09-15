import AppKit
import DiskMapCore
import SwiftUI

/// First-run / unscanned / scanning / brief-ready hero for Overview (and shell needsScan).
struct FirstScanHero: View {
    @ObservedObject var model: ScanModel
    var pickFolder: () -> Void
    var onScanMac: () -> Void
    @Binding var showReady: Bool

    var body: some View {
        Group {
            if model.isScanning {
                scanningBody
            } else if showReady, model.tree != nil {
                readyBody
            } else {
                emptyBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DiskMapTheme.cream)
    }

    private var emptyBody: some View {
        VStack(spacing: DiskMapSpace.lg) {
            StorageMapIllustration(mode: .idle, size: 128)
                .accessibilityHidden(true)
                .padding(.bottom, DiskMapSpace.xs)

            VStack(spacing: DiskMapSpace.sm) {
                Text("Understand where your storage is going.")
                    .font(.system(size: 22, weight: .semibold))
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
                    .font(.system(size: 9))
                Text("Nothing is uploaded. Your scan stays on this Mac.")
                    .font(.system(size: 11))
            }
            .foregroundStyle(DiskMapTheme.mutedLabel)

            featureHints
                .padding(.top, DiskMapSpace.md)
        }
        .frame(maxWidth: 620)
        .padding(.horizontal, DiskMapSpace.xl)
        .padding(.vertical, DiskMapSpace.xxl)
    }

    private var scanningBody: some View {
        VStack(spacing: DiskMapSpace.lg) {
            StorageMapIllustration(mode: .scanning, size: 128)
                .accessibilityHidden(true)

            VStack(spacing: DiskMapSpace.sm) {
                Text(scanHeadline)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.ink)
                Text("DiskMap is building your storage map.")
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }

            VStack(spacing: DiskMapSpace.xs) {
                ProgressView()
                    .controlSize(.regular)
                Text("\(model.scannedCount.formatted()) items scanned")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .accessibilityIdentifier("scan-progress")
                if let root = model.rootURL {
                    Text(CanonicalPath.displayPath(absolutePath: root.path))
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 420)
                }
            }

            Button("Cancel Scan") {
                model.cancelScan()
            }
            .buttonStyle(InkButtonStyle(filled: false))
            .padding(.top, DiskMapSpace.sm)
        }
        .frame(maxWidth: 560)
        .padding(DiskMapSpace.xxl)
    }

    private var readyBody: some View {
        VStack(spacing: DiskMapSpace.lg) {
            StorageMapIllustration(mode: .ready, size: 120)
                .accessibilityHidden(true)
            Text("Your storage map is ready.")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(DiskMapTheme.ink)
            Text(readySubtitle)
                .font(DiskMapType.body)
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Explore storage") {
                showReady = false
                model.destination = .overview
            }
            .buttonStyle(PrimaryCTAStyle())
        }
        .frame(maxWidth: 560)
        .padding(DiskMapSpace.xxl)
    }

    private var scanHeadline: String {
        let n = model.scannedCount
        if n < 2_000 { return "Mapping your Mac…" }
        if n < 50_000 { return "Scanning folders…" }
        if n < 400_000 { return "Analyzing files…" }
        return "Almost there…"
    }

    private var readySubtitle: String {
        let bytes: Int64 = {
            if !model.selectedTotals.isEmpty { return model.selectedTotals[0] }
            return model.analysis.scannedBytes
        }()
        let files = model.descendantFileCounts.first ?? 0
        if bytes > 0, files > 0 {
            return "DiskMap found \(ByteFormat.string(bytes)) across \(files.formatted()) files."
        }
        if bytes > 0 {
            return "DiskMap mapped \(ByteFormat.string(bytes)) on this Mac."
        }
        return "Your scan finished. Explore Overview to see where space is going."
    }

    private func reassurance(symbol: String, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Text(label)
                .font(.system(size: 11, weight: .medium))
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
                .font(.system(size: 10))
            Text(title)
                .font(.system(size: 11))
        }
        .foregroundStyle(DiskMapTheme.mutedLabel)
    }
}
