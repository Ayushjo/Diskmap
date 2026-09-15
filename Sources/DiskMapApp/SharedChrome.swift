import DiskMapCore
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
    var primaryTitle: String = "Add to Cleanup Review"
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
