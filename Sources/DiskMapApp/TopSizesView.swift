import DiskMapCore
import SwiftUI

struct TopSizesView: View {
    let tree: FileTree
    let totals: [Int64]
    let rootURL: URL
    @Binding var selectedNode: Int32

    private var ranked: [Int32] {
        guard totals.count == tree.count else { return [] }
        return TopSizes.rankedFiles(tree: tree, totals: totals)
    }

    var body: some View {
        Group {
            if ranked.isEmpty {
                Text("Nothing ranked yet")
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(ranked.enumerated()), id: \.element) { index, id in
                            rankRow(index: index, id: id)
                            Rectangle()
                                .fill(DiskMapTheme.cardStroke.opacity(0.7))
                                .frame(height: 1)
                                .padding(.leading, 52)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
        }
        .background(DiskMapTheme.cream)
    }

    private func rankRow(index: Int, id: Int32) -> some View {
        let selected = id == selectedNode
        let size = totals[Int(id)]
        return Button {
            selectedNode = id
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Text("\(index + 1)")
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(selected ? Color.white : DiskMapTheme.mutedLabel)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(selected ? DiskMapTheme.ink : DiskMapTheme.cardFill)
                            .overlay(Circle().stroke(DiskMapTheme.cardStroke, lineWidth: 1))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(tree.name(of: id))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                        .lineLimit(1)
                    Text(CanonicalPath.parentDisplay(of: tree.path(of: id, root: rootURL).path))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(diskByteString(size))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DiskMapTheme.ink)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? DiskMapTheme.ink.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
