import SwiftUI

/// Brand empty-state / scan-progress illustration: a calm storage map (disk + nodes).
/// Decorative — use with `accessibilityHidden(true)` when paired with a headline.
struct StorageMapIllustration: View {
    enum Mode {
        case idle
        case scanning
        case ready
    }

    var mode: Mode = .idle
    var size: CGFloat = 120
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            // Soft outer ring
            Circle()
                .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                .frame(width: size * 0.92, height: size * 0.92)
                .opacity(0.9)

            // Connecting lines (behind nodes)
            StorageMapLines()
                .stroke(DiskMapTheme.ink.opacity(0.12), lineWidth: 1)
                .frame(width: size, height: size)

            // Central disk
            RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                .fill(DiskMapTheme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                        .stroke(DiskMapTheme.ink.opacity(0.18), lineWidth: 1.5)
                )
                .frame(width: size * 0.38, height: size * 0.48)
                .overlay(
                    VStack(spacing: size * 0.04) {
                        Capsule()
                            .fill(DiskMapTheme.ink.opacity(0.2))
                            .frame(width: size * 0.12, height: size * 0.035)
                        Circle()
                            .fill(DiskMapTheme.info.opacity(mode == .scanning ? 0.85 : 0.55))
                            .frame(width: size * 0.07, height: size * 0.07)
                            .scaleEffect(pulse && mode == .scanning ? 1.15 : 1)
                    }
                )
                .shadow(color: Color.black.opacity(0.04), radius: 6, y: 2)

            // Satellite nodes
            ForEach(Array(StorageMapNode.all.enumerated()), id: \.offset) { index, node in
                let progress = appeared ? 1.0 : 0.0
                Circle()
                    .fill(node.color.opacity(0.92))
                    .frame(width: size * node.scale, height: size * node.scale)
                    .overlay(
                        Image(systemName: node.symbol)
                            .font(.system(size: size * node.scale * 0.42, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                    .offset(
                        x: node.x * size * 0.5 * progress,
                        y: node.y * size * 0.5 * progress
                    )
                    .opacity(0.35 + 0.65 * progress)
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !reduceMotion else {
                appeared = true
                return
            }
            withAnimation(.easeOut(duration: 0.55)) {
                appeared = true
            }
            if mode == .scanning {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        }
        .onChange(of: mode) { _, new in
            if new == .scanning, !reduceMotion {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            } else {
                pulse = false
            }
        }
    }
}

private struct StorageMapNode {
    var x: CGFloat
    var y: CGFloat
    var scale: CGFloat
    var symbol: String
    var color: Color

    static let all: [StorageMapNode] = [
        .init(x: -0.72, y: -0.35, scale: 0.16, symbol: "doc.fill", color: DiskMapTheme.info),
        .init(x: 0.70, y: -0.28, scale: 0.15, symbol: "folder.fill", color: DiskMapTheme.review),
        .init(x: -0.55, y: 0.55, scale: 0.14, symbol: "app.fill", color: DiskMapTheme.developer),
        .init(x: 0.58, y: 0.52, scale: 0.15, symbol: "photo.fill", color: DiskMapTheme.safe),
        .init(x: 0.05, y: -0.78, scale: 0.12, symbol: "chevron.left.forwardslash.chevron.right", color: DiskMapTheme.ink.opacity(0.65)),
        .init(x: -0.05, y: 0.78, scale: 0.11, symbol: "internaldrive", color: DiskMapTheme.mutedLabel),
    ]
}

private struct StorageMapLines: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let pts: [CGPoint] = [
            CGPoint(x: c.x - rect.width * 0.36, y: c.y - rect.height * 0.18),
            CGPoint(x: c.x + rect.width * 0.35, y: c.y - rect.height * 0.14),
            CGPoint(x: c.x - rect.width * 0.28, y: c.y + rect.height * 0.28),
            CGPoint(x: c.x + rect.width * 0.29, y: c.y + rect.height * 0.26),
            CGPoint(x: c.x, y: c.y - rect.height * 0.39),
            CGPoint(x: c.x, y: c.y + rect.height * 0.39),
        ]
        for p in pts {
            path.move(to: c)
            path.addLine(to: p)
        }
        return path
    }
}
