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

    var body: some View {
        VStack(spacing: 0) {
            DrillHeader(tree: tree, currentNode: currentNode, totals: totals) { id in
                currentNode = id
                selectedNode = id
            }
            List(rows, id: \.id) { row in
                HStack {
                    Image(systemName: tree.isDirectory[Int(row.id)] ? "folder" : "doc")
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                    Text(tree.name(of: row.id))
                        .foregroundStyle(DiskMapTheme.ink)
                        .lineLimit(1)
                    Spacer()
                    Text(diskByteString(row.size))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .monospacedDigit()
                }
                .padding(.vertical, 2)
                .listRowBackground(row.id == selectedNode ? DiskMapTheme.ink.opacity(0.08) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedNode = row.id
                    if tree.isDirectory[Int(row.id)] {
                        currentNode = row.id
                    }
                }
                .onTapGesture(count: 2) {
                    selectedNode = row.id
                    guard !tree.isDirectory[Int(row.id)] else { return }
                    revealDownloadedFile(row.id, tree: tree, root: rootURL)
                }
            }
            .scrollContentBackground(.hidden)
            .background(DiskMapTheme.cream)
        }
        .background(DiskMapTheme.cream)
    }
}
