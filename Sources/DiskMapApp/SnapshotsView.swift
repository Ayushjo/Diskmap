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
    @State private var report: SnapshotCompareReport = .empty
    @State private var isComparing = false
    @State private var showSave = false
    @State private var saveName = ""
    @State private var saveNote = ""
    @State private var changeFilter: ChangeFilter = .all
    @State private var changeQuery = ""
    @State private var minDelta: Int64 = 100_000_000
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

    private enum ChangeFilter: String, CaseIterable, Identifiable {
        case all, added, removed, grew, shrunk
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .added: return "Added"
            case .removed: return "Removed"
            case .grew: return "Grew"
            case .shrunk: return "Shrank"
            }
        }
        var kind: SnapshotChangeKind? {
            switch self {
            case .all: return nil
            case .added: return .added
            case .removed: return .removed
            case .grew: return .grew
            case .shrunk: return .shrunk
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

    private var visibleChanges: [SnapshotChange] {
        SnapshotCompare.filterChanges(
            report.folderChanges,
            kind: changeFilter.kind,
            query: changeQuery,
            minAbsDelta: minDelta
        )
    }

    private var selectedChange: SnapshotChange? {
        if let selectedChangePath {
            return visibleChanges.first { $0.path == selectedChangePath }
                ?? report.folderChanges.first { $0.path == selectedChangePath }
        }
        return visibleChanges.first
    }

    var body: some View {
        Group {
            if model.tree == nil && records.isEmpty {
                emptyNoScan
            } else {
                HStack(spacing: 0) {
                    mainColumn
                    Divider().overlay(DiskMapTheme.cardStroke)
                    inspector
                        .frame(width: DiskMapLayout.inspectorWidth(for: contentWidth))
                }
            }
        }
        .background(DiskMapTheme.cream)
        .task { reload() }
        .sheet(isPresented: $showSave) { saveSheet }
        .confirmationDialog(
            "Delete snapshot?",
            isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Snapshot", role: .destructive) {
                if let rec = confirmDelete { delete(rec) }
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("This only removes the saved DiskMap storage analysis. Your files will not be affected.")
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
                .font(.system(size: 11))
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
            .buttonStyle(PrimaryCTAStyle())
            .disabled(model.tree == nil)
        }
    }

    private var compactFirstUseTip: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(DiskMapTheme.info)
            Text("Save a snapshot to start history. Comparing later shows what grew or shrank — snapshots are analytical, not backups.")
                .font(.system(size: 12))
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
                .font(.system(size: 13, weight: .semibold))
            Text("Save a snapshot now, then compare it with a future scan to see exactly what grew or shrank.")
                .font(.system(size: 12))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Text("A DiskMap snapshot records your storage analysis. It does not copy or back up your files.")
                .font(.system(size: 11))
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
                            .font(.system(size: 11, weight: listFilter == f ? .semibold : .regular))
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
                    .font(.system(size: 12))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .padding(.vertical, 20)
            } else {
                ForEach(visibleRecords) { rec in
                    historyRow(rec)
                }
            }

            Text("DiskMap snapshots are analytical checkpoints — not Time Machine or APFS filesystem snapshots.")
                .font(.system(size: 10))
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
                    .font(.system(size: 16))
                    .foregroundStyle(DiskMapTheme.info)
                    .frame(width: 28, height: 28)
                    .background(DiskMapTheme.navSelected, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(rec.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DiskMapTheme.ink)
                            .lineLimit(1)
                        if rec.isCurrent {
                            Text("Current")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(DiskMapTheme.info)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(DiskMapTheme.info.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(rec.header.capturedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                    Text("\(ByteFormat.string(rec.usedBytes)) used")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(DiskMapTheme.ink)
                    if rec.freeBytes > 0 {
                        Text("\(ByteFormat.string(rec.freeBytes)) free")
                            .font(.system(size: 10))
                            .foregroundStyle(DiskMapTheme.mutedLabel)
                    }
                }
                Spacer(minLength: 0)
                if !rec.isCurrent {
                    Menu {
                        Button("Compare with previous") { compareWithPrevious(rec) }
                        Button(rec.meta.favorite ? "Unfavorite" : "Favorite") { toggleFavorite(rec) }
                        Button("Delete…", role: .destructive) { confirmDelete = rec }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
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
                ProgressView("Comparing…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if report.folderChanges.isEmpty && report.categoryDeltas.isEmpty && beforeID != nil {
                noChangeCard
            } else if !report.folderChanges.isEmpty || !report.categoryDeltas.isEmpty {
                deltaSummary
                categorySection
                changesTable
            } else {
                Text("Choose Before and After snapshots, then Compare.")
                    .font(.system(size: 12))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .padding(.vertical, 24)
            }
            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compareSelectors: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Compare storage")
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Before")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                    Picker("", selection: $beforeID) {
                        Text("Select…").tag(String?.none)
                        ForEach(records) { rec in
                            Text(rec.pickerLabel).tag(Optional(rec.id))
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                }
                Image(systemName: "arrow.right")
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                VStack(alignment: .leading, spacing: 4) {
                    Text("After")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                    Picker("", selection: $afterID) {
                        Text("Select…").tag(String?.none)
                        ForEach(records) { rec in
                            Text(rec.pickerLabel).tag(Optional(rec.id))
                        }
                        if let current = currentRecord {
                            Text(current.pickerLabel).tag(Optional(current.id))
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                }
                Button("Compare") { Task { await runCompare() } }
                    .buttonStyle(PrimaryCTAStyle())
                    .disabled(!canCompare)
            }
        }
        .padding(14)
        .background(cardBG)
    }

    private var canCompare: Bool {
        guard let beforeID, let afterID, beforeID != afterID else { return false }
        // before must be saved; after can be current
        return records.contains { $0.id == beforeID }
            && (records.contains { $0.id == afterID } || currentRecord?.id == afterID)
    }

    private var deltaSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Storage changed")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Text(signed(report.usedDelta) + " used")
                .font(.system(size: 28, weight: .semibold).monospacedDigit())
                .foregroundStyle(report.usedDelta > 0 ? DiskMapTheme.review : DiskMapTheme.safe)
            Text("\(ByteFormat.string(report.beforeUsed)) → \(ByteFormat.string(report.afterUsed))")
                .font(.system(size: 13))
                .foregroundStyle(DiskMapTheme.ink)
            if report.beforeFree > 0 || report.afterFree > 0 {
                Text("Free space \(ByteFormat.string(report.beforeFree)) → \(ByteFormat.string(report.afterFree)) (\(signed(report.freeDelta)))")
                    .font(.system(size: 12))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            }
            Text(SnapshotCompare.narrative(for: report))
                .font(.system(size: 12))
                .foregroundStyle(DiskMapTheme.ink.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            if report.incomplete, let reason = report.incompleteReason {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(DiskMapTheme.review)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBG)
    }

    private var noChangeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No meaningful storage changes")
                .font(.system(size: 14, weight: .semibold))
            Text("Your storage is effectively unchanged between these snapshots.")
                .font(.system(size: 12))
                .foregroundStyle(DiskMapTheme.mutedLabel)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBG)
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where did the change happen?")
                .font(.system(size: 13, weight: .semibold))
            let maxAbs = max(1, report.categoryDeltas.map { abs($0.delta) }.max() ?? 1)
            ForEach(report.categoryDeltas.prefix(8)) { cat in
                Button {
                    changeQuery = cat.title
                    changeFilter = .all
                } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(DiskMapTheme.color(forHint: cat.colorHint))
                            .frame(width: 8, height: 8)
                        Text(cat.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DiskMapTheme.ink)
                            .frame(width: 110, alignment: .leading)
                        Text(signed(cat.delta))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(cat.delta >= 0 ? DiskMapTheme.review : DiskMapTheme.safe)
                            .frame(width: 80, alignment: .trailing)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(DiskMapTheme.color(forHint: cat.colorHint).opacity(0.85))
                                .frame(width: max(4, geo.size.width * CGFloat(abs(cat.delta)) / CGFloat(maxAbs)))
                        }
                        .frame(height: 8)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(cardBG)
    }

    private var changesTable: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Largest changes")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Picker("", selection: $minDelta) {
                    Text("> 10 MB").tag(Int64(10_000_000))
                    Text("> 100 MB").tag(Int64(100_000_000))
                    Text("> 500 MB").tag(Int64(500_000_000))
                    Text("> 1 GB").tag(Int64(1_000_000_000))
                    Text("Any").tag(Int64(0))
                }
                .labelsHidden()
                .frame(width: 110)
            }
            HStack(spacing: 8) {
                ForEach(ChangeFilter.allCases) { f in
                    Button {
                        changeFilter = f
                    } label: {
                        Text(f.title)
                            .font(.system(size: 11, weight: changeFilter == f ? .semibold : .regular))
                            .foregroundStyle(changeFilter == f ? DiskMapTheme.ink : DiskMapTheme.mutedLabel)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(changeFilter == f ? DiskMapTheme.navSelected : Color.clear))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                TextField("Search changes…", text: $changeQuery)
                    .textFieldStyle(.plain)
                    .padding(6)
                    .frame(width: 160)
                    .background(
                        RoundedRectangle(cornerRadius: 8).stroke(DiskMapTheme.cardStroke)
                    )
            }

            HStack {
                Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
                Text("CHANGE").frame(width: 90, alignment: .trailing)
                Text("AFTER").frame(width: 80, alignment: .trailing)
                Text("TYPE").frame(width: 70, alignment: .leading)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(DiskMapTheme.mutedLabel)

            if visibleChanges.isEmpty {
                Text("No changes match this filter.")
                    .font(.system(size: 12))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .padding(.vertical, 12)
            } else {
                ForEach(visibleChanges.prefix(80), id: \.path) { change in
                    Button {
                        selectedChangePath = change.path
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: change.path).lastPathComponent)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(DiskMapTheme.ink)
                                    .lineLimit(1)
                                Text(change.displayPath)
                                    .font(.system(size: 10))
                                    .foregroundStyle(DiskMapTheme.mutedLabel)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(signed(change.delta))
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(change.delta >= 0 ? DiskMapTheme.review : DiskMapTheme.safe)
                                .frame(width: 90, alignment: .trailing)
                            Text(ByteFormat.string(change.after))
                                .font(.system(size: 11).monospacedDigit())
                                .frame(width: 80, alignment: .trailing)
                            Text(change.kind.title)
                                .font(.system(size: 11))
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                                .frame(width: 70, alignment: .leading)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedChangePath == change.path ? DiskMapTheme.navSelected : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(DiskMapTheme.cardStroke.opacity(0.5))
                }
                if report.folderChanges.count > 80 {
                    Text("Showing top matches — \(Self.formatCount(report.folderChanges.count)) folder changes total.")
                        .font(.system(size: 11))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                }
            }
        }
        .padding(14)
        .background(cardBG)
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let change = selectedChange {
                    changeInspector(change)
                } else if let rec = selectedRecord {
                    snapshotInspector(rec)
                } else {
                    Text("Select a snapshot or change")
                        .font(.system(size: 13, weight: .semibold))
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
                .font(.system(size: 16, weight: .semibold))
            if rec.isCurrent {
                Text("Current")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.info)
            }
            Text(ByteFormat.string(rec.usedBytes) + " used")
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
            if !rec.meta.note.isEmpty {
                Text(rec.meta.note)
                    .font(.system(size: 12))
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
                Button("Delete snapshot…", role: .destructive) { confirmDelete = rec }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
            } else {
                Button("Save Snapshot") { prepareSave() }
                    .buttonStyle(PrimaryCTAStyle(fullWidth: true))
            }
        }
    }

    private func changeInspector(_ change: SnapshotChange) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(URL(fileURLWithPath: change.path).lastPathComponent)
                .font(.system(size: 16, weight: .semibold))
            Text(signed(change.delta))
                .font(.system(size: 24, weight: .semibold).monospacedDigit())
                .foregroundStyle(change.delta >= 0 ? DiskMapTheme.review : DiskMapTheme.safe)
            Text(change.displayPath)
                .font(.system(size: 11))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            VStack(alignment: .leading, spacing: 6) {
                StatRow(label: "Before", value: ByteFormat.string(change.before))
                StatRow(label: "After", value: ByteFormat.string(change.after))
                StatRow(label: "Type", value: change.kind.title)
            }
            .padding(12)
            .background(cardBG)

            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: change.path)])
            }
            .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
            Button("Open File Browser") {
                model.destination = .fileBrowser
            }
            .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
            Button("Explore in Visualize") {
                model.destination = .visualize
            }
            .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
            if change.displayPath.lowercased().contains("library/developer")
                || change.displayPath.lowercased().contains("node_modules")
                || change.displayPath.lowercased().contains("deriveddata") {
                Button("View Developer Storage") {
                    model.destination = .developerStorage
                }
                .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
            }
        }
    }

    private var saveSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save Snapshot")
                .font(.system(size: 16, weight: .semibold))
            Text("Save the current scan so you can compare your storage later. This does not copy or back up your files.")
                .font(.system(size: 12))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Text("Name")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            TextField("Snapshot name", text: $saveName)
                .textFieldStyle(.roundedBorder)
            Text("Optional note")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            TextField("e.g. Before cleaning Docker caches", text: $saveNote, axis: .vertical)
                .lineLimit(3...5)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showSave = false }
                    .buttonStyle(InkButtonStyle(filled: false))
                Button("Save Snapshot") { saveSnapshot() }
                    .buttonStyle(PrimaryCTAStyle())
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

    private func delete(_ rec: SnapshotRecord) {
        guard !rec.isCurrent else { return }
        do {
            try SnapshotStore.delete(rec.url)
            if beforeID == rec.id { beforeID = nil }
            if afterID == rec.id { afterID = nil }
            if selectedID == rec.id { selectedID = nil }
            confirmDelete = nil
            reload()
            model.showToast("Snapshot deleted")
        } catch {
            statusMessage = "Could not delete snapshot"
        }
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
        Task { await runCompare() }
    }

    private func runCompare() async {
        guard canCompare, let beforeID, let afterID else { return }
        isComparing = true
        report = .empty
        defer { isComparing = false }

        let basis = model.sizeBasis
        do {
            let beforeRec = records.first { $0.id == beforeID }
            guard let beforeRec else { return }
            let before = try SnapshotStore.load(from: beforeRec.url)

            let afterSnap: DiskSnapshot
            let afterMeta: SnapshotMeta?
            if let afterRec = records.first(where: { $0.id == afterID }) {
                afterSnap = try SnapshotStore.load(from: afterRec.url)
                afterMeta = afterRec.meta
            } else if let tree = model.tree, let root = model.rootURL, currentRecord?.id == afterID {
                afterSnap = DiskSnapshot(rootPath: root.path, capturedAt: Date(), tree: tree)
                afterMeta = currentRecord?.meta
            } else {
                return
            }

            let built = SnapshotCompare.report(
                before: before,
                after: afterSnap,
                beforeMeta: beforeRec.meta,
                afterMeta: afterMeta,
                basis: basis,
                minAbsDelta: 0
            )
            await MainActor.run {
                report = built
                selectedChangePath = built.folderChanges.first?.path
                statusMessage = "\(built.folderChanges.count) folder changes"
            }
        } catch {
            await MainActor.run {
                report = .empty
                statusMessage = "Could not compare those snapshots"
            }
        }
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
