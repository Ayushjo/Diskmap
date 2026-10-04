import AppKit
import DiskMapCore
import QuickLookThumbnailing
import Quartz
import SwiftUI

// MARK: - Spacing scale (4…32)


// MARK: - Shared compact controls

struct DiskMapSearchField: View {
    var placeholder: String
    @Binding var text: String
    var shortcutHint: String? = nil
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: DiskMapSpace.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: DiskMapType.scaled(11.5), weight: .medium))
                .foregroundStyle(DiskMapTheme.ink3)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DiskMapType.body)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DiskMapTheme.ink3)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            } else if let shortcutHint, !focused {
                Kbd(shortcutHint)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: DiskMapMetric.searchHeight)
        .background(
            RoundedRectangle(cornerRadius: DiskMapRadius.control, style: .continuous)
                .fill(DiskMapTheme.raised.opacity(focused ? 1 : 0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: DiskMapRadius.control, style: .continuous)
                        .stroke(focused ? DiskMapTheme.accent.opacity(0.6) : DiskMapTheme.line, lineWidth: 1)
                )
        )
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
            HStack(spacing: 5) {
                Text(label.isEmpty ? "" : label)
                    .foregroundStyle(DiskMapTheme.ink3)
                Text(title(selection))
                    .foregroundStyle(DiskMapTheme.ink)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: DiskMapType.scaled(8.5), weight: .semibold))
                    .foregroundStyle(DiskMapTheme.ink3)
            }
            .font(DiskMapType.bodyEmphasis)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(width: width, height: DiskMapMetric.controlHeight)
            .contentShape(Rectangle())
        }
        // A plain-button menu draws this label as written. The borderless
        // style replaced it with a system-font title that ignored Text Size.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: width == nil, vertical: true)
    }
}


// MARK: - Classification badge (color + text — never color alone)


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
                .font(.system(size: DiskMapType.scaled(20), weight: .regular))
                .foregroundStyle(DiskMapTheme.ink3)
                .accessibilityHidden(true)
            Text(title)
                .font(DiskMapType.bodyEmphasis)
                .foregroundStyle(DiskMapTheme.ink)
            Text(message)
                .font(DiskMapType.secondary)
                .foregroundStyle(DiskMapTheme.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: DiskMapSpace.xs) {
                if let primaryTitle, let primaryAction {
                    Button(primaryTitle, action: primaryAction)
                        .buttonStyle(PrimaryButtonStyle())
                }
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                        .buttonStyle(SecondaryButtonStyle())
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
                .font(DiskMapType.bodyEmphasis)
                .foregroundStyle(DiskMapTheme.ink)
            if let detail {
                Text(detail)
                    .font(DiskMapType.secondary)
                    .foregroundStyle(DiskMapTheme.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            if let processed, let total, total > 0 {
                Text("\(processed.formatted()) of \(total.formatted()) size groups")
                    .font(DiskMapType.figureSmall)
                    .foregroundStyle(DiskMapTheme.ink2)
            }
            if let onCancel {
                Button("Cancel", action: onCancel)
                    .buttonStyle(SecondaryButtonStyle())
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
    /// Paths of the selection, one per line, for a terminal (TASK-058).
    var paths: [String]? = nil

    var body: some View {
        HStack(spacing: DiskMapSpace.xs) {
            Text("\(selectedCount.formatted()) selected")
                .font(DiskMapType.bodyEmphasis)
                .foregroundStyle(DiskMapTheme.ink)
            Text(ByteFormat.string(selectedBytes))
                .font(DiskMapType.figure)
                .foregroundStyle(DiskMapTheme.ink2)
            Button("Clear", action: onClear)
                .buttonStyle(QuietButtonStyle())
                .keyboardShortcut(.cancelAction)
            Spacer()
            HStack(spacing: 2) {
                if let onReveal {
                    Button(action: onReveal) { Label("Reveal in Finder", systemImage: "arrow.up.forward.app") }
                        .help("Reveal in Finder")
                }
                if let paths, !paths.isEmpty {
                    Button { copyPaths(paths) } label: { Label("Copy Paths", systemImage: "doc.on.doc") }
                        .help("Copy the selected paths, one per line")
                }
            }
            .buttonStyle(IconButtonStyle())
            Button(primaryTitle, action: onPrimary)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!primaryEnabled || selectedCount == 0)
        }
        .padding(.horizontal, DiskMapSpace.md)
        .frame(height: 48)
        .background(DiskMapTheme.canvas)
        .overlay(alignment: .top) { Hairline() }
    }
}

// MARK: - Compact why / safety cards for inspectors

/// A persistent inline notice for something that makes the numbers on screen
/// incomplete or approximate. The app deliberately has no modal alerts; a
/// trust problem belongs next to the numbers it affects, and stays until fixed.
struct DiskMapNoticeBanner: View {
    var symbol: String
    var tint: Color
    var title: String
    var detail: String
    var examples: [String] = []
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DiskMapSpace.sm) {
            Image(systemName: symbol)
                .font(.system(size: DiskMapType.scaled(11.5), weight: .medium))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(DiskMapType.bodyEmphasis)
                    .foregroundStyle(DiskMapTheme.ink)
                Text(detail)
                    .font(DiskMapType.secondary)
                    .foregroundStyle(DiskMapTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(examples, id: \.self) { example in
                    Text(example)
                        .font(DiskMapType.figureSmall)
                        .foregroundStyle(DiskMapTheme.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(LinkButtonStyle())
            }
        }
        .padding(.horizontal, DiskMapSpace.sm)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DiskMapRadius.card, style: .continuous)
                .stroke(DiskMapTheme.line, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
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
        windowWidth >= 1450 ? 320 : 290
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
                    Rectangle().fill(DiskMapTheme.line).frame(width: 1)
                    inspectorContent
                        .frame(width: DiskMapLayout.inspectorWidth(for: windowWidth))
                        .background(DiskMapTheme.canvas)
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
                                }
                                .buttonStyle(QuietButtonStyle())
                                .help("Show Inspector")
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(DiskMapTheme.canvas)
                        Hairline()
                        mainContent
                    }
                    if showsDrawer {
                        Color.black.opacity(0.12)
                            .ignoresSafeArea()
                            .onTapGesture { showsDrawer = false }
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Rectangle().fill(DiskMapTheme.line).frame(width: 1)
                            inspectorContent
                                .frame(width: min(320, max(280, windowWidth * 0.34)))
                                .background(DiskMapTheme.canvas)
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
                    fallbackSymbol: resolvedKind.symbolName,
                    fallsBackToFileIcon: false
                )
            } else if resolvedKind == .application || url.pathExtension.lowercased() == "app" {
                Image(nsImage: WorkspaceIconCache.icon(for: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(2)
            } else {
                Image(systemName: resolvedKind.symbolName)
                    .font(.system(size: size * 0.44, weight: .regular))
                    .foregroundStyle(resolvedKind == .other ? DiskMapTheme.ink2 : identityTint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(resolvedKind == .other ? DiskMapTheme.hover : identityTint.opacity(0.16))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: max(5, size * 0.24), style: .continuous))
        .accessibilityHidden(true)
    }

    private var isLocallyPreviewable: Bool {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values?.isUbiquitousItem == true else { return true }
        return values?.ubiquitousItemDownloadingStatus == .current
            || values?.ubiquitousItemDownloadingStatus == .downloaded
    }

    private var identityTint: Color {
        DiskMapTheme.kindColor(resolvedKind)
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
    /// When the thumbnail can't be made: the Finder icon (large previews) or
    /// the quiet kind glyph (small row icons, where a white page glares).
    var fallsBackToFileIcon: Bool = true

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DiskMapTheme.hover)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: min(size.height, size.width) * (min(size.height, size.width) <= 48 ? 0.44 : 0.28)))
                    .foregroundStyle(DiskMapTheme.ink3)
            }
            if showPlayBadge {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: DiskMapType.scaled(22)))
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
            image = fallsBackToFileIcon ? NSWorkspace.shared.icon(forFile: url.path) : nil
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


/// One path per line, shell-ready: paths with spaces or quotes are
/// single-quoted so the result pastes safely into a terminal.
@MainActor
func copyPaths(_ paths: [String]) {
    let text = paths.map(shellQuoted).joined(separator: "\n")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    ScanModel.shared.showToast(paths.count == 1 ? "Copied 1 path" : "Copied \(paths.count) paths")
}

func shellQuoted(_ path: String) -> String {
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+,@%=:~"))
    guard path.unicodeScalars.contains(where: { !safe.contains($0) }) else { return path }
    return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
