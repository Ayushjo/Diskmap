import AppKit
import DiskMapCore
import SwiftUI

/// Explore → Snapshots: storage history and comparison workspace.
struct SnapshotsView: View {
    @ObservedObject var model: ScanModel
    var onOpenCleanup: () -> Void = {}
    @Environment(\.diskMapContentWidth) private var contentWidth

    @State private var records: [SnapshotRecord] = []
    @State private var selectedID: String?
    @State private var beforeID: String?
    @State private var afterID: String?
    @State private var comparison: SnapshotComparison?
    @State private var hotspots: [SnapshotComparison.Entry] = []
    @State private var comparedIDs: (before: String, after: String)?
    @State private var browsePath = ""
    @State private var compareTask: Task<Void, Never>?
    @State private var isComparing = false
    @State private var showSave = false
    @State private var saveName = ""
    @State private var saveNote = ""
    @State private var selectedChangePath: String?
    @State private var listFilter: ListFilter = .all
    @State private var statusMessage: String?
    @State private var confirmDelete: SnapshotRecord?

    private enum ListFilter: String, CaseIterable, Identifiable {
        case all, favorites
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All Snapshots"
            case .favorites: return "Favorites"
            }
        }
    }

    private var allRecords: [SnapshotRecord] {
        var list = records
        if let current = currentRecord {
            list.insert(current, at: 0)
        }
        return list
    }

    private var visibleRecords: [SnapshotRecord] {
        switch listFilter {
        case .all: return allRecords
        case .favorites: return allRecords.filter { $0.meta.favorite }
        }
    }

    private var currentRecord: SnapshotRecord? {
        guard let root = model.rootURL, model.tree != nil else { return nil }
        let vol = VolumeStats.forPath(root.path)
        let meta = SnapshotMeta(
            name: "Current scan",
            note: "Live scan — save to keep a DiskMap analytical checkpoint.",
            favorite: false,
            volumeName: vol?.volumeName,
            totalBytes: vol?.totalBytes,
            freeBytes: vol?.freeBytes,
            usedBytes: vol?.usedBytes,
            scannedBytes: model.selectedTotals.first,
            fileCount: model.descendantFileCounts.first,
            folderCount: model.descendantFolderCounts.first,
            scanSeconds: model.lastScanSeconds
        )
        return SnapshotRecord(
            url: URL(fileURLWithPath: "/tmp/diskmap-current-scan"),
            header: SnapshotHeader(rootPath: root.path, capturedAt: Date()),
            meta: meta,
            isCurrent: true
        )
    }

    private var selectedRecord: SnapshotRecord? {
        allRecords.first { $0.id == selectedID } ?? visibleRecords.first
    }

    private func record(_ id: String?) -> SnapshotRecord? {
        guard let id else { return nil }
        return allRecords.first { $0.id == id }
    }

    private var selectedEntry: SnapshotComparison.Entry? {
        guard let comparison, let selectedChangePath else { return nil }
        return comparison.entry(atPath: selectedChangePath)
    }

    var body: some View {
        Group {
            if model.tree == nil && records.isEmpty {
                emptyNoScan
            } else {
                AdaptiveInspectorSplit(windowWidth: contentWidth, inspectionToken: selectedChangePath ?? selectedID, main: mainColumn, inspector: inspector)
            }
        }
        .background(DiskMapTheme.cream)
        .task { reload() }
        .sheet(isPresented: $showSave) { saveSheet }
        .confirmationDialog(
            "Add snapshot to Cleanup?",
            isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Add to Cleanup") {
                if let rec = confirmDelete { Task { await stageSnapshot(rec) } }
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("The saved analysis and its metadata will be reviewed in Cleanup before either file moves to Trash. Your scanned files are not affected.")
        }
    }

    private var emptyNoScan: some View {
        VStack(spacing: 12) {
            Text("Snapshots")
                .font(DiskMapType.title)
            Text("Scan a folder first, then save a DiskMap snapshot to track storage over time.")
                .font(DiskMapType.body)
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .multilineTextAlignment(.center)
            Text("A DiskMap snapshot records your storage analysis. It does not copy or back up your files.")
                .font(DiskMapType.caption)
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mainColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if records.isEmpty && currentRecord != nil {
                    compactFirstUseTip
                }
                HStack(alignment: .top, spacing: 14) {
                    historyPanel
                        .frame(width: 280)
                    compareWorkspace
                }
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Snapshots")
                    .font(DiskMapType.title)
                    .foregroundStyle(DiskMapTheme.ink)
                Text("Track how your storage changes over time. Save a snapshot after important changes and compare it later.")
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button {
                prepareSave()
            } label: {
                Label("Save Snapshot", systemImage: "plus")
            }
            .buttonStyle(InkButtonStyle())
            .disabled(model.tree == nil)
        }
    }

    private var compactFirstUseTip: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(DiskMapTheme.info)
            Text("Save a snapshot to start history. Comparing later shows what grew or shrank — snapshots are analytical, not backups.")
                .font(DiskMapType.small)
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DiskMapTheme.info.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(DiskMapTheme.info.opacity(0.2), lineWidth: 1)
                )
        )
    }

    private var firstUseBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Storage History")
                .font(DiskMapType.bodyStrong)
            Text("Save a snapshot now, then compare it with a future scan to see exactly what grew or shrank.")
                .font(DiskMapType.small)
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Text("A DiskMap snapshot records your storage analysis. It does not copy or back up your files.")
                .font(DiskMapType.caption)
                .foregroundStyle(DiskMapTheme.info)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DiskMapTheme.info.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DiskMapTheme.info.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(ListFilter.allCases) { f in
                    let count = f == .all ? allRecords.count : allRecords.filter { $0.meta.favorite }.count
                    Button {
                        listFilter = f
                    } label: {
                        Text("\(f.title) \(count)")
                            .font(.system(size: DiskMapType.scaled(11), weight: listFilter == f ? .semibold : .regular))
                            .foregroundStyle(listFilter == f ? DiskMapTheme.ink : DiskMapTheme.mutedLabel)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(listFilter == f ? DiskMapTheme.navSelected : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            if visibleRecords.isEmpty {
                Text("No saved snapshots yet.")
                    .font(DiskMapType.small)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .padding(.vertical, 20)
            } else {
                ForEach(visibleRecords) { rec in
                    historyRow(rec)
                }
            }

            Text("DiskMap snapshots are analytical checkpoints — not Time Machine or APFS filesystem snapshots.")
                .font(DiskMapType.micro)
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .padding(.top, 8)
        }
        .padding(12)
        .background(cardBG)
    }

    private func historyRow(_ rec: SnapshotRecord) -> some View {
        let selected = selectedID == rec.id
        return Button {
            selectedID = rec.id
            selectedChangePath = nil
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: DiskMapType.scaled(16)))
                    .foregroundStyle(DiskMapTheme.info)
                    .frame(width: 28, height: 28)
                    .background(DiskMapTheme.navSelected, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(rec.displayName)
                            .font(DiskMapType.smallStrong)
                            .foregroundStyle(DiskMapTheme.ink)
                            .lineLimit(1)
                        if rec.isCurrent {
                            Text("Current")
                                .font(.system(size: DiskMapType.scaled(9), weight: .semibold))
                                .foregroundStyle(DiskMapTheme.info)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(DiskMapTheme.info.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(rec.header.capturedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(DiskMapType.micro)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                    Text("\(ByteFormat.string(rec.usedBytes)) used")
                        .font(DiskMapType.captionMedium.monospacedDigit())
                        .foregroundStyle(DiskMapTheme.ink)
                    if rec.freeBytes > 0 {
                        Text("\(ByteFormat.string(rec.freeBytes)) free")
                            .font(DiskMapType.micro)
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                }
                Spacer(minLength: 0)
                if !rec.isCurrent {
                    Menu {
                        Button("Compare with previous") { compareWithPrevious(rec) }
                        Button(rec.meta.favorite ? "Unfavorite" : "Favorite") { toggleFavorite(rec) }
                        Button("Add to Cleanup…") { confirmDelete = rec }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(DiskMapType.smallStrong)
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                            .frame(width: 24, height: 24)
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? DiskMapTheme.navSelected : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var compareWorkspace: some View {
        VStack(alignment: .leading, spacing: 14) {
            compareSelectors
            if isComparing {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Reading both snapshots…")
                        .font(DiskMapType.caption)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
                .background(SnapshotCompareText.card)
            } else if let comparison, let ids = comparedIDs,
                      let before = record(ids.before), let after = record(ids.after) {
                SnapshotCompareView(
                    comparison: comparison, hotspots: hotspots,
                    beforeRecord: before, afterRecord: after,
                    browsePath: $browsePath, selectedPath: $selectedChangePath
                )
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(records.isEmpty ? "Save a snapshot to compare against later." : "Pick two snapshots to see what changed between them.")
                        .font(DiskMapType.body)
                        .foregroundStyle(DiskMapTheme.ink)
                    Text("You'll see the net change, the handful of places it actually happened, and a drill-down whose rows always add up.")
                        .font(DiskMapType.caption)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SnapshotCompareText.card)
            }
            if let statusMessage {
                Text(statusMessage)
                    .font(DiskMapType.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: beforeID) { _, _ in scheduleCompare() }
        .onChange(of: afterID) { _, _ in scheduleCompare() }
    }

    private var compareSelectors: some View {
        HStack(alignment: .bottom, spacing: 10) {
            snapshotPicker("Before", selection: $beforeID)
            Button {
                swap(&beforeID, &afterID)
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(DiskMapType.captionStrong)
                    .frame(width: 30, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(DiskMapTheme.navSelected))
            }
            .buttonStyle(.plain)
            .help("Swap Before and After")
            .padding(.bottom, 1)
            snapshotPicker("After", selection: $afterID)
        }
        .padding(14)
        .background(cardBG)
    }

    private func snapshotPicker(_ title: String, selection: Binding<String?>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(DiskMapType.microStrong)
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Picker("", selection: selection) {
                Text("Select…").tag(String?.none)
                if let current = currentRecord {
                    Text("Current scan (now)").tag(Optional(current.id))
                }
                ForEach(records) { rec in
                    Text(rec.pickerLabel).tag(Optional(rec.id))
                }
            }
            .labelsHidden()
            .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
        }
    }

    private var canCompare: Bool {
        guard let beforeID, let afterID, beforeID != afterID else { return false }
        return record(beforeID) != nil && record(afterID) != nil
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let entry = selectedEntry {
                    changeInspector(entry)
                } else if let rec = selectedRecord {
                    snapshotInspector(rec)
                } else {
                    Text("Select a snapshot or change")
                        .font(DiskMapType.bodyStrong)
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
            }
            .padding(16)
        }
        .background(DiskMapTheme.inspectorFill)
    }

    private func snapshotInspector(_ rec: SnapshotRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(rec.displayName)
                .font(DiskMapType.headline)
            if rec.isCurrent {
                Text("Current")
                    .font(DiskMapType.microStrong)
                    .foregroundStyle(DiskMapTheme.info)
            }
            Text(ByteFormat.string(rec.usedBytes) + " used")
                .font(DiskMapType.title.monospacedDigit())
            if !rec.meta.note.isEmpty {
                Text(rec.meta.note)
                    .font(DiskMapType.small)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
            VStack(alignment: .leading, spacing: 6) {
                StatRow(label: "Captured", value: rec.header.capturedAt.formatted(date: .abbreviated, time: .shortened))
                if rec.freeBytes > 0 {
                    StatRow(label: "Free", value: ByteFormat.string(rec.freeBytes))
                }
                if rec.totalBytes > 0 {
                    StatRow(label: "Capacity", value: ByteFormat.string(rec.totalBytes))
                }
                if let files = rec.meta.fileCount {
                    StatRow(label: "Files", value: Self.formatCount(files))
                }
                if let folders = rec.meta.folderCount {
                    StatRow(label: "Folders", value: Self.formatCount(folders))
                }
                if let secs = rec.meta.scanSeconds {
                    StatRow(label: "Scan time", value: String(format: "%.1fs", secs))
                }
                StatRow(label: "Root", value: CanonicalPath.displayPath(absolutePath: rec.header.rootPath))
            }
            .padding(12)
            .background(cardBG)

            if !rec.isCurrent {
                Button("Compare with previous") { compareWithPrevious(rec) }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                Button("Add snapshot to Cleanup…") { confirmDelete = rec }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
            } else {
                Button("Save Snapshot") { prepareSave() }
                    .buttonStyle(InkButtonStyle(fullWidth: true))
            }
        }
    }

    private func changeInspector(_ entry: SnapshotComparison.Entry) -> some View {
        let path = comparison?.absolutePath(of: entry) ?? entry.path
        let existsNow = FileManager.default.fileExists(atPath: path)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(entry.name)
                    .font(DiskMapType.headline)
                    .lineLimit(2)
                if let kind = entry.kind { KindBadge(kind: kind) }
            }
            Text(SnapshotCompareText.signed(entry.delta))
                .font(.system(size: DiskMapType.scaled(26), weight: .semibold).monospacedDigit())
                .foregroundStyle(SnapshotCompareText.color(for: entry.delta))
            Text(CanonicalPath.displayPath(absolutePath: path))
                .font(DiskMapType.caption)
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 6) {
                StatRow(label: "Before", value: entry.beforeID == nil ? "Not there" : ByteFormat.string(entry.before))
                StatRow(label: "After", value: entry.afterID == nil ? "Gone" : ByteFormat.string(entry.after))
                if entry.before > 0, entry.after > 0 {
                    StatRow(label: "Change", value: String(format: "%+.0f%%", Double(entry.delta) / Double(entry.before) * 100))
                }
            }
            .padding(12)
            .background(cardBG)
            if entry.isDirectory {
                Button("Show what changed inside") { browsePath = entry.path }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
            }
            if existsNow {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                if let tree = model.tree, let root = model.rootURL,
                   case .found(let id) = FileQuery.node(atPath: path, tree: tree, rootPath: root.path) {
                    Button("Show in File Browser") {
                        model.selectedNode = id
                        model.currentNode = tree.isDirectory[Int(id)] ? id : max(0, tree.parent[Int(id)])
                        model.destination = .fileBrowser
                    }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                    if entry.delta > 0 {
                        Button("Add to Cleanup") {
                            model.stageRow(path: path, size: model.selectedTotals[Int(id)], reason: "Grew since snapshot: \(entry.name)")
                        }
                        .buttonStyle(InkButtonStyle(fullWidth: true))
                    }
                }
            } else if entry.kind != .removed {
                Text("This isn't on disk any more.")
                    .font(DiskMapType.caption)
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
        }
    }

    private var saveSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save Snapshot")
                .font(DiskMapType.headline)
            Text("Save the current scan so you can compare your storage later. This does not copy or back up your files.")
                .font(DiskMapType.small)
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Text("Name")
                .font(DiskMapType.captionStrong)
                .foregroundStyle(DiskMapTheme.mutedLabel)
            TextField("Snapshot name", text: $saveName)
                .textFieldStyle(.roundedBorder)
            Text("Optional note")
                .font(DiskMapType.captionStrong)
                .foregroundStyle(DiskMapTheme.mutedLabel)
            TextField("e.g. Before cleaning Docker caches", text: $saveNote, axis: .vertical)
                .lineLimit(3...5)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showSave = false }
                    .buttonStyle(InkButtonStyle(filled: false))
                Button("Save Snapshot") { saveSnapshot() }
                    .buttonStyle(InkButtonStyle())
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var cardBG: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(DiskMapTheme.cardFill)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
            )
    }

    // MARK: - Actions

    private func reload() {
        guard let root = model.rootURL else {
            records = []
            return
        }
        records = SnapshotStore.records(in: SnapshotStore.defaultDirectory(), rootPath: root.path)
        if selectedID == nil {
            selectedID = currentRecord?.id ?? records.first?.id
        }
        if beforeID == nil, records.count >= 1 {
            beforeID = records.last?.id // oldest among recent? records sorted newest first → last is oldest
            if records.count >= 2 {
                beforeID = records[1].id // previous
            }
        }
        if afterID == nil {
            afterID = currentRecord?.id ?? records.first?.id
        }
    }

    private func prepareSave() {
        saveName = SnapshotMeta.defaultName(for: Date())
        saveNote = ""
        showSave = true
    }

    private func saveSnapshot() {
        guard let tree = model.tree, let root = model.rootURL else { return }
        let vol = VolumeStats.forPath(root.path)
        let meta = SnapshotMeta(
            name: saveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? SnapshotMeta.defaultName(for: Date())
                : saveName.trimmingCharacters(in: .whitespacesAndNewlines),
            note: saveNote.trimmingCharacters(in: .whitespacesAndNewlines),
            volumeName: vol?.volumeName,
            totalBytes: vol?.totalBytes,
            freeBytes: vol?.freeBytes,
            usedBytes: vol?.usedBytes,
            scannedBytes: model.selectedTotals.first,
            fileCount: model.descendantFileCounts.first,
            folderCount: model.descendantFolderCounts.first,
            scanSeconds: model.lastScanSeconds,
            diskMapVersion: "DiskMap"
        )
        let snapshot = DiskSnapshot(rootPath: root.path, capturedAt: Date(), tree: tree)
        do {
            let url = try SnapshotStore.save(snapshot, meta: meta, in: SnapshotStore.defaultDirectory())
            showSave = false
            reload()
            selectedID = url.path
            statusMessage = "Snapshot saved"
            model.showToast("Snapshot saved")
        } catch {
            statusMessage = "Could not save snapshot"
        }
    }

    private func stageSnapshot(_ rec: SnapshotRecord) async {
        guard !rec.isCurrent else { return }
        let metaURL = SnapshotStore.metaURL(for: rec.url)
        let urls = [rec.url, metaURL].filter { FileManager.default.fileExists(atPath: $0.path) }
        let requests = urls.map { url in
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            let size = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            return CleanupStageRequest(url: url, size: size, reason: "Saved snapshot: \(rec.displayName)")
        }
        let result = await model.stageForCleanup(requests)
        confirmDelete = nil
        model.showToast(result.added > 0 ? "Snapshot added to Cleanup" : "Snapshot is already in Cleanup")
        onOpenCleanup()
    }

    private func toggleFavorite(_ rec: SnapshotRecord) {
        var meta = rec.meta
        meta.favorite.toggle()
        try? SnapshotStore.saveMeta(meta, for: rec.url)
        reload()
    }

    private func compareWithPrevious(_ rec: SnapshotRecord) {
        afterID = rec.id
        if let idx = records.firstIndex(where: { $0.id == rec.id }), idx + 1 < records.count {
            beforeID = records[idx + 1].id
        } else if records.count >= 2 {
            beforeID = records[1].id
        }
        scheduleCompare()
    }

    /// Selection changes land here; a newer choice cancels an older compare.
    private func scheduleCompare() {
        compareTask?.cancel()
        guard canCompare else { return }
        compareTask = Task { await runCompare() }
    }

    /// Loading two trees and rolling both up takes seconds on a large home,
    /// so it runs off the main thread (it used to freeze the window).
    private func runCompare() async {
        guard canCompare, let beforeID, let afterID,
              let beforeRec = record(beforeID), let afterRec = record(afterID) else { return }
        if let done = comparedIDs, done.before == beforeID, done.after == afterID, comparison != nil { return }
        isComparing = true
        statusMessage = nil
        let basis = model.sizeBasis
        let current = model.tree.flatMap { tree in model.rootURL.map { DiskSnapshot(rootPath: $0.path, capturedAt: Date(), tree: tree) } }
        let work = Task.detached(priority: .userInitiated) { () -> (SnapshotComparison, [SnapshotComparison.Entry])? in
            func load(_ rec: SnapshotRecord) -> DiskSnapshot? {
                rec.isCurrent ? current : try? SnapshotStore.load(from: rec.url)
            }
            guard let before = load(beforeRec), !Task.isCancelled, let after = load(afterRec), !Task.isCancelled else { return nil }
            let built = SnapshotComparison(before: before, after: after, basis: basis)
            return (built, built.hotspots(minimumChange: built.defaultMinimumChange, limit: 25))
        }
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard !Task.isCancelled else { return }
        isComparing = false
        guard let (built, spots) = result else {
            comparison = nil
            statusMessage = "Could not read those snapshots"
            return
        }
        comparison = built
        hotspots = spots
        comparedIDs = (beforeID, afterID)
        browsePath = ""
        selectedChangePath = spots.first?.path
    }

    private func signed(_ delta: Int64) -> String {
        let sign = delta >= 0 ? "+" : "−"
        return "\(sign)\(ByteFormat.string(abs(delta)))"
    }
}


private extension SnapshotsView {
    static func formatCount(_ n: Int) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

private extension DiskMapTheme {
    static func color(forHint hint: String) -> Color {
        switch hint {
        case "apps": return folderPastels[4]
        case "library": return folderPastels[0]
        case "downloads": return folderPastels[1]
        case "documents": return folderPastels[5]
        case "developer": return folderPastels[2]
        case "caches": return folderPastels[3]
        case "system": return mutedLabel
        default: return info
        }
    }
}
