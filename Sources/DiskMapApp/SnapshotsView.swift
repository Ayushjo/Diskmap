import AppKit
import DiskMapCore
import SwiftUI

/// Explore → Snapshots: storage history and comparison workspace.
struct SnapshotsView: View {
    @ObservedObject var model: ScanModel
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
            case .all: return "All"
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
                DiskMapEmptyState(symbol: "camera", title: "Scan first, then save snapshots",
                                  message: "Snapshots record sizes over time so you can see what grew. They don’t copy your files.")
            } else {
                AdaptiveInspectorSplit(windowWidth: contentWidth, inspectionToken: selectedChangePath ?? selectedID, main: mainColumn, inspector: inspector)
            }
        }
        .background(DiskMapTheme.canvas)
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

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(eyebrow: "Explore", title: "Snapshots",
                       subtitle: "Sizes over time — save one, compare later. Snapshots record sizes, not files; they are not backups.") {
                Button { prepareSave() } label: { Label("Save Snapshot", systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.tree == nil)
            }
            .padding(.horizontal, 28)
            .padding(.top, DiskMapSpace.pageTop)
            .padding(.bottom, 16)
            Hairline()
            HStack(alignment: .top, spacing: 0) {
                historyPanel
                    .frame(width: 250)
                Rectangle().fill(DiskMapTheme.line).frame(width: 1)
                ScrollView {
                    compareWorkspace
                        .padding(.horizontal, 24)
                        .padding(.vertical, 18)
                }
            }
        }
    }

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                ForEach(ListFilter.allCases) { f in
                    let count = f == .all ? allRecords.count : allRecords.filter { $0.meta.favorite }.count
                    Chip(title: f.title, count: "\(count)", isOn: listFilter == f) { listFilter = f }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            ScrollView {
                VStack(spacing: 0) {
                    if visibleRecords.isEmpty {
                        Text(listFilter == .favorites ? "No favourites yet." : "No saved snapshots yet.")
                            .font(DiskMapType.secondary)
                            .foregroundStyle(DiskMapTheme.ink3)
                            .padding(.vertical, 20)
                    }
                    ForEach(visibleRecords) { rec in
                        historyRow(rec)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private func historyRow(_ rec: SnapshotRecord) -> some View {
        let selected = selectedID == rec.id
        return Button {
            selectedID = rec.id
            selectedChangePath = nil
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(rec.displayName)
                            .font(DiskMapType.bodyEmphasis)
                            .foregroundStyle(DiskMapTheme.ink)
                            .lineLimit(1)
                        if rec.meta.favorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: DiskMapType.scaled(9)))
                                .foregroundStyle(DiskMapTheme.ink3)
                                .accessibilityLabel("Favorite")
                        }
                    }
                    Text(rec.isCurrent ? "Now" : rec.header.capturedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(DiskMapType.figureSmall)
                        .foregroundStyle(DiskMapTheme.ink3)
                }
                Spacer(minLength: 4)
                Text(ByteFormat.string(rec.usedBytes))
                    .font(DiskMapType.figureSmall)
                    .foregroundStyle(DiskMapTheme.ink2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(RowBackground(selected: selected, hovering: false))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(rec.displayName), \(ByteFormat.string(rec.usedBytes)) used")
        .contextMenu {
            if !rec.isCurrent {
                Button("Compare with Previous") { compareWithPrevious(rec) }
                Button(rec.meta.favorite ? "Unfavorite" : "Favorite") { toggleFavorite(rec) }
                Divider()
                Button("Add to Cleanup…") { confirmDelete = rec }
            }
        }
    }

    private var compareWorkspace: some View {
        VStack(alignment: .leading, spacing: 20) {
            compareSelectors
            if isComparing {
                DiskMapLoadingState(title: "Comparing", detail: "Reading both snapshots.")
                    .frame(minHeight: 160)
            } else if let comparison, let ids = comparedIDs,
                      let before = record(ids.before), let after = record(ids.after) {
                SnapshotCompareView(
                    comparison: comparison, hotspots: hotspots,
                    beforeRecord: before, afterRecord: after,
                    browsePath: $browsePath, selectedPath: $selectedChangePath
                )
            } else {
                Text(records.isEmpty
                     ? "Save a snapshot now; compare it with a later scan to see what grew or shrank."
                     : "Pick two snapshots to see what changed between them.")
                    .font(DiskMapType.body)
                    .foregroundStyle(DiskMapTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let statusMessage {
                Text(statusMessage)
                    .font(DiskMapType.secondary)
                    .foregroundStyle(DiskMapTheme.ink3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: beforeID) { _, _ in scheduleCompare() }
        .onChange(of: afterID) { _, _ in scheduleCompare() }
    }

    private var compareSelectors: some View {
        HStack(spacing: 8) {
            MonoLabel("Compare")
            snapshotPicker("Before", selection: $beforeID)
            Button { swap(&beforeID, &afterID) } label: {
                Label("Swap Before and After", systemImage: "arrow.left.arrow.right")
            }
            .buttonStyle(IconButtonStyle(size: 24))
            .help("Swap Before and After")
            snapshotPicker("After", selection: $afterID)
            Spacer(minLength: 0)
        }
    }

    private func snapshotPicker(_ title: String, selection: Binding<String?>) -> some View {
        Picker(title, selection: selection) {
            Text("Select…").tag(String?.none)
            if let current = currentRecord {
                Text("Current scan (now)").tag(Optional(current.id))
            }
            ForEach(records) { rec in
                Text(rec.pickerLabel).tag(Optional(rec.id))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        // Shrinks (the label truncates) instead of forcing the page wider
        // than the window; long dates pushed the inspector off-screen.
        .frame(minWidth: 120, maxWidth: 280)
        .accessibilityLabel(title)
    }

    private var canCompare: Bool {
        guard let beforeID, let afterID, beforeID != afterID else { return false }
        return record(beforeID) != nil && record(afterID) != nil
    }

    private var inspector: some View {
        Group {
            if let entry = selectedEntry {
                changeInspector(entry)
            } else if let rec = selectedRecord {
                snapshotInspector(rec)
            } else {
                DiskMapEmptyState(symbol: "camera", title: "Select a snapshot or change", message: "Its details appear here.")
            }
        }
        .background(DiskMapTheme.canvas)
    }

    private func snapshotInspector(_ rec: SnapshotRecord) -> some View {
        InspectorColumn {
            InspectorHeader(name: rec.displayName, size: ByteFormat.string(rec.usedBytes) + " used",
                            detail: rec.isCurrent ? "Live — not saved yet" : rec.header.capturedAt.formatted(date: .abbreviated, time: .shortened)) {
                Image(systemName: "camera")
                    .font(.system(size: DiskMapType.scaled(16)))
                    .foregroundStyle(DiskMapTheme.ink2)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DiskMapTheme.ink.opacity(0.06)))
            }
            if !rec.meta.note.isEmpty && !rec.isCurrent { Note(label: "Note", text: rec.meta.note) }
            Hairline()
            if rec.freeBytes > 0 { FactRow(label: "Free", value: ByteFormat.string(rec.freeBytes)) }
            if rec.totalBytes > 0 { FactRow(label: "Capacity", value: ByteFormat.string(rec.totalBytes)) }
            if let files = rec.meta.fileCount, let folders = rec.meta.folderCount {
                FactRow(label: "Contents", value: countLabel(files, "file") + " · " + countLabel(folders, "folder"))
            }
            if let secs = rec.meta.scanSeconds { FactRow(label: "Scan time", value: String(format: "%.1f s", secs)) }
            FactRow(label: "Root", value: CanonicalPath.displayPath(absolutePath: rec.header.rootPath))
            if !rec.isCurrent {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Compare with Previous") { compareWithPrevious(rec) }
                        .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                    HStack(spacing: 2) {
                        Button { toggleFavorite(rec) } label: {
                            Label(rec.meta.favorite ? "Unfavorite" : "Favorite", systemImage: rec.meta.favorite ? "star.fill" : "star")
                        }
                        .help(rec.meta.favorite ? "Unfavorite" : "Favorite")
                        Spacer()
                        Menu {
                            Button("Add to Cleanup…") { confirmDelete = rec }
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 28, height: 28).contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .foregroundStyle(DiskMapTheme.ink2)
                        .accessibilityLabel("More actions")
                    }
                    .buttonStyle(IconButtonStyle())
                }
                .padding(.top, 4)
            }
        }
    }

    private func changeInspector(_ entry: SnapshotComparison.Entry) -> some View {
        let path = comparison?.absolutePath(of: entry) ?? entry.path
        let existsNow = FileManager.default.fileExists(atPath: path)
        let found: Int32? = {
            guard existsNow, let tree = model.tree, let root = model.rootURL,
                  case .found(let id) = FileQuery.node(atPath: path, tree: tree, rootPath: root.path) else { return nil }
            return id
        }()
        return InspectorColumn {
            InspectorHeader(name: entry.name, size: SnapshotCompareText.signed(entry.delta),
                            detail: SnapshotCompareText.beforeAfter(entry)) {
                Image(systemName: entry.isDirectory ? "folder" : "doc")
                    .font(.system(size: DiskMapType.scaled(16)))
                    .foregroundStyle(DiskMapTheme.ink2)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DiskMapTheme.ink.opacity(0.06)))
            }
            if let kind = entry.kind { KindBadge(kind: kind) }
            Hairline()
            FactRow(label: "Location", value: CanonicalPath.displayPath(absolutePath: path))
            FactRow(label: "Before", value: entry.beforeID == nil ? "Not there" : ByteFormat.string(entry.before))
            FactRow(label: "After", value: entry.afterID == nil ? "Gone" : ByteFormat.string(entry.after))
            if entry.before > 0, entry.after > 0 {
                FactRow(label: "Change", value: String(format: "%+.0f%%", Double(entry.delta) / Double(entry.before) * 100))
            }
            if !existsNow && entry.kind != .removed {
                Note(label: nil, text: "This isn't on disk any more.")
            }
            if entry.isDirectory {
                Button("Show What Changed Inside") { browsePath = entry.path }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true))
            }
            if existsNow {
                let staged = model.isStaged(URL(fileURLWithPath: path))
                InspectorActions(
                    primaryTitle: staged ? "In Cleanup" : "Add to Cleanup",
                    primaryDone: staged,
                    primaryEnabled: found != nil && entry.delta > 0,
                    primary: {
                        if staged { model.isCleanupQueuePresented = true } else if let id = found {
                            model.stageRow(path: path, size: model.selectedTotals[Int(id)], reason: "Grew since snapshot: \(entry.name)")
                        }
                    },
                    path: path
                ) {
                    if let id = found, let tree = model.tree {
                        Button("Show in File Browser") {
                            model.selectedNode = id
                            model.currentNode = tree.isDirectory[Int(id)] ? id : max(0, tree.parent[Int(id)])
                            model.destination = .fileBrowser
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private var saveSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save Snapshot")
                .font(DiskMapType.heading)
            Text("Save the current scan so you can compare your storage later. This does not copy or back up your files.")
                .font(DiskMapType.secondary)
                .foregroundStyle(DiskMapTheme.ink2)
            Text("Name")
                .font(DiskMapType.secondary.weight(.semibold))
                .foregroundStyle(DiskMapTheme.ink2)
            TextField("Snapshot name", text: $saveName)
                .textFieldStyle(.roundedBorder)
            Text("Optional note")
                .font(DiskMapType.secondary.weight(.semibold))
                .foregroundStyle(DiskMapTheme.ink2)
            TextField("e.g. Before cleaning Docker caches", text: $saveNote, axis: .vertical)
                .lineLimit(3...5)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showSave = false }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Save Snapshot") { saveSnapshot() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(DiskMapTheme.raised)
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
        model.showToast(result.added > 0 ? "Snapshot added to Cleanup — ⇧⌘⌫ to review" : "Snapshot is already in Cleanup")
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
}
