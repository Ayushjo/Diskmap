import AppKit
import DiskMapCore
import SwiftUI

// Adding to Cleanup, the way the Windows build does it
// (docs/MAC-FIXES-FROM-WINDOWS.md §3.2, §4.2):
// - a bulk add lists every item by full path and size and waits for a yes;
// - risky items (Docker's disk, VMs, apps, browser profiles, .git…) are left
//   out of bulk adds — added one at a time, each shows why and what to do
//   instead; things macOS manages are refused with the right alternative.

/// One line of a confirmation list.
struct ConfirmPathRow: Identifiable, Equatable {
    var id: String { path }
    var path: String
    var bytes: Int64
}

/// A bulk add waiting for the person to confirm.
struct BulkStageProposal: Identifiable {
    let id = UUID()
    var title: String
    var safe: [CleanupStageRequest]
    /// Left out: added one at a time, each shows its warning.
    var skipped: [(request: CleanupStageRequest, verdict: StorageVerdict)]
    var resolve: (Bool) -> Void
}

/// One risky item waiting for "Add anyway".
struct RiskyStageProposal: Identifiable {
    let id = UUID()
    var request: CleanupStageRequest
    var verdict: StorageVerdict
    var resolve: (Bool) -> Void
}

extension ScanModel {
    private static func verdict(for request: CleanupStageRequest) -> StorageVerdict {
        let path = request.url.path
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            return StorageClassifier.classify(path: path, isDirectory: isDirectory.boolValue)
        }
        // Gone or unknown: judge it both ways and keep the stricter answer
        // (".git" and "Slack.app" look like file names).
        let asFolder = StorageClassifier.classify(path: path, isDirectory: true)
        let asFile = StorageClassifier.classify(path: path, isDirectory: false)
        let rank: [CleanupAdvice: Int] = [.fine: 0, .review: 1, .warn: 2, .never: 3]
        return (rank[asFile.advice] ?? 0) > (rank[asFolder.advice] ?? 0) ? asFile : asFolder
    }

    /// What a bulk add offers, and what it leaves out as risky.
    static func splitForBulkStage(_ requests: [CleanupStageRequest], allowing: Set<String> = [])
        -> (safe: [CleanupStageRequest], skipped: [(request: CleanupStageRequest, verdict: StorageVerdict)]) {
        var safe: [CleanupStageRequest] = []
        var skipped: [(request: CleanupStageRequest, verdict: StorageVerdict)] = []
        for request in requests {
            let verdict = verdict(for: request)
            if verdict.advice.isRisky, !allowing.contains(verdict.storageClass.id) {
                skipped.append((request, verdict))
            } else {
                safe.append(request)
            }
        }
        return (safe, skipped)
    }

    /// Bulk "Add to Cleanup". Lists every item in a sheet and stages only
    /// after a yes; risky items are skipped and named. `allowing` are
    /// category ids this screen adds on purpose (Applications adds apps).
    /// Nil when cancelled or nothing could be offered.
    func confirmStageMany(_ requests: [CleanupStageRequest], title: String,
                          allowing: Set<String> = []) async -> CleanupStageSummary? {
        guard !requests.isEmpty else { return nil }
        // One item is not a bulk add: it gets the single-item checks.
        if requests.count == 1, let only = requests.first {
            let summary = await stageOne(only, allowing: allowing)
            if let summary, !summary.wasBusy { showToast(Self.stagedToast(summary)) }
            return summary
        }
        let (safe, skipped) = Self.splitForBulkStage(requests, allowing: allowing)
        guard !safe.isEmpty else {
            showToast("\(countLabel(skipped.count, "risky item")) — add \(skipped.count == 1 ? "it" : "them") one at a time to see why")
            return nil
        }
        let confirmed = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            var resolved = false
            pendingBulkStage = BulkStageProposal(title: title, safe: safe, skipped: skipped) { answer in
                guard !resolved else { return }
                resolved = true
                done.resume(returning: answer)
            }
        }
        pendingBulkStage = nil
        guard confirmed else { return nil }
        let summary = await stageForCleanup(safe)
        if summary.wasBusy {
            showToast("Still adding the last selection — try again in a moment")
        } else if !skipped.isEmpty {
            let names = skipped.prefix(2).map { $0.request.url.lastPathComponent }.joined(separator: ", ")
            let more = skipped.count > 2 ? " +\(skipped.count - 2)" : ""
            showToast("Added \(countLabel(summary.added, "item")) · skipped \(countLabel(skipped.count, "risky item")) (\(names)\(more))")
        } else {
            showToast(summary.added > 0 ? "Added \(countLabel(summary.added, "item")) to Cleanup — ⇧⌘⌫ to review"
                      : summary.alreadyPresent > 0 ? "Already in Cleanup" : "Nothing could be added")
        }
        return summary
    }

    static func stagedToast(_ summary: CleanupStageSummary) -> String {
        summary.added > 0 ? "Added \(countLabel(summary.added, "item")) to Cleanup — ⇧⌘⌫ to review"
            : summary.alreadyPresent > 0 ? "Already in Cleanup" : "Blocked by safety rules"
    }

    /// One item: things macOS manages are refused with what to do instead;
    /// risky ones ask first. Nil when refused or cancelled.
    func stageOne(_ request: CleanupStageRequest, allowing: Set<String> = []) async -> CleanupStageSummary? {
        let verdict = Self.verdict(for: request)
        if !allowing.contains(verdict.storageClass.id) {
            if verdict.advice == .never {
                showToast("macOS manages this. " + (verdict.instead ?? verdict.note ?? "It can’t be added to Cleanup."))
                return nil
            }
            if verdict.advice == .warn {
                let confirmed = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                    var resolved = false
                    pendingRiskyStage = RiskyStageProposal(request: request, verdict: verdict) { answer in
                        guard !resolved else { return }
                        resolved = true
                        done.resume(returning: answer)
                    }
                }
                pendingRiskyStage = nil
                guard confirmed else { return nil }
            }
        }
        let summary = await stageForCleanup([request])
        if summary.wasBusy { showToast("Still adding the last selection — try again in a moment") }
        return summary
    }
}

/// A list of paths and sizes to confirm, biggest first. Cancel is the
/// default, so Return never adds or moves anything by accident.
struct PathListConfirmSheet: View {
    var title: String
    var message: String
    var footnote: String?
    var rows: [ConfirmPathRow]
    var confirmTitle: String
    var destructive = false
    var onConfirm: () -> Void
    var onCancel: () -> Void

    static let rowLimit = 400

    var body: some View {
        let sorted = rows.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
        let total = rows.reduce(Int64(0)) { $0 + max(0, $1.bytes) }
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(DiskMapType.heading)
                .foregroundStyle(DiskMapTheme.ink)
            Text(message)
                .font(DiskMapType.secondary)
                .foregroundStyle(DiskMapTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sorted.prefix(Self.rowLimit)) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text((row.path as NSString).lastPathComponent)
                                    .font(DiskMapType.bodyEmphasis)
                                    .foregroundStyle(DiskMapTheme.ink)
                                    .lineLimit(1)
                                Text(row.path)
                                    .font(DiskMapType.figureSmall)
                                    .foregroundStyle(DiskMapTheme.ink3)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                            Spacer(minLength: 8)
                            Text(ByteFormat.string(row.bytes))
                                .font(DiskMapType.figure)
                                .foregroundStyle(DiskMapTheme.ink2)
                        }
                        .padding(.vertical, 6)
                        .accessibilityElement(children: .combine)
                        Hairline()
                    }
                    if sorted.count > Self.rowLimit {
                        Text("+ \((sorted.count - Self.rowLimit).formatted()) more")
                            .font(DiskMapType.secondary)
                            .foregroundStyle(DiskMapTheme.ink3)
                            .padding(.vertical, 8)
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 340)
            HStack {
                Text("\(countLabel(rows.count, "item")) · \(ByteFormat.string(total))")
                    .font(DiskMapType.figure)
                    .foregroundStyle(DiskMapTheme.ink)
                Spacer()
            }
            if let footnote {
                Text(footnote)
                    .font(DiskMapType.secondary)
                    .foregroundStyle(DiskMapTheme.review)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Button(confirmTitle, action: onConfirm)
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(DiskMapTheme.raised)
    }
}

/// "Add <name> to Cleanup?" for one risky item: what it is, why removing it
/// hurts, and the better way to get the space back.
struct RiskyStageSheet: View {
    var proposal: RiskyStageProposal

    var body: some View {
        let name = proposal.request.url.lastPathComponent
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: DiskMapType.scaled(18), weight: .medium))
                    .foregroundStyle(DiskMapTheme.review)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DiskMapTheme.review.opacity(0.12)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    MonoLabel(proposal.verdict.storageClass.title)
                    Text("Add \(name) to Cleanup?")
                        .font(DiskMapType.heading)
                        .foregroundStyle(DiskMapTheme.ink)
                        .lineLimit(2)
                }
            }
            if let note = proposal.verdict.note {
                Text(note)
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let instead = proposal.verdict.instead {
                VStack(alignment: .leading, spacing: 4) {
                    MonoLabel("Instead")
                    Text(.init(instead))
                        .font(DiskMapType.secondary)
                        .foregroundStyle(DiskMapTheme.ink2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DiskMapRadius.card, style: .continuous)
                    .stroke(DiskMapTheme.line, lineWidth: 1))
            }
            Text(proposal.request.url.path)
                .font(DiskMapType.figureSmall)
                .foregroundStyle(DiskMapTheme.ink3)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { proposal.resolve(false) }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Button("Add anyway") { proposal.resolve(true) }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(DiskMapTheme.raised)
        .onDisappear { proposal.resolve(false) }
    }
}

/// The bulk-add sheet, from a proposal.
struct BulkStageSheet: View {
    var proposal: BulkStageProposal

    var body: some View {
        let skipped = proposal.skipped.count
        PathListConfirmSheet(
            title: "Add \(countLabel(proposal.safe.count, "item")) to Cleanup?",
            message: "Nothing is deleted yet — you review the list in Cleanup and confirm again before anything moves to the Trash.",
            footnote: skipped == 0 ? nil
                : "\(countLabel(skipped, "risky item")) (\(proposal.skipped.prefix(3).map { $0.request.url.lastPathComponent }.joined(separator: ", "))\(skipped > 3 ? "…" : "")) won’t be added — add \(skipped == 1 ? "it" : "them") one at a time to see why.",
            rows: proposal.safe.map { ConfirmPathRow(path: $0.url.path, bytes: $0.size) },
            confirmTitle: "Add to Cleanup",
            onConfirm: { proposal.resolve(true) },
            onCancel: { proposal.resolve(false) }
        )
        .onDisappear { proposal.resolve(false) }
    }
}
