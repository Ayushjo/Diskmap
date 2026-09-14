import DiskMapCore
import SwiftUI

struct FoldersView: View {
    let tree: FileTree
    let totals: [Int64]
    let rootURL: URL
    @Binding var currentNode: Int32
    @Binding var selectedNode: Int32

    private var rows: [(id: Int32, size: Int64)] {
        guard currentNode >= 0, Int(currentNode) < tree.count, totals.count == tree.count else { return [] }
        return tree.children(of: currentNode, totals: totals).sorted { $0.size > $1.size }
    }

    private var parentTotal: Int64 {
        guard currentNode >= 0, Int(currentNode) < totals.count else { return 0 }
        return max(totals[Int(currentNode)], 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            DrillHeader(tree: tree, currentNode: currentNode, totals: totals) { id in
                currentNode = id
                selectedNode = id
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if rows.isEmpty {
                Text("Nothing with a size in this folder")
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows, id: \.id) { row in
                            folderRow(row)
                            Rectangle()
                                .fill(DiskMapTheme.cardStroke.opacity(0.7))
                                .frame(height: 1)
                                .padding(.leading, 44)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .background(DiskMapTheme.cream)
    }

    private func folderRow(_ row: (id: Int32, size: Int64)) -> some View {
        let selected = row.id == selectedNode
        let frac = Double(row.size) / Double(parentTotal)
        return Button {
            selectedNode = row.id
            if tree.isDirectory[Int(row.id)] {
                currentNode = row.id
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? DiskMapTheme.ink : DiskMapTheme.cardFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                        )
                    Image(systemName: tree.isDirectory[Int(row.id)] ? "folder.fill" : "doc")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : DiskMapTheme.mutedLabel)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(tree.name(of: row.id))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DiskMapTheme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(diskByteString(row.size))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(DiskMapTheme.ink)
                    }
                    ProportionBar(fraction: frac, tint: DiskMapTheme.ink.opacity(0.28))
                        .frame(height: 3)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? DiskMapTheme.ink.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
