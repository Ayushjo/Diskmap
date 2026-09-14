import DiskMapCore
import SwiftUI

struct TopSizesView: View {
    let tree: FileTree
    let totals: [Int64]
    let rootURL: URL
    @Binding var selectedNode: Int32

    private var ranked: [Int32] {
        guard totals.count == tree.count else { return [] }
        return TopSizes.ranked(totals: totals)
    }

    var body: some View {
        List(ranked, id: \.self) { id in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tree.path(of: id, root: rootURL).path)
                        .foregroundStyle(DiskMapTheme.ink)
                        .lineLimit(1)
                    Text(tree.isDirectory[Int(id)] ? "Folder" : "File")
                        .font(.caption)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
                Spacer()
                Text(diskByteString(totals[Int(id)]))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .monospacedDigit()
            }
            .listRowBackground(id == selectedNode ? DiskMapTheme.ink.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedNode = id
            }
            .onTapGesture(count: 2) {
                selectedNode = id
                guard !tree.isDirectory[Int(id)] else { return }
                revealDownloadedFile(id, tree: tree, root: rootURL)
            }
        }
        .scrollContentBackground(.hidden)
        .background(DiskMapTheme.cream)
    }
}
