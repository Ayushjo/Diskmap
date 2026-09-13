import DiskMapCore
import SwiftUI

struct TopSizesView: View {
    let tree: FileTree
    let totals: [Int64]
    let rootURL: URL

    private var ranked: [Int32] {
        guard totals.count == tree.count else { return [] }
        return TopSizes.ranked(totals: totals)
    }

    var body: some View {
        List(ranked, id: \.self) { id in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tree.path(of: id, root: rootURL).path)
                        .lineLimit(1)
                    Text(tree.isDirectory[Int(id)] ? "Folder" : "File")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(diskByteString(totals[Int(id)]))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                guard !tree.isDirectory[Int(id)] else { return }
                revealDownloadedFile(id, tree: tree, root: rootURL)
            }
        }
    }
}
