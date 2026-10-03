import AppKit
import DiskMapCore
import SwiftUI

// The calm kit (Milestone 18). Every page is built from these parts so the
// app reads as one system: a header, one inline figure strip, one filter row,
// one flat list, one selection bar, one inspector. Lines over boxes, one
// accent, figures in mono.

// MARK: - Text

/// Uppercase SF Mono label: eyebrows, section labels, column headers, figure captions.
struct MonoLabel: View {
    let text: String
    var tint: Color = DiskMapTheme.ink3
    init(_ text: String, tint: Color = DiskMapTheme.ink3) {
        self.text = text
        self.tint = tint
    }
    var body: some View {
        Text(text.uppercased())
            .font(DiskMapType.label)
            .tracking(0.6)
            .foregroundStyle(tint)
            .lineLimit(1)
    }
}

/// A keyboard shortcut chip (⌘K).
struct Kbd: View {
    let keys: String
    init(_ keys: String) { self.keys = keys }
    var body: some View {
        Text(keys)
            .font(DiskMapType.figureSmall)
            .foregroundStyle(DiskMapTheme.ink3)
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(DiskMapTheme.hover))
            .accessibilityHidden(true)
    }
}

// MARK: - Lines

/// 1 px hairline.
struct Hairline: View {
    var dashed = false
    var body: some View {
        if dashed {
            GeometryReader { geo in
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0.5))
                    path.addLine(to: CGPoint(x: geo.size.width, y: 0.5))
                }
                .stroke(DiskMapTheme.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .frame(height: 1)
        } else {
            Rectangle().fill(DiskMapTheme.line).frame(height: 1)
        }
    }
}

// MARK: - Page structure

/// The one page header: mono eyebrow, title, one-line subtitle, mono summary on the right.
struct PageHeader<Trailing: View>: View {
    var eyebrow: String?
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: DiskMapSpace.md) {
            VStack(alignment: .leading, spacing: 6) {
                if let eyebrow { MonoLabel(eyebrow) }
                Text(title)
                    .font(DiskMapType.title)
                    .foregroundStyle(DiskMapTheme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(DiskMapType.secondary)
                        .foregroundStyle(DiskMapTheme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DiskMapSpace.md)
            trailing
        }
        .accessibilityElement(children: .contain)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(eyebrow: String? = nil, title: String, subtitle: String? = nil) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A mono summary for a header's right side: "21 files · 561.8 MB".
struct HeaderSummary: View {
    let parts: [String]
    var body: some View {
        Text(parts.joined(separator: "  ·  "))
            .font(DiskMapType.figure)
            .foregroundStyle(DiskMapTheme.ink2)
            .lineLimit(1)
    }
}

/// One figure in a `FigureStrip`.
struct Figure: Identifiable {
    var id: String { label }
    var label: String
    var value: String
    var detail: String? = nil
    var tint: Color = DiskMapTheme.ink
}

/// 2–4 inline figures separated by hairlines — replaces stat cards.
struct FigureStrip: View {
    let figures: [Figure]
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(figures.enumerated()), id: \.element.id) { index, figure in
                if index > 0 {
                    Rectangle().fill(DiskMapTheme.line).frame(width: 1).padding(.vertical, 2)
                }
                VStack(alignment: .leading, spacing: 5) {
                    MonoLabel(figure.label)
                    Text(figure.value)
                        .font(.system(size: DiskMapType.scaled(20), weight: .semibold).monospacedDigit())
                        .foregroundStyle(figure.tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let detail = figure.detail {
                        Text(detail)
                            .font(DiskMapType.secondary)
                            .foregroundStyle(DiskMapTheme.ink2)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, index == 0 ? 0 : DiskMapSpace.lg)
                .padding(.trailing, DiskMapSpace.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A section's mono label, an optional trailing control, and a hairline.
struct SectionHeader<Trailing: View>: View {
    var label: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MonoLabel(label, tint: DiskMapTheme.ink2)
                if let detail {
                    Text(detail)
                        .font(DiskMapType.figureSmall)
                        .foregroundStyle(DiskMapTheme.ink3)
                }
                Spacer(minLength: 8)
                trailing
            }
            Hairline()
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(label: String, detail: String? = nil) {
        self.init(label: label, detail: detail) { EmptyView() }
    }
}

// MARK: - Filters

/// The one chip: text + mono count. Off: secondary text. On: accent wash.
struct Chip: View {
    var title: String
    var count: String? = nil
    var symbol: String? = nil
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: DiskMapType.scaled(10.5), weight: .medium))
                }
                Text(title).font(DiskMapType.bodyEmphasis)
                if let count {
                    Text(count)
                        .font(DiskMapType.figureSmall)
                        .foregroundStyle(isOn ? DiskMapTheme.accent : DiskMapTheme.ink3)
                }
            }
            .foregroundStyle(isOn ? DiskMapTheme.ink : DiskMapTheme.ink2)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: DiskMapRadius.control, style: .continuous)
                    .fill(isOn ? DiskMapTheme.accentSoft : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
    }
}

/// Underline tabs with mono counts.
struct KitTabs<ID: Hashable>: View {
    struct Tab: Identifiable {
        var id: ID
        var title: String
        var count: String? = nil
    }
    let tabs: [Tab]
    @Binding var selection: ID

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DiskMapSpace.lg) {
                ForEach(tabs) { tab in
                    let on = tab.id == selection
                    Button { selection = tab.id } label: {
                        VStack(spacing: 7) {
                            HStack(spacing: 5) {
                                Text(tab.title)
                                    .font(on ? DiskMapType.bodyEmphasis : DiskMapType.body)
                                    .foregroundStyle(on ? DiskMapTheme.ink : DiskMapTheme.ink2)
                                if let count = tab.count {
                                    Text(count).font(DiskMapType.figureSmall).foregroundStyle(DiskMapTheme.ink3)
                                }
                            }
                            Rectangle()
                                .fill(on ? DiskMapTheme.ink : .clear)
                                .frame(height: 1.5)
                        }
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            Hairline()
        }
    }
}

// MARK: - Lists

/// Safety as a dot and a word — never a filled pill.
struct SafetyLabel: View {
    var level: SafetyLevel?
    var title: String? = nil
    var tint: Color? = nil

    private var resolvedTitle: String {
        if let title { return title }
        switch level {
        case .safe: return "Safe"
        case .review: return "Review first"
        case .protected: return "Protected"
        case .none: return "Unknown"
        }
    }

    private var resolvedTint: Color {
        if let tint { return tint }
        switch level {
        case .safe: return DiskMapTheme.safe
        case .review: return DiskMapTheme.review
        case .protected: return DiskMapTheme.danger
        case .none: return DiskMapTheme.ink3
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(resolvedTint).frame(width: 6, height: 6)
            Text(resolvedTitle)
                .font(DiskMapType.secondary)
                .foregroundStyle(DiskMapTheme.ink2)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(resolvedTitle)
    }
}

/// Column header row in mono.
struct ColumnHeaderLabel: View {
    let title: String
    var alignment: Alignment = .leading
    var width: CGFloat? = nil
    var body: some View {
        // Same scaling as MonoColumn / TextColumn, so headers stay over their columns.
        MonoLabel(title)
            .frame(width: width.map { $0 * max(1, DiskMapType.scale) }, alignment: alignment)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
    }
}

/// Selection / hover background shared by list rows.
struct RowBackground: View {
    var selected: Bool
    var hovering: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: DiskMapRadius.control, style: .continuous)
            .fill(selected ? DiskMapTheme.accentSoft : hovering ? DiskMapTheme.hover : .clear)
    }
}

/// Row hover actions: Quick Look, Reveal, Add to Cleanup — shown on hover.
struct RowHoverActions: View {
    var path: String
    var onStage: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            Button { DiskMapQuickLook.shared.show(URL(fileURLWithPath: path)) } label: {
                Label("Quick Look", systemImage: "eye")
            }
            .help("Quick Look")
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                Label("Reveal in Finder", systemImage: "arrow.up.forward.app")
            }
            .help("Reveal in Finder")
            if let onStage {
                Button(action: onStage) { Label("Add to Cleanup", systemImage: "plus.circle") }
                    .help("Add to Cleanup")
            }
        }
        .buttonStyle(IconButtonStyle(size: 24))
    }
}

// MARK: - Inspector parts

/// Inspector header: icon, name, the size as the one big figure, one mono line.
struct InspectorHeader<Icon: View>: View {
    var name: String
    var size: String?
    var detail: String?
    @ViewBuilder var icon: Icon

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            icon
            Text(name)
                .font(DiskMapType.heading)
                .foregroundStyle(DiskMapTheme.ink)
                .lineLimit(3)
                .textSelection(.enabled)
            if let size {
                Text(size)
                    .font(DiskMapType.display)
                    .foregroundStyle(DiskMapTheme.ink)
                    .contentTransition(.numericText())
            }
            if let detail {
                Text(detail)
                    .font(DiskMapType.figureSmall)
                    .foregroundStyle(DiskMapTheme.ink2)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Label / value fact, value in mono, wraps for paths.
struct FactRow: View {
    var label: String
    var value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            MonoLabel(label)
            Text(value)
                .font(DiskMapType.figure)
                .foregroundStyle(DiskMapTheme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A single explanatory sentence — no box.
struct Note: View {
    var label: String?
    var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label { MonoLabel(label) }
            Text(text)
                .font(DiskMapType.secondary)
                .foregroundStyle(DiskMapTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Safety as one line: the dot label, then why, then what removing it means.
struct SafetyLine: View {
    var assessment: SafetyAssessment
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SafetyLabel(level: assessment.level)
            Text(assessment.consequences.isEmpty ? assessment.reason : "\(assessment.reason) \(assessment.consequences)")
                .font(DiskMapType.secondary)
                .foregroundStyle(DiskMapTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// One primary button, then icon buttons, then an overflow menu.
struct InspectorActions<More: View>: View {
    var primaryTitle: String
    var primaryDone: Bool = false
    var primaryEnabled: Bool = true
    var primary: () -> Void
    var path: String?
    @ViewBuilder var more: More

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: primary) {
                Label(primaryTitle, systemImage: primaryDone ? "checkmark" : "plus")
            }
            .buttonStyle(primaryDone ? AnyButtonStyleBox(SecondaryButtonStyle(fullWidth: true)) : AnyButtonStyleBox(PrimaryButtonStyle(fullWidth: true)))
            .disabled(!primaryEnabled)
            HStack(spacing: 2) {
                if let path {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                        Label("Reveal in Finder", systemImage: "arrow.up.forward.app")
                    }
                    .help("Reveal in Finder")
                    Button { DiskMapQuickLook.shared.show(URL(fileURLWithPath: path)) } label: {
                        Label("Quick Look", systemImage: "eye")
                    }
                    .help("Quick Look")
                    Button { copyPaths([path]) } label: {
                        Label("Copy Path", systemImage: "doc.on.doc")
                    }
                    .help("Copy Path")
                }
                Spacer(minLength: 0)
                Menu {
                    more
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(DiskMapTheme.ink2)
                .help("More")
                .accessibilityLabel("More actions")
            }
            .buttonStyle(IconButtonStyle())
        }
    }
}

/// Type-erased button style, for choosing one at runtime.
struct AnyButtonStyleBox: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// The standard inspector column: padding, spacing, hairlines between groups.
struct InspectorColumn<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .padding(DiskMapMetric.inspectorPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DiskMapTheme.canvas)
    }
}

// MARK: - Dates

/// One relative-age format for every list: "Today", "Yesterday", "3 d", "4 mo", "2 y", "—".
enum RelativeAge {
    static func short(day: Int32, today: Int32 = AgeMap.today()) -> String {
        guard day > 0 else { return "—" }
        let days = Int(today - day)
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days < 31 { return "\(days) d" }
        if days < 365 { return "\(days / 30) mo" }
        return "\(days / 365) y"
    }

    /// From an age in days rather than a modified day.
    static func short(ageDays: Int32) -> String {
        short(day: AgeMap.today() - ageDays)
    }

    /// Spelled out for inspectors and VoiceOver: "3 days ago".
    static func long(day: Int32, today: Int32 = AgeMap.today()) -> String {
        guard day > 0 else { return "Unknown" }
        let days = Int(today - day)
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days < 31 { return "\(days) days ago" }
        if days < 365 { let m = days / 30; return m == 1 ? "1 month ago" : "\(m) months ago" }
        let y = days / 365
        return y == 1 ? "1 year ago" : "\(y) years ago"
    }
}

/// A path shown relative to the scan root: "Movies/clips/", "—" at the root.
func relativeParent(of absolutePath: String, root: URL) -> String {
    let parent = (absolutePath as NSString).deletingLastPathComponent
    let rootPath = root.path
    if parent == rootPath { return root.lastPathComponent + "/" }
    if parent.hasPrefix(rootPath + "/") {
        return String(parent.dropFirst(rootPath.count + 1)) + "/"
    }
    return CanonicalPath.parentDisplay(of: absolutePath)
}
