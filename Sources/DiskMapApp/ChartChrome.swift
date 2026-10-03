import AppKit
import DiskMapCore
import SwiftUI

/// Listed cloud-only files stay in the lists. Opening them would start a
/// download, so Reveal does nothing when the node is not on disk.
func revealDownloadedFile(_ id: Int32, tree: FileTree, root: URL) {
    guard id >= 0, id < tree.count else { return }
    guard tree.flags[Int(id)] & NodeFlags.notDownloaded == 0 else { return }
    NSWorkspace.shared.activateFileViewerSelecting([tree.path(of: id, root: root)])
}

struct BreadcrumbBar: View {
    let tree: FileTree
    let currentNode: Int32
    let jump: (Int32) -> Void

    var body: some View {
        let chain = tree.ancestorIDs(of: currentNode)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(chain.enumerated()), id: \.element) { index, id in
                    if index > 0 {
                        Text("/")
                            .font(DiskMapType.figureSmall)
                            .foregroundStyle(DiskMapTheme.ink3)
                            .accessibilityHidden(true)
                    }
                    Button(tree.name(of: id)) { jump(id) }
                        .buttonStyle(.plain)
                        .font(id == currentNode ? DiskMapType.bodyEmphasis : DiskMapType.body)
                        .foregroundStyle(id == currentNode ? DiskMapTheme.ink : DiskMapTheme.ink2)
                        .lineLimit(1)
                }
            }
        }
    }
}
