import AppKit
import DiskMapCore
import QuickLookThumbnailing
import Quartz
import SwiftUI

// MARK: - Spacing scale (4…32)

enum DiskMapSpace {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32

    /// Default page padding.
    static let page: CGFloat = 20
    /// Compact list row height target.
    static let rowMin: CGFloat = 44
}

// MARK: - Shared compact controls

struct DiskMapSearchField: View {
    var placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: DiskMapSpace.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DiskMapType.body)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: DiskMapMetric.searchHeight)
        .background(
            RoundedRectangle(cornerRadius: DiskMapRadius.control, style: .continuous)
                .fill(DiskMapTheme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: DiskMapRadius.control, style: .continuous)
                        .stroke(focused ? DiskMapTheme.focus.opacity(0.75) : DiskMapTheme.cardStroke, lineWidth: 1)
                )
        )
        .shadow(color: focused ? DiskMapTheme.focus.opacity(0.10) : .clear, radius: 3)
    }
}

struct DiskMapMenu<Option: Hashable>: View {
    var label: String
    var options: [Option]
    @Binding var selection: Option
    var title: (Option) -> String
    var width: CGFloat? = nil

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(title(option), systemImage: "checkmark")
                    } else {
                        Text(title(option))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(label.isEmpty ? title(selection) : "\(label): \(title(selection))")
                    .lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(DiskMapTheme.ink)
            .padding(.horizontal, 10)
            .frame(width: width, height: DiskMapMetric.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: DiskMapRadius.control, style: .continuous)
                    .fill(DiskMapTheme.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: DiskMapRadius.control, style: .continuous)
                            .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: width == nil, vertical: true)
    }
}

struct DiskMapColumnSpacer: View {
    var width: CGFloat = DiskMapMetric.checkboxColumnWidth
    var body: some View { Color.clear.frame(width: width, height: 1) }
}

// MARK: - Classification badge (color + text — never color alone)

struct ClassificationBadge: View {
    enum Kind {
        case safe
        case review
        case protected
        case unknown
        case custom(title: String, tint: Color)

        var title: String {
            switch self {
            case .safe: return "Generally safe"
            case .review: return "Review first"
            case .protected: return "Protected"
            case .unknown: return "Unknown"
            case .custom(let title, _): return title
            }
        }

        var tint: Color {
            switch self {
            case .safe: return DiskMapTheme.safe
            case .review: return DiskMapTheme.review
            case .protected: return DiskMapTheme.danger
            case .unknown: return DiskMapTheme.mutedLabel
            case .custom(_, let tint): return tint
            }
        }

        static func from(safety: SafetyLevel) -> Kind {
            switch safety {
            case .safe: return .safe
            case .review: return .review
            case .protected: return .protected
            }
        }
    }

    var kind: Kind

    var body: some View {
        Text(kind.title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(kind.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(kind.tint.opacity(0.14)))
            .accessibilityLabel(kind.title)
    }
}

// MARK: - Empty state

struct DiskMapEmptyState: View {
    var symbol: String
    var title: String
    var message: String
    var primaryTitle: String? = nil
    var primaryAction: (() -> Void)? = nil
    var secondaryTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: DiskMapSpace.sm) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DiskMapTheme.ink)
            Text(message)
                .font(DiskMapType.body)
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: DiskMapSpace.xs) {
                if let primaryTitle, let primaryAction {
                    Button(primaryTitle, action: primaryAction)
                        .buttonStyle(InkButtonStyle())
                }
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                        .buttonStyle(InkButtonStyle(filled: false))
                }
            }
            .padding(.top, DiskMapSpace.xs)
        }
        .padding(DiskMapSpace.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Loading / long-running operation state

struct DiskMapLoadingState: View {
    var title: String
    var detail: String? = nil
    var fraction: Double? = nil // nil = indeterminate
    var processed: Int? = nil
    var total: Int? = nil
    var onCancel: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: DiskMapSpace.md) {
            if let fraction {
                ProgressView(value: min(max(fraction, 0), 1))
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 320)
            } else {
                ProgressView()
                    .controlSize(.regular)
            }
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DiskMapTheme.ink)
            if let detail {
                Text(detail)
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            if let processed, let total, total > 0 {
                Text("\(processed.formatted()) of \(total.formatted()) size groups")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
            if let onCancel {
                Button("Cancel", action: onCancel)
                    .buttonStyle(InkButtonStyle(filled: false))
                    .padding(.top, DiskMapSpace.xs)
            }
        }
        .padding(DiskMapSpace.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

// MARK: - Selection footer toolbar

struct SelectionToolbar: View {
    var selectedCount: Int
    var selectedBytes: Int64
    var primaryTitle: String = "Add to Cleanup"
    var primaryEnabled: Bool = true
    var onPrimary: () -> Void
    var onClear: () -> Void
    var onReveal: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: DiskMapSpace.xs) {
            Text("\(selectedCount) selected · \(ByteFormat.string(selectedBytes))")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DiskMapTheme.ink)
            Spacer()
            Button("Clear", action: onClear)
                .buttonStyle(InkButtonStyle(filled: false))
            if let onReveal {
                Button("Reveal", action: onReveal)
                    .buttonStyle(InkButtonStyle(filled: false))
            }
            Button(primaryTitle, action: onPrimary)
                .buttonStyle(PrimaryCTAStyle())
                .disabled(!primaryEnabled || selectedCount == 0)
        }
        .padding(.horizontal, DiskMapSpace.lg)
        .padding(.vertical, DiskMapSpace.sm)
        .background(DiskMapTheme.cardFill)
        .overlay(alignment: .top) { Divider().overlay(DiskMapTheme.cardStroke) }
    }
}

// MARK: - Compact why / safety cards for inspectors

struct WhyCard: View {
    var title: String = "Why is this large?"
    var bodyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: DiskMapSpace.xs) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Text(bodyText)
                .font(.system(size: 12))
                .foregroundStyle(DiskMapTheme.ink.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DiskMapSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DiskMapTheme.info.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DiskMapTheme.info.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

struct SafetyCard: View {
    var assessment: SafetyAssessment

    var body: some View {
        VStack(alignment: .leading, spacing: DiskMapSpace.xs) {
            HStack {
                Text("Classification")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                Spacer()
                ClassificationBadge(kind: .from(safety: assessment.level))
            }
            Text(assessment.reason)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            if !assessment.consequences.isEmpty {
                Text(assessment.consequences)
                    .font(.system(size: 11))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DiskMapSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DiskMapTheme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                )
        )
    }
}


// MARK: - Layout helpers

private struct DiskMapContentWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1280
}

extension EnvironmentValues {
    var diskMapContentWidth: CGFloat {
        get { self[DiskMapContentWidthKey.self] }
        set { self[DiskMapContentWidthKey.self] = newValue }
    }
}

enum DiskMapLayout {
    static func inspectorWidth(for windowWidth: CGFloat) -> CGFloat {
        windowWidth >= 1450 ? 310 : 280
    }

    static func showsSideInspector(for windowWidth: CGFloat) -> Bool {
        windowWidth >= 1200
    }
}

struct AdaptiveInspectorSplit<Main: View, Inspector: View>: View {
    var windowWidth: CGFloat
    var inspectionToken: String?
    var mainContent: Main
    var inspectorContent: Inspector
    @State private var showsDrawer = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(windowWidth: CGFloat, inspectionToken: String? = nil, main: Main, inspector: Inspector) {
        self.windowWidth = windowWidth
        self.inspectionToken = inspectionToken
        self.mainContent = main
        self.inspectorContent = inspector
    }

    var body: some View {
        Group {
            if DiskMapLayout.showsSideInspector(for: windowWidth) {
                HStack(spacing: 0) {
                    mainContent
                    Divider().overlay(DiskMapTheme.cardStroke)
                    inspectorContent
                        .frame(width: DiskMapLayout.inspectorWidth(for: windowWidth))
                }
            } else {
                ZStack(alignment: .trailing) {
                    VStack(spacing: 0) {
                        HStack {
                            Spacer(minLength: 0)
                            if !showsDrawer {
                                Button {
                                    showsDrawer = true
                                } label: {
                                    Label("Inspector", systemImage: "sidebar.right")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .buttonStyle(InkButtonStyle(filled: false))
                                .help("Show Inspector")
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 42)
                        .background(DiskMapTheme.cream)
                        Divider().overlay(DiskMapTheme.cardStroke)
                        mainContent
                    }
                    if showsDrawer {
                        Color.black.opacity(0.12)
                            .ignoresSafeArea()
                            .onTapGesture { showsDrawer = false }
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Divider().overlay(DiskMapTheme.cardStroke)
                            inspectorContent
                                .frame(width: min(310, max(270, windowWidth * 0.34)))
                                .background(DiskMapTheme.inspectorFill)
                        }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .onExitCommand { showsDrawer = false }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: showsDrawer)
            }
        }
        .onChange(of: inspectionToken) { oldValue, newValue in
            guard newValue != nil, newValue != oldValue,
                  !DiskMapLayout.showsSideInspector(for: windowWidth) else { return }
            showsDrawer = true
        }
    }
}

// MARK: - Page header

struct DiskMapPageHeader: View {
    var title: String
    var subtitle: String
    var symbol: String? = nil
    var symbolTint: Color = DiskMapTheme.info

    var body: some View {
        HStack(alignment: .top, spacing: DiskMapSpace.sm) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(symbolTint)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(symbolTint.opacity(0.10)))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: DiskMapSpace.xxs) {
                Text(title)
                    .font(DiskMapType.title)
                    .foregroundStyle(DiskMapTheme.ink)
                Text(subtitle)
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DiskMapSpace.xs)
        }
    }
}

// MARK: - File identity

struct FileIdentityIcon: View {
    let url: URL
    var kind: FileKind? = nil
    var size: CGFloat = 34

    private var resolvedKind: FileKind {
        kind ?? FileKind.classify(fileName: url.lastPathComponent, path: url.path)
    }

    var body: some View {
        Group {
            if resolvedKind == .video, isLocallyPreviewable {
                MediaThumbnailView(
                    url: url,
                    size: CGSize(width: size, height: size),
                    fallbackSymbol: resolvedKind.symbolName
                )
            } else if resolvedKind == .application || url.pathExtension.lowercased() == "app" {
                Image(nsImage: WorkspaceIconCache.icon(for: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(2)
            } else {
                Image(systemName: resolvedKind.symbolName)
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(identityTint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(identityTint.opacity(0.10))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: max(7, size * 0.23), style: .continuous))
        .accessibilityHidden(true)
    }

    private var isLocallyPreviewable: Bool {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values?.isUbiquitousItem == true else { return true }
        return values?.ubiquitousItemDownloadingStatus == .current
            || values?.ubiquitousItemDownloadingStatus == .downloaded
    }

    private var identityTint: Color {
        switch resolvedKind {
        case .video: return DiskMapTheme.developer
        case .diskImage: return DiskMapTheme.info
        case .archive: return DiskMapTheme.review
        case .application: return DiskMapTheme.folderPastels[4]
        case .document: return DiskMapTheme.folderPastels[5]
        case .virtualDisk: return DiskMapTheme.developer
        case .deviceBackup: return DiskMapTheme.safe
        case .database: return DiskMapTheme.folderPastels[5]
        case .other: return DiskMapTheme.mutedLabel
        }
    }
}

@MainActor
private enum WorkspaceIconCache {
    static let cache = NSCache<NSString, NSImage>()

    static func icon(for path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}

// MARK: - Lazy media / file thumbnail (Quick Look)


struct MediaThumbnailView: View {
    let url: URL
    var size: CGSize = CGSize(width: 160, height: 90)
    var fallbackSymbol: String = "doc"
    var showPlayBadge: Bool = false
    var allowsPreview: Bool = true

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DiskMapTheme.navSelected)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: min(size.height, size.width) * 0.28))
                    .foregroundStyle(DiskMapTheme.info)
            }
            if showPlayBadge {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.95))
                    .shadow(radius: 2)
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: url.path) { await load() }
    }

    @MainActor
    private func load() async {
        failed = false
        image = nil
        guard allowsPreview else {
            image = NSWorkspace.shared.icon(forFile: url.path)
            return
        }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let stamp = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(stamp)|\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = ThumbnailCache.shared.object(forKey: key) {
            image = cached
            return
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        do {
            let rep = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            guard !Task.isCancelled else { return }
            ThumbnailCache.shared.setObject(rep.nsImage, forKey: key)
            image = rep.nsImage
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
            // Fallback: NSWorkspace icon
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
    }
}

@MainActor
private enum ThumbnailCache {
    static let shared: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 160
        cache.totalCostLimit = 96 * 1_024 * 1_024
        return cache
    }()
}

@MainActor
final class DiskMapQuickLook: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = DiskMapQuickLook()
    private var previewURL: URL?

    func show(_ url: URL) {
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }
}
