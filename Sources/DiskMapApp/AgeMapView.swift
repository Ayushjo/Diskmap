import DiskMapCore
import SwiftUI

struct AgeMapView: View {
    @ObservedObject var model: ScanModel
    let tree: FileTree
    let totals: [Int64]
    let rootURL: URL

    @State private var checked: Set<Int32> = []

    private var today: Int32 { AgeMap.today() }

    private var bucketSizes: [AgeBucket: Int64] {
        guard totals.count == tree.count else { return [:] }
        return AgeMap.bucketSizes(in: tree, totals: totals, today: today)
    }

    private var untouched: [Int32] {
        guard totals.count == tree.count else { return [] }
        return AgeMap.untouched(in: tree, totals: totals, today: today)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heatmap
                .frame(minHeight: 180, maxHeight: 260)
                .padding(8)
            HStack {
                Text("Forgotten files (1+ year)")
                    .font(.headline)
                    .foregroundStyle(DiskMapTheme.ink)
                Spacer()
                Button("Add selected to review") { Task { await stageSelected() } }
                    .disabled(checked.isEmpty)
            }
            .padding(.horizontal, 8)
            List(untouched, id: \.self) { id in
                Toggle(isOn: binding(id)) {
                    HStack {
                        Text(tree.path(of: id, root: rootURL).path)
                            .foregroundStyle(DiskMapTheme.ink)
                            .lineLimit(1)
                        Spacer()
                        Text(diskByteString(totals[Int(id)]))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                }
                .listRowBackground(id == model.selectedNode ? DiskMapTheme.ink.opacity(0.08) : Color.clear)
                .onTapGesture {
                    model.selectedNode = id
                }
                .onTapGesture(count: 2) {
                    model.selectedNode = id
                    revealDownloadedFile(id, tree: tree, root: rootURL)
                }
            }
            .scrollContentBackground(.hidden)
            .background(DiskMapTheme.cream)
        }
        .background(DiskMapTheme.cream)
    }

    private var heatmap: some View {
        Canvas { context, size in
            let items = AgeBucket.allCases.enumerated().compactMap { index, bucket -> (id: Int32, size: Int64)? in
                let bytes = bucketSizes[bucket] ?? 0
                guard bytes > 0 else { return nil }
                return (Int32(index), bytes)
            }
            let rects = SquarifiedTreemap.layout(items: items, in: CGRect(origin: .zero, size: size))
            for rect in rects {
                let bucket = AgeBucket.allCases[Int(rect.id)]
                let path = Path(rect.rect.insetBy(dx: 1, dy: 1))
                context.fill(path, with: .color(heatColor(bucket)))
                if rect.rect.width > 72 && rect.rect.height > 28 {
                    let bytes = bucketSizes[bucket] ?? 0
                    context.draw(
                        Text("\(bucket.title)\n\(diskByteString(bytes))")
                            .font(.caption)
                            .foregroundStyle(.white),
                        at: CGPoint(x: rect.rect.midX, y: rect.rect.midY)
                    )
                }
            }
        }
    }

    private func heatColor(_ bucket: AgeBucket) -> Color {
        switch bucket {
        case .under30: return Color(hue: 0.42, saturation: 0.45, brightness: 0.72)
        case .days30to90: return Color(hue: 0.38, saturation: 0.5, brightness: 0.62)
        case .days90to365: return Color(hue: 0.12, saturation: 0.55, brightness: 0.78)
        case .oneToTwoYears: return Color(hue: 0.06, saturation: 0.65, brightness: 0.72)
        case .overTwoYears: return Color(hue: 0.02, saturation: 0.7, brightness: 0.55)
        case .unknown: return Color.gray.opacity(0.7)
        }
    }

    private func binding(_ id: Int32) -> Binding<Bool> {
        Binding(
            get: { checked.contains(id) },
            set: { isOn in
                if isOn { checked.insert(id) } else { checked.remove(id) }
            }
        )
    }

    private func stageSelected() async {
        for id in checked {
            guard id >= 0, Int(id) < totals.count else { continue }
            let url = tree.path(of: id, root: rootURL)
            _ = await model.cleanupQueue.stage(url, size: totals[Int(id)], reason: "big & untouched")
        }
        checked.removeAll()
        await model.refreshQueue()
    }
}
