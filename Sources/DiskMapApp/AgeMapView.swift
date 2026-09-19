import DiskMapCore
import SwiftUI

struct AgeMapView: View {
    @ObservedObject var model: ScanModel
    let tree: FileTree
    let totals: [Int64]
    let rootURL: URL
    /// When true (Find → Forgotten), emphasize the candidate list and total bytes.
    var findWorkflow: Bool = false

    @State private var checked: Set<Int32> = []
    @State private var filterBucket: AgeBucket? = nil
    @State private var bucketSizes: [AgeBucket: Int64] = [:]
    @State private var untouched: [Int32] = []
    @State private var isPreparing = true

    private var today: Int32 { AgeMap.today() }

    private var filteredUntouched: [Int32] {
        guard let filterBucket else { return untouched }
        return untouched.filter { id in
            AgeMap.bucket(modifiedDay: tree.modifiedDay[Int(id)], today: today) == filterBucket
        }
    }

    private var forgottenBytes: Int64 {
        if model.analysis.forgottenBytes > 0 {
            return model.analysis.forgottenBytes
        }
        return untouched.reduce(Int64(0)) { partial, id in
            let i = Int(id)
            return partial + (i < totals.count ? totals[i] : 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isPreparing {
                DiskMapLoadingState(title: "Preparing Age Map", detail: "Grouping modification dates off the main thread.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                heatmap
                    .frame(minHeight: findWorkflow ? 140 : 180, maxHeight: findWorkflow ? 200 : 260)
                    .padding(8)

                summaryBar
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)

                bucketChips
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)

                Divider().overlay(DiskMapTheme.cardStroke)

                if filteredUntouched.isEmpty {
                    emptyState
                } else {
                    listHeader
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    candidateList
                }
            }
        }
        .background(DiskMapTheme.cream)
        .task(id: totals.count) {
            await prepareAgeMap()
        }
    }

    @MainActor
    private func prepareAgeMap() async {
        guard totals.count == tree.count else {
            bucketSizes = [:]
            untouched = []
            isPreparing = false
            return
        }
        isPreparing = true
        let sourceTree = tree
        let sourceTotals = totals
        let referenceDay = today
        let result = await Task.detached(priority: .utility) {
            let buckets = AgeMap.bucketSizes(in: sourceTree, totals: sourceTotals, today: referenceDay)
            guard !Task.isCancelled else { return ([AgeBucket: Int64](), [Int32]()) }
            let candidates = AgeMap.untouched(in: sourceTree, totals: sourceTotals, today: referenceDay, limit: 200)
            return (buckets, candidates)
        }.value
        guard !Task.isCancelled else { return }
        bucketSizes = result.0
        untouched = result.1
        isPreparing = false
    }

    private var summaryBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Forgotten files")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.ink)
                Text("Not modified in over a year · based on modification date")
                    .font(DiskMapType.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormat.string(forgottenBytes))
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DiskMapTheme.ink)
                Text("\(filteredUntouched.count) candidates")
                    .font(DiskMapType.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DiskMapTheme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                )
        )
    }

    private var bucketChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(title: "All forgotten", bucket: nil, bytes: forgottenBytes)
                ForEach(forgottenBuckets, id: \.self) { bucket in
                    chip(title: bucket.shortTitle, bucket: bucket, bytes: bucketSizes[bucket] ?? 0)
                }
            }
        }
    }

    private var forgottenBuckets: [AgeBucket] {
        [.oneToTwoYears, .overTwoYears].filter { (bucketSizes[$0] ?? 0) > 0 }
    }

    private func chip(title: String, bucket: AgeBucket?, bytes: Int64) -> some View {
        let selected = filterBucket == bucket
        return Button {
            filterBucket = bucket
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                if bytes > 0 {
                    Text(ByteFormat.string(bytes))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .opacity(0.85)
                }
            }
            .foregroundStyle(selected ? Color.white : DiskMapTheme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(selected ? DiskMapTheme.ink : DiskMapTheme.cardFill)
                    .overlay(Capsule().stroke(DiskMapTheme.cardStroke, lineWidth: selected ? 0 : 1))
            )
        }
        .buttonStyle(.plain)
    }

    private var listHeader: some View {
        HStack {
            Text("Largest forgotten files")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DiskMapTheme.ink)
            Spacer()
            Button("Add selected to review") { Task { await stageSelected() } }
                .buttonStyle(InkButtonStyle(filled: false))
                .disabled(checked.isEmpty)
            if findWorkflow {
                Button("Open Age Map in Explore") {
                    model.exploreMode = .ageMap
                    model.destination = .visualize
                }
                .buttonStyle(InkButtonStyle())
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            if untouched.isEmpty {
                Text("No forgotten files in this scan")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.ink)
                Text("Nothing larger than zero bytes was unmodified for over a year. Try another folder, or check Age Map after a broader scan.")
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            } else {
                Text("No files in this age bucket")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.ink)
                Text("Clear the filter or pick another age chip.")
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var candidateList: some View {
        List(filteredUntouched, id: \.self) { id in
            candidateRow(id)
                .listRowBackground(id == model.selectedNode ? DiskMapTheme.ink.opacity(0.08) : Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(DiskMapTheme.cream)
    }

    private func candidateRow(_ id: Int32) -> some View {
        let size = totals.indices.contains(Int(id)) ? totals[Int(id)] : 0
        let day = tree.modifiedDay[Int(id)]
        let bucket = AgeMap.bucket(modifiedDay: day, today: today)
        return HStack(alignment: .center, spacing: 10) {
            Toggle(isOn: binding(id)) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.checkbox)

            Button {
                selectForInspect(id)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tree.name(of: id))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                        .lineLimit(1)
                    Text(tree.path(of: id, root: rootURL).path)
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        Text(bucket.shortTitle)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(heatColor(bucket).opacity(0.18)))
                            .foregroundStyle(DiskMapTheme.ink)
                        Text(relativeAge(day))
                            .font(DiskMapType.caption)
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(ByteFormat.string(size))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(DiskMapTheme.ink)

            Menu {
                Button("Inspect") { selectForInspect(id) }
                Button("Show in Explore") { openInExplore(id) }
                Button("Reveal in Finder") { revealDownloadedFile(id, tree: tree, root: rootURL) }
                Button("Add to review") { Task { await stageOne(id) } }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.vertical, 4)
        .onTapGesture(count: 2) {
            openInExplore(id)
        }
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
                if rect.rect.width > 56 && rect.rect.height > 24 {
                    let bytes = bucketSizes[bucket] ?? 0
                    context.draw(
                        Text("\(bucket.shortTitle)\n\(diskByteString(bytes))")
                            .font(.caption)
                            .foregroundStyle(.white),
                        at: CGPoint(x: rect.rect.midX, y: rect.rect.midY)
                    )
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DiskMapTheme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                )
        )
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

    private func relativeAge(_ day: Int32) -> String {
        guard day > 0 else { return "No modification date" }
        let ageDays = today - day
        if ageDays >= 730 {
            let years = ageDays / 365
            return "~\(years)y ago"
        }
        if ageDays >= 365 {
            return "1–2y ago"
        }
        return "\(ageDays)d ago"
    }

    private func binding(_ id: Int32) -> Binding<Bool> {
        Binding(
            get: { checked.contains(id) },
            set: { isOn in
                if isOn { checked.insert(id) } else { checked.remove(id) }
            }
        )
    }

    private func selectForInspect(_ id: Int32) {
        model.selectedNode = id
        let parent = tree.parent[Int(id)]
        if parent >= 0 {
            model.currentNode = parent
        }
    }

    private func openInExplore(_ id: Int32) {
        selectForInspect(id)
        model.exploreMode = .ageMap
        model.destination = .visualize
    }

    private func stageOne(_ id: Int32) async {
        guard id >= 0, Int(id) < totals.count else { return }
        let url = tree.path(of: id, root: rootURL)
        if model.isStaged(url) {
            model.showToast("Already in cleanup list")
            return
        }
        _ = await model.cleanupQueue.stage(url, size: totals[Int(id)], reason: "big & untouched")
        await model.refreshQueue()
        model.showToast("Added to Cleanup")
    }

    private func stageSelected() async {
        for id in checked {
            guard id >= 0, Int(id) < totals.count else { continue }
            let url = tree.path(of: id, root: rootURL)
            if model.isStaged(url) { continue }
            _ = await model.cleanupQueue.stage(url, size: totals[Int(id)], reason: "big & untouched")
        }
        checked.removeAll()
        await model.refreshQueue()
        model.showToast("Added to Cleanup")
    }
}
