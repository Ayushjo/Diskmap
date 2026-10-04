import DiskMapCore
import SwiftUI

// TASK-081 — Find queries kept in the sidebar, with live totals. Separate
// from the numbered destinations, so ⌘1–⌘9 never move.

extension ScanModel {
    static let savedSearchesKey = "SavedSearches"

    private func persistSavedSearches() {
        // Only the app's own model writes the user's preferences.
        if recordsLastScan {
            UserDefaults.standard.set(SavedSearches.encode(savedSearches), forKey: Self.savedSearchesKey)
        }
        refreshSavedSearchTotals()
    }

    @discardableResult
    func saveSearch(name: String, query: String, sort: FileQuery.Sort) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let index = savedSearches.firstIndex(where: { $0.query == trimmed }) {
            savedSearches[index].name = name
            savedSearches[index].sort = sort.rawValue
        } else {
            guard savedSearches.count < SavedSearches.limit else { return false }
            savedSearches.append(SavedSearch(name: name, query: trimmed, sort: sort))
        }
        persistSavedSearches()
        return true
    }

    func renameSavedSearch(_ id: UUID, to name: String) {
        guard let index = savedSearches.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        savedSearches[index].name = name
        persistSavedSearches()
    }

    /// Removes the saved search only — never anything it matches.
    func removeSavedSearch(_ id: UUID) {
        savedSearches.removeAll { $0.id == id }
        savedSearchTotals[id] = nil
        persistSavedSearches()
    }

    func moveSavedSearch(_ id: UUID, by offset: Int) {
        guard let index = savedSearches.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard savedSearches.indices.contains(target) else { return }
        savedSearches.swapAt(index, target)
        persistSavedSearches()
    }

    func openSavedSearch(_ search: SavedSearch) {
        findQuery = search.query
        findSort = search.fileSort
        destination = .find
    }

    func isSavedSearchSelected(_ search: SavedSearch) -> Bool {
        destination == .find && findQuery.trimmingCharacters(in: .whitespacesAndNewlines) == search.query
    }

    /// One count-only pass per saved search, off the main thread.
    func refreshSavedSearchTotals() {
        savedSearchTotalsTask?.cancel()
        guard let tree, let root = rootURL, !savedSearches.isEmpty else {
            savedSearchTotals = [:]
            return
        }
        let list = savedSearches
        let totals = selectedTotals
        let duplicates: Set<Int32>? = duplicateDidRun ? Set(duplicateGroups.flatMap(\.fileIDs)) : nil
        let context = FileQuery.Context(home: NSHomeDirectory(), duplicateFileIDs: duplicates)
        savedSearchTotalsTask = Task { [weak self] in
            let work = Task.detached(priority: .utility) {
                SavedSearches.totals(list, tree: tree, root: root, totals: totals, context: context,
                                     isCancelled: { Task.isCancelled })
            }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let self else { return }
            self.savedSearchTotals = result
        }
    }
}

/// The sidebar's "Saved" section.
struct SavedSearchSection: View {
    @ObservedObject var model: ScanModel
    let enabled: Bool
    @State private var renaming: SavedSearch?
    @State private var newName = ""

    var body: some View {
        if !model.savedSearches.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("SAVED")
                    .font(DiskMapType.secondary.weight(.medium))
                    .tracking(0.8)
                    .foregroundStyle(DiskMapTheme.ink2)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 2)
                ForEach(model.savedSearches) { search in
                    row(search)
                }
            }
            .alert("Rename Saved Search", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Rename") {
                    if let renaming { model.renameSavedSearch(renaming.id, to: newName.trimmingCharacters(in: .whitespaces)) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }

    private func row(_ search: SavedSearch) -> some View {
        let selected = model.isSavedSearchSelected(search)
        let total = model.savedSearchTotals[search.id]
        return Button { model.openSavedSearch(search) } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass.circle")
                    .font(DiskMapType.secondary)
                    .frame(width: 18)
                Text(search.name)
                    .font(.system(size: DiskMapType.scaled(13), weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let total {
                    Text(total.count == 0 ? "—" : ByteFormat.string(total.bytes))
                        .font(DiskMapType.secondary.monospacedDigit())
                        .foregroundStyle(DiskMapTheme.ink2)
                }
            }
            .foregroundStyle(enabled ? DiskMapTheme.ink : DiskMapTheme.ink3.opacity(0.62))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? DiskMapTheme.hover : Color.clear))
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(search.query)
        .contextMenu {
            Button("Rename…") { newName = search.name; renaming = search }
            Button("Move Up") { model.moveSavedSearch(search.id, by: -1) }
                .disabled(model.savedSearches.first?.id == search.id)
            Button("Move Down") { model.moveSavedSearch(search.id, by: 1) }
                .disabled(model.savedSearches.last?.id == search.id)
            Divider()
            Button("Remove from Sidebar") { model.removeSavedSearch(search.id) }
        }
        .accessibilityLabel(total.map { "\(search.name), \($0.count) matches, \(ByteFormat.string($0.bytes))" } ?? search.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Find's "Save…" sheet.
struct SaveSearchSheet: View {
    @ObservedObject var model: ScanModel
    @Binding var isPresented: Bool
    @State private var name: String

    init(model: ScanModel, isPresented: Binding<Bool>, suggestedName: String) {
        self.model = model
        self._isPresented = isPresented
        self._name = State(initialValue: suggestedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save to the Sidebar")
                .font(DiskMapType.heading)
            Text(model.findQuery)
                .font(DiskMapType.secondary.monospaced())
                .foregroundStyle(DiskMapTheme.ink2)
                .textSelection(.enabled)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            if model.savedSearches.count >= SavedSearches.limit {
                Text("The sidebar holds \(SavedSearches.limit) saved searches; remove one first.")
                    .font(DiskMapType.secondary)
                    .foregroundStyle(DiskMapTheme.review)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.saveSearch(name: name.trimmingCharacters(in: .whitespaces), query: model.findQuery, sort: model.findSort)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || model.savedSearches.count >= SavedSearches.limit)
            }
        }
        .padding(20)
    }
}
