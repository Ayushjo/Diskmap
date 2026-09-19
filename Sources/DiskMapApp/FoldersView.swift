import DiskMapCore
import SwiftUI

struct FoldersView: View {
    let tree: FileTree
    let totals: [Int64]
    let rootURL: URL
    @Binding var currentNode: Int32

    private var rows: [(id: Int32, size: Int64)] {
        guard currentNode >= 0, Int(currentNode) < tree.count, totals.count == tree.count else { return [] }
        return tree.children(of: currentNode, totals: totals).sorted { $0.size > $1.size }
    }

    var body: some View {
        VStack(spacing: 0) {
            DrillHeader(tree: tree, currentNode: currentNode, totals: totals) { currentNode = $0 }
            List(rows, id: \.id) { row in
                HStack {
                    Image(systemName: tree.flags[Int(row.id)] & NodeFlags.notDownloaded != 0
                          ? "icloud"
                          : tree.isDirectory[Int(row.id)] ? "folder" : "doc")
                        .foregroundStyle(.secondary)
                    Text(tree.name(of: row.id))
                        .lineLimit(1)
                    Spacer()
                    Text(diskByteString(row.size))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard tree.isDirectory[Int(row.id)] else { return }
                    currentNode = row.id
                }
                .onTapGesture(count: 2) {
                    guard !tree.isDirectory[Int(row.id)] else { return }
                    revealDownloadedFile(row.id, tree: tree, root: rootURL)
                }
            }
        }
    }
}
