import AppKit
import DiskMapCore
import SwiftUI

// Shared by Safe to Review and Caches: a row, the inspector, the selection
// footer, and staging for `ReviewableTarget`s (which can span several paths).

/// A reviewable target row: checkbox, icon, name over detail, safety, size.
struct ReviewTargetRow: View {
    let target: ReviewableTarget
    var subtitle: String
    let checked: Bool
    let selected: Bool
    var onToggle: () -> Void
    var onSelect: () -> Void
    var onStage: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            Toggle(isOn: Binding(get: { checked }, set: { _ in onToggle() })) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.checkbox)
                .padding(.leading, 10)
                .accessibilityLabel(checked ? "Unmark \(target.displayName)" : "Mark \(target.displayName)")
            Button(action: onSelect) {
                KitRow(title: target.displayName, subtitle: subtitle, selected: selected,
                       path: target.primaryPath, onStage: onStage) {
                    ReviewTargetIcon(target: target)
                } trailing: {
                    SafetyLabel(level: target.safety.level, title: target.isGenerallySafe ? "Generally safe" : nil)
                        .frame(width: DiskMapType.scaled(112), alignment: .leading)
                    MonoColumn(text: ByteFormat.string(target.bytes), width: 74, emphasis: true)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(target.displayName), \(ByteFormat.string(target.bytes)), \(target.isGenerallySafe ? "generally safe" : target.safety.level.title)")
            .rowActions(path: target.primaryPath, stage: onStage)
        }
    }
}

/// The owning app's icon when known, else the target's symbol.
struct ReviewTargetIcon: View {
    let target: ReviewableTarget
    var size: CGFloat = 24

    var body: some View {
        Group {
            if let hint = target.bundleHint,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: hint) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: target.symbolName)
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(DiskMapTheme.ink2)
                    .frame(width: size, height: size)
                    .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(DiskMapTheme.ink.opacity(0.06)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Inspector for a cache, build output or package cache.
struct ReviewableInspector: View {
    @ObservedObject var model: ScanModel
    let target: ReviewableTarget
    var onStage: () -> Void

    var body: some View {
        let staged = target.paths.contains { model.isStaged(URL(fileURLWithPath: $0, isDirectory: true)) }
        InspectorColumn {
            InspectorHeader(name: target.displayName, size: ByteFormat.string(target.bytes),
                            detail: "\(target.detail) · \(target.category.title)") {
                ReviewTargetIcon(target: target, size: 40)
            }
            Hairline()
            if !target.paths.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    MonoLabel(target.paths.count == 1 ? "Location" : "Locations")
                    ForEach(target.paths.prefix(6), id: \.self) { path in
                        Text(CanonicalPath.displayPath(absolutePath: path))
                            .font(DiskMapType.figure)
                            .foregroundStyle(DiskMapTheme.ink)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    if target.paths.count > 6 {
                        Text("+\(target.paths.count - 6) more")
                            .font(DiskMapType.figureSmall)
                            .foregroundStyle(DiskMapTheme.ink3)
                    }
                }
            }
            Hairline()
            Note(label: "What it is", text: target.safety.reason)
            VStack(alignment: .leading, spacing: 4) {
                SafetyLabel(level: target.safety.level, title: target.isGenerallySafe ? "Generally safe to clear" : nil)
                Text(target.consequence.isEmpty ? target.safety.recommendedAction : target.consequence)
                    .font(DiskMapType.secondary)
                    .foregroundStyle(DiskMapTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            InspectorActions(
                primaryTitle: staged ? "In Cleanup" : "Add to Cleanup",
                primaryDone: staged,
                primaryEnabled: !target.isProtected,
                primary: { if staged { model.isCleanupQueuePresented = true } else { onStage() } },
                path: target.primaryPath
            ) {
                if let id = target.nodeIDs.first {
                    Button("Open in File Browser") {
                        model.currentNode = id
                        model.selectedNode = id
                        model.destination = .fileBrowser
                    }
                    Button("Show in Visualize") {
                        model.currentNode = id
                        model.selectedNode = id
                        model.destination = .visualize
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}

/// Footer for a checkbox list: a hint with a quick-select link, or the
/// shared selection toolbar once something is checked.
struct ReviewSelectionFooter: View {
    let checkedTargets: [ReviewableTarget]
    var hint: String
    var quickSelectTitle: String
    var quickSelectEnabled: Bool
    var onQuickSelect: () -> Void
    var onStage: () -> Void
    var onClear: () -> Void

    var body: some View {
        ReviewFooter(
            checkedCount: checkedTargets.count,
            checkedBytes: checkedTargets.reduce(0) { $0 + $1.bytes },
            hint: hint, quickSelectTitle: quickSelectTitle, quickSelectEnabled: quickSelectEnabled,
            onQuickSelect: onQuickSelect, onStage: onStage, onClear: onClear,
            onReveal: {
                NSWorkspace.shared.activateFileViewerSelecting(checkedTargets.map { URL(fileURLWithPath: $0.primaryPath) })
            },
            paths: checkedTargets.flatMap(\.paths)
        )
    }
}

/// The checkbox-list footer for any item type: a hint with a quick-select
/// link, or the selection toolbar once something is checked.
struct ReviewFooter: View {
    var checkedCount: Int
    var checkedBytes: Int64
    var hint: String
    var quickSelectTitle: String
    var quickSelectEnabled = true
    var onQuickSelect: () -> Void
    var onStage: () -> Void
    var onClear: () -> Void
    var onReveal: () -> Void
    var paths: [String]

    var body: some View {
        if checkedCount == 0 {
            HStack(spacing: 6) {
                Text(hint)
                    .font(DiskMapType.secondary)
                    .foregroundStyle(DiskMapTheme.ink3)
                Button(quickSelectTitle, action: onQuickSelect)
                    .buttonStyle(LinkButtonStyle())
                    .font(DiskMapType.secondary)
                    .disabled(!quickSelectEnabled)
                Spacer()
            }
            .padding(.horizontal, 28)
            .frame(height: 44)
            .overlay(alignment: .top) { Hairline() }
        } else {
            SelectionToolbar(selectedCount: checkedCount, selectedBytes: checkedBytes,
                             onPrimary: onStage, onClear: onClear, onReveal: onReveal, paths: paths)
        }
    }
}

extension ScanModel {
    /// Stages every path of each target (a cache group can span several
    /// folders). Toasts the outcome; never opens the Cleanup sheet.
    @discardableResult
    func stageReviewTargets(_ targets: [ReviewableTarget], reason: (ReviewableTarget) -> String) async -> Int {
        var requests: [CleanupStageRequest] = []
        let totals = selectedTotals
        for target in targets where !target.isProtected {
            for (index, path) in target.paths.enumerated() {
                var size = target.bytes / Int64(max(1, target.paths.count))
                if index < target.nodeIDs.count, Int(target.nodeIDs[index]) < totals.count {
                    size = totals[Int(target.nodeIDs[index])]
                }
                requests.append(CleanupStageRequest(url: URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL,
                                                    size: size, reason: reason(target)))
            }
        }
        let summary = await stageForCleanup(requests)
        showToast(summary.added > 0 ? "Added \(countLabel(targets.count, "item")) to Cleanup — ⇧⌘⌫ to review"
                  : summary.alreadyPresent > 0 ? "Already in Cleanup" : "Nothing could be added")
        return summary.added
    }
}
