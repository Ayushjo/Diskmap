import DiskMapCore
import SwiftUI

struct AgeMapView: View {
    @ObservedObject var model: ScanModel
    let tree: FileTree
    let totals: [Int64]
    let rootURL: URL

    @State private var checked: Set<Int32> = []
    @State private var bucketSizes: [AgeBucket: Int64] = [:]
    @State private var untouched: [Int32] = []
    @State private var selectedBucket: AgeBucket?
    @State private var bucketFiles: [Int32] = []
    /// Rects the heatmap drew, for hit-testing taps.
    @State private var heatmapRects: [TreemapRect] = []

    private let today = AgeMap.today()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heatmap
                .frame(minHeight: 180, maxHeight: 260)
                .padding(8)
            HStack {
                Text(selectedBucket.map { "\($0.title)" } ?? "Big & Untouched")
                    .font(.headline)
                if selectedBucket != nil {
                    Button("Clear filter") { selectedBucket = nil }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                Spacer()
                Button("Stage Selected") { Task { await stageSelected() } }
                    .disabled(checked.isEmpty)
            }
            .padding(.horizontal, 8)
            List(listedIDs, id: \.self) { id in
                Toggle(isOn: binding(id)) {
                    HStack {
                        if tree.flags[Int(id)] & NodeFlags.notDownloaded != 0 {
                            Image(systemName: "icloud")
                                .foregroundStyle(.secondary)
                                .help("Not downloaded — revealing may trigger an iCloud download")
                        }
                        Text(tree.path(of: id, root: rootURL).path)
                            .lineLimit(1)
                        Spacer()
                        Text(diskByteString(totals[Int(id)]))
                            .foregroundStyle(.secondary)
                    }
                }
                .onTapGesture(count: 2) {
                    revealDownloadedFile(id, tree: tree, root: rootURL)
                }
            }
        }
        // Whole-tree aggregations — once per scan, not per body evaluation.
        .task(id: model.scanID) {
            checked = []
            selectedBucket = nil
            bucketFiles = []
            async let sizes = Task.detached(priority: .userInitiated) {
                AgeMap.bucketSizes(in: tree, totals: totals, today: today)
            }.value
            async let stale = Task.detached(priority: .userInitiated) {
                AgeMap.untouched(in: tree, totals: totals, today: today)
            }.value
            bucketSizes = await sizes
            untouched = await stale
        }
        .task(id: BucketKey(scanID: model.scanID, bucket: selectedBucket)) {
            guard let selectedBucket else {
                bucketFiles = []
                return
            }
            bucketFiles = await Task.detached(priority: .userInitiated) {
                AgeMap.files(in: tree, totals: totals, today: today, bucket: selectedBucket)
            }.value
        }
    }

    private struct BucketKey: Equatable {
        var scanID: UUID
        var bucket: AgeBucket?
    }

    private var listedIDs: [Int32] {
        selectedBucket == nil ? untouched : bucketFiles
    }

    private var heatmap: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                for rect in heatmapRects {
                    let bucket = AgeBucket.allCases[Int(rect.id)]
                    let path = Path(rect.rect.insetBy(dx: 1, dy: 1))
                    context.fill(path, with: .color(heatColor(bucket)))
                    if bucket == selectedBucket {
                        context.stroke(path, with: .color(.white), lineWidth: 2)
                    }
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
            .contentShape(Rectangle())
            .onTapGesture { point in
                guard let hitID = SquarifiedTreemap.hitTest(heatmapRects, at: point) else {
                    return
                }
                let bucket = AgeBucket.allCases[Int(hitID)]
                selectedBucket = selectedBucket == bucket ? nil : bucket
            }
            .onChange(of: proxy.size) { _, size in
                layoutRects(in: size)
            }
            .onAppear { layoutRects(in: proxy.size) }
            .onChange(of: bucketSizes) { _, _ in layoutRects(in: proxy.size) }
        }
        .accessibilityLabel("File age map")
    }

    private func layoutRects(in size: CGSize) {
        let items = AgeBucket.allCases.enumerated().compactMap { index, bucket -> (id: Int32, size: Int64)? in
            let bytes = bucketSizes[bucket] ?? 0
            guard bytes > 0 else { return nil }
            return (Int32(index), bytes)
        }
        heatmapRects = SquarifiedTreemap.layout(items: items, in: CGRect(origin: .zero, size: size))
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
