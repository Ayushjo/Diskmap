import AppKit
import DiskMapCore
import SwiftUI

func nodeColor(id: Int32?) -> Color {
    guard let id else { return Color.gray.opacity(0.55) }
    let hash = Int(id) &* 2654435761
    let hue = Double(abs(hash) % 360) / 360.0
    return Color(hue: hue, saturation: 0.55, brightness: 0.82)
}

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
            HStack(spacing: 4) {
                ForEach(Array(chain.enumerated()), id: \.element) { index, id in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(DiskMapTheme.mutedLabel.opacity(0.7))
                    }
                    Button(tree.name(of: id)) { jump(id) }
                        .buttonStyle(.plain)
                        .font(id == currentNode ? .headline : .body)
                        .foregroundStyle(id == currentNode ? DiskMapTheme.ink : DiskMapTheme.mutedLabel)
                }
            }
        }
    }
}

struct DrillHeader: View {
    let tree: FileTree
    let currentNode: Int32
    let totals: [Int64]
    let jump: (Int32) -> Void

    var body: some View {
        HStack(spacing: 8) {
            BreadcrumbBar(tree: tree, currentNode: currentNode, jump: jump)
            Spacer(minLength: 8)
            if currentNode >= 0, Int(currentNode) < totals.count {
                Text(diskByteString(totals[Int(currentNode)]))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
        }
        .padding(8)
    }
}
