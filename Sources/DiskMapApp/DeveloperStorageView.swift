import AppKit
import DiskMapCore
import SwiftUI

/// Explore → Developer Storage: dependencies, caches and build output, by
/// project, item, opportunity and tool (the former Regenerable Data page).
struct DeveloperStorageView: View {
    @ObservedObject var model: ScanModel
    @Environment(\.diskMapContentWidth) private var contentWidth
    var pickFolder: () -> Void

    @State private var selectedID: String?
    @State private var tableTab: TableTab = .projects
    @State private var query = ""
    @State private var categoryFilter: DeveloperCategory?
    @State private var checked: Set<String> = []
    /// The By tool tab (TASK-002 quick wins), built when first opened.
    @State private var toolHits: [QuickWins.Hit]?
    @State private var checkedTools: Set<Int32> = []
    @State private var selectedTool: Int32?

    private let toolCategories = QuickWins.bundledCategories()

    enum TableTab: String, CaseIterable, Identifiable {
        case projects, allItems, opportunities, byTool
        var id: String { rawValue }
        var title: String {
            switch self {
            case .projects: return "Projects"
            case .allItems: return "Items"
            case .opportunities: return "Opportunities"
            case .byTool: return "By tool"
            }
        }
    }

    private var catalog: DeveloperCatalogResult { model.cachedDeveloper }
    private var summary: DeveloperSummary { catalog.summary }
    private var totals: [Int64] { model.selectedTotals }

    private var activeItem: DeveloperItem? {
        if let selectedID {
            if let item = catalog.items.first(where: { $0.id == selectedID }) { return item }
            if let proj = catalog.projects.first(where: { $0.id == selectedID }),
               let first = catalog.items.first(where: { proj.nodeIDs.contains($0.nodeID) }) {
                return first
            }
        }
        return catalog.opportunities.first ?? catalog.items.first
    }

    var body: some View {
        Group {
            if model.tree == nil {
                DiskMapEmptyState(symbol: "chevron.left.forwardslash.chevron.right", title: "Scan to see developer storage",
                                  message: "Dependencies, caches and build output, after a scan.",
                                  primaryTitle: "Choose Folder…", primaryAction: pickFolder)
            } else {
                AdaptiveInspectorSplit(windowWidth: contentWidth, inspectionToken: tableTab == .byTool ? selectedTool.map(String.init) : selectedID,
                                       main: mainColumn, inspector: inspector)
            }
        }
        .background(DiskMapTheme.canvas)
        .catalogGate(.developer, model: model, title: "Sorting developer storage…")
        .task(id: tableTab == .byTool ? model.scanID : nil) {
            guard tableTab == .byTool, let tree = model.tree, let root = model.rootURL else { return }
            toolHits = nil
            checkedTools = []
            let categories = toolCategories
            let found = await Task.detached(priority: .userInitiated) {
                QuickWins.findCategorized(in: tree, root: root, categories: categories)
            }.value
            guard !Task.isCancelled else { return }
            toolHits = found
        }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(eyebrow: "Explore", title: "Developer Storage",
                           subtitle: "Dependencies, caches and build output — what each costs to rebuild, and whether the project is backed up.") {
                    HeaderSummary(parts: [countLabel(summary.toolCount, "tool"), countLabel(summary.projectCount, "project")])
                }
                notice
                FigureStrip(figures: [
                    Figure(label: "Developer storage", value: ByteFormat.string(summary.totalBytes)),
                    Figure(label: "Reclaimable", value: ByteFormat.string(summary.reclaimableBytes), detail: percent(summary.reclaimableBytes)),
                    Figure(label: "Likely keep", value: ByteFormat.string(summary.keepBytes), detail: percent(summary.keepBytes)),
                ])
                categoryBar
                KitTabs(tabs: TableTab.allCases.map { tab in
                    .init(id: tab, title: tab.title, count: tabCount(tab).map { "\($0)" })
                }, selection: $tableTab)
                HStack(spacing: 10) {
                    DiskMapSearchField(placeholder: "Filter by name, path or ecosystem", text: $query)
                        .frame(maxWidth: 320)
                    if let categoryFilter, tableTab == .allItems {
                        Chip(title: categoryFilter.title, symbol: "xmark", isOn: true) { self.categoryFilter = nil }
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, DiskMapSpace.pageTop)
            .padding(.bottom, 12)
            Hairline()
            switch tableTab {
            case .projects: projectsList
            case .allItems: itemsList(filteredItems)
            case .opportunities: itemsList(catalog.opportunities)
            case .byTool: toolsList
            }
            footer
        }
    }

    private func tabCount(_ tab: TableTab) -> Int? {
        switch tab {
        case .projects: return catalog.projects.count
        case .allItems: return filteredItems.count
        case .opportunities: return catalog.opportunities.count
        case .byTool: return toolHits?.count
        }
    }

    /// One notice: stale projects, unpinned dependencies, or both.
    @ViewBuilder
    private var notice: some View {
        if summary.staleProjectCount > 0 {
            DiskMapNoticeBanner(
                symbol: "clock.arrow.circlepath",
                tint: DiskMapTheme.ink2,
                title: "\(countLabel(summary.staleProjectCount, "project")) untouched for 6+ months "
                    + "\(summary.staleProjectCount == 1 ? "holds" : "hold") \(ByteFormat.string(summary.staleReclaimableBytes)) of dependencies and build output",
                detail: "Measured from each project’s newest source file. Check Git before removing a whole project."
                    + (summary.unpinnedBytes > 0 ? " \(ByteFormat.string(summary.unpinnedBytes)) of dependencies have no lockfile." : "")
            )
        } else if summary.unpinnedBytes > 0 {
            DiskMapNoticeBanner(
                symbol: "exclamationmark.triangle",
                tint: DiskMapTheme.review,
                title: "\(ByteFormat.string(summary.unpinnedBytes)) of dependencies have no lockfile",
                detail: RebuildCost.networkedUnpinned.explanation
            )
        }
    }

    /// One stacked bar; its legend entries filter the Items tab.
    private var categoryBar: some View {
        let total = max(1, summary.totalBytes)
        return VStack(alignment: .leading, spacing: 10) {
            SegmentedStorageBar(segments: summary.categories.map {
                (color(for: $0.category).opacity(categoryFilter == nil || categoryFilter == $0.category ? 1 : 0.3),
                 Double($0.bytes) / Double(total))
            })
            .accessibilityHidden(true)
            FlowLayout(spacing: 14) {
                ForEach(summary.categories) { roll in
                    let on = categoryFilter == roll.category
                    Button {
                        categoryFilter = on ? nil : roll.category
                        tableTab = .allItems
                    } label: {
                        HStack(spacing: 5) {
                            Circle().fill(color(for: roll.category)).frame(width: 7, height: 7)
                            Text(roll.category.title)
                                .font(on ? DiskMapType.bodyEmphasis : DiskMapType.secondary)
                                .foregroundStyle(on ? DiskMapTheme.ink : DiskMapTheme.ink2)
                            Text(ByteFormat.string(roll.bytes))
                                .font(DiskMapType.figureSmall)
                                .foregroundStyle(DiskMapTheme.ink3)
                        }
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(roll.category.title), \(ByteFormat.string(roll.bytes))")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    private var filteredItems: [DeveloperItem] {
        var list = catalog.items
        if let categoryFilter { list = list.filter { $0.category == categoryFilter } }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.displayName.lowercased().contains(q) || $0.displayPath.lowercased().contains(q)
                    || $0.ecosystem.title.lowercased().contains(q)
            }
        }
        return list
    }

    private var filteredProjects: [DeveloperProject] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return catalog.projects }
        return catalog.projects.filter {
            $0.name.lowercased().contains(q) || $0.displayPath.lowercased().contains(q)
                || $0.ecosystem.title.lowercased().contains(q)
        }
    }

    // MARK: Lists

    private var projectsList: some View {
        let projects = Array(filteredProjects.prefix(60))
        return Group {
            if projects.isEmpty {
                DiskMapEmptyState(symbol: "folder", title: "No projects found",
                                  message: "No project-scoped folders such as node_modules, Pods or .venv in this scan.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(projects) { proj in
                            let itemID = catalog.items.first(where: { proj.nodeIDs.contains($0.nodeID) })?.id ?? proj.id
                            Button { selectedID = itemID } label: {
                                KitRow(title: proj.name, subtitle: "\(proj.ecosystem.title) · " + (model.rootURL.map { relativeParent(of: proj.absolutePath, root: $0) } ?? proj.displayPath),
                                       selected: isProjectSelected(proj), path: proj.absolutePath, onStage: nil) {
                                    Image(systemName: proj.ecosystem.symbolName)
                                        .font(.system(size: DiskMapType.scaled(13)))
                                        .foregroundStyle(DiskMapTheme.ink2)
                                        .frame(width: 24, height: 24)
                                } trailing: {
                                    // Columns give way when the list is narrow (large text, small
                                    // window); the inspector always shows every fact.
                                    let git = SafetyLabel(level: nil, title: DeveloperLabels.gitShort(proj.git), tint: DeveloperLabels.gitTint(proj.git))
                                        .frame(width: DiskMapType.scaled(92), alignment: .leading)
                                        .help(proj.git.detail)
                                    let size = MonoColumn(text: ByteFormat.string(proj.bytes), width: 74, emphasis: true)
                                    ViewThatFits(in: .horizontal) {
                                        HStack(spacing: 12) {
                                            git
                                            TextColumn(text: DeveloperLabels.rebuildShort(proj.rebuildCost), width: 92)
                                            MonoColumn(text: RelativeAge.short(day: proj.lastSourceDay), width: 56)
                                            MonoColumn(text: ByteFormat.string(proj.reclaimableBytes), width: 74)
                                                .help("Reclaimable")
                                            size
                                        }
                                        HStack(spacing: 12) {
                                            git
                                            TextColumn(text: DeveloperLabels.rebuildShort(proj.rebuildCost), width: 92)
                                            size
                                        }
                                        HStack(spacing: 12) { git; size }
                                        size
                                    }
                                    .layoutPriority(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(proj.name), \(ByteFormat.string(proj.bytes)), \(ByteFormat.string(proj.reclaimableBytes)) reclaimable, \(DeveloperLabels.gitShort(proj.git))")
                            RowSeparator(indent: 10 + 24 + 12)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 4)
                }
                .listKeyboard(
                    ids: projects.compactMap { p in catalog.items.first(where: { p.nodeIDs.contains($0.nodeID) })?.id },
                    selection: $selectedID,
                    path: { id in catalog.items.first { $0.id == id }?.absolutePath },
                    stage: { id in if let item = catalog.items.first(where: { $0.id == id }) { stage([item]) } }
                )
            }
        }
    }

    private func itemsList(_ items: [DeveloperItem]) -> some View {
        let shown = Array(items.prefix(120))
        return Group {
            if shown.isEmpty {
                DiskMapEmptyState(symbol: "shippingbox", title: "Nothing here", message: "No matching developer items.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { item in
                            itemRow(item)
                            RowSeparator(indent: 10 + 18 + 10 + 24 + 12)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 4)
                }
                .listKeyboard(
                    ids: shown.map(\.id), selection: $selectedID,
                    path: { id in catalog.items.first { $0.id == id }?.absolutePath },
                    stage: { id in if let item = catalog.items.first(where: { $0.id == id }) { stage([item]) } },
                    selectAll: { checked = Set(shown.filter(canStage).map(\.id)) },
                    clearSelection: { checked.removeAll() }
                )
            }
        }
    }

    private func canStage(_ item: DeveloperItem) -> Bool {
        !item.isProtected && item.recipe?.trashIsUnsafe != true
    }

    private func itemRow(_ item: DeveloperItem) -> some View {
        let isOn = checked.contains(item.id)
        return CheckRow {
            KitCheckbox(isOn: Binding(get: { isOn }, set: { on in
                if on { checked.insert(item.id) } else { checked.remove(item.id) }
            }), label: isOn ? "Unmark \(item.displayName)" : "Mark \(item.displayName)")
                .disabled(!canStage(item))
            Button { selectedID = item.id } label: {
                KitRow(title: item.displayName, subtitle: "\(item.category.shortTitle) · " + (model.rootURL.map { relativeParent(of: item.absolutePath, root: $0) } ?? item.displayPath),
                       selected: item.id == activeItem?.id, path: item.absolutePath,
                       onStage: canStage(item) ? { stage([item]) } : nil) {
                    Image(systemName: item.ecosystem.symbolName)
                        .font(.system(size: DiskMapType.scaled(13)))
                        .foregroundStyle(DiskMapTheme.ink2)
                        .frame(width: 24, height: 24)
                } trailing: {
                    TextColumn(text: item.ecosystem.title, width: 84)
                    SafetyLabel(level: item.safety.level)
                        .frame(width: DiskMapType.scaled(104), alignment: .leading)
                    MonoColumn(text: ByteFormat.string(item.bytes), width: 74, emphasis: true)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.displayName), \(ByteFormat.string(item.bytes)), \(item.safety.level.title)")
            .rowActions(path: item.absolutePath, stage: canStage(item) ? { stage([item]) } : nil)
        }
    }

    // MARK: By tool (former Regenerable Data)

    private var toolsList: some View {
        Group {
            if let hits = toolHits {
                if hits.isEmpty {
                    DiskMapEmptyState(symbol: "leaf", title: "Nothing regenerable found", message: "No dependency folders, build output or tool caches in this scan.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(toolCategories) { category in
                                let group = toolGroup(category, hits: hits)
                                if !group.isEmpty { toolSection(category, group: group) }
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 8)
                    }
                }
            } else {
                DiskMapLoadingState(title: "Grouping by tool", detail: "Matching folders against the known patterns.")
            }
        }
    }

    private func toolGroup(_ category: QuickWins.Category, hits: [QuickWins.Hit]) -> [QuickWins.Hit] {
        hits.filter { $0.categoryID == category.id }.sorted { toolSize($0.id) > toolSize($1.id) }
    }

    private func toolSize(_ id: Int32) -> Int64 { Int(id) < totals.count ? totals[Int(id)] : 0 }

    private func toolSection(_ category: QuickWins.Category, group: [QuickWins.Hit]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(label: category.title,
                          detail: "\(countLabel(group.count, "item")) · \(ByteFormat.string(group.reduce(0) { $0 + toolSize($1.id) }))") {
                Button("Add all to Cleanup") { stageTools(group.map(\.id), category: category.id) }
                    .buttonStyle(LinkButtonStyle())
                    .font(DiskMapType.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 18)
            if !category.note.isEmpty {
                Text(category.note)
                    .font(DiskMapType.secondary)
                    .foregroundStyle(DiskMapTheme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            ForEach(group) { hit in
                toolRow(hit, category: category.id)
            }
        }
    }

    private func toolRow(_ hit: QuickWins.Hit, category: String) -> some View {
        let abs = model.tree.flatMap { tree in model.rootURL.map { tree.path(of: hit.id, root: $0).path } } ?? hit.name
        let isOn = checkedTools.contains(hit.id)
        return CheckRow {
            KitCheckbox(isOn: Binding(get: { isOn }, set: { on in
                if on { checkedTools.insert(hit.id) } else { checkedTools.remove(hit.id) }
            }), label: isOn ? "Unmark \(hit.name)" : "Mark \(hit.name)")
            Button { selectedTool = hit.id } label: {
                KitRow(title: hit.name, subtitle: model.rootURL.map { relativeParent(of: abs, root: $0) },
                       selected: selectedTool == hit.id, path: abs,
                       onStage: { stageTools([hit.id], category: category) }, height: DiskMapSpace.rowTwoLine) {
                    Image(systemName: "folder")
                        .font(.system(size: DiskMapType.scaled(13)))
                        .foregroundStyle(DiskMapTheme.ink2)
                        .frame(width: 24, height: 24)
                } trailing: {
                    MonoColumn(text: ByteFormat.string(toolSize(hit.id)), width: 74, emphasis: true)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(hit.name), \(ByteFormat.string(toolSize(hit.id)))")
            .rowActions(path: abs, stage: { stageTools([hit.id], category: category) })
        }
    }

    // MARK: Footer, inspector, staging

    @ViewBuilder
    private var footer: some View {
        if tableTab == .byTool {
            if toolHits?.isEmpty == false {
                ReviewFooter(
                    checkedCount: checkedTools.count,
                    checkedBytes: checkedTools.reduce(0) { $0 + toolSize($1) },
                    hint: "Tick folders to clean, or use Add all on a group.",
                    quickSelectTitle: "",
                    quickSelectEnabled: false,
                    onQuickSelect: {},
                    onStage: { stageTools(Array(checkedTools), category: nil) },
                    onClear: { checkedTools.removeAll() },
                    onReveal: { revealNodes(Array(checkedTools)) },
                    paths: checkedTools.compactMap(path(of:))
                )
            }
        } else if tableTab != .projects {
            let items = catalog.items.filter { checked.contains($0.id) }
            ReviewFooter(
                checkedCount: items.count,
                checkedBytes: items.reduce(0) { $0 + $1.bytes },
                hint: "Tick items to clean, or",
                quickSelectTitle: "Select reclaimable",
                onQuickSelect: {
                    let source = tableTab == .opportunities ? catalog.opportunities : filteredItems
                    checked = Set(source.filter { canStage($0) && $0.reclaimability == .reclaimable }.map(\.id))
                },
                onStage: { stage(items) },
                onClear: { checked.removeAll() },
                onReveal: { NSWorkspace.shared.activateFileViewerSelecting(items.map { URL(fileURLWithPath: $0.absolutePath) }) },
                paths: items.map(\.absolutePath)
            )
        }
    }

    private var inspector: some View {
        Group {
            if tableTab == .byTool {
                if let id = selectedTool, let tree = model.tree, let root = model.rootURL {
                    FolderInspector(model: model, tree: tree, rootURL: root, id: id, reason: "Developer: " + tree.name(of: id))
                } else {
                    DiskMapEmptyState(symbol: "folder", title: "Select a folder", message: "Its details and actions appear here.")
                }
            } else if let item = activeItem {
                DeveloperInspector(model: model, item: item, project: catalog.projects.first { $0.id == item.projectKey }) {
                    stage([item])
                }
            } else {
                DiskMapEmptyState(symbol: "shippingbox", title: "Select an item",
                                  message: "See why it’s large and what removing it costs.")
            }
        }
        .background(DiskMapTheme.canvas)
    }

    private func isProjectSelected(_ proj: DeveloperProject) -> Bool {
        guard let item = activeItem else { return false }
        return proj.nodeIDs.contains(item.nodeID)
    }

    private func percent(_ part: Int64) -> String {
        guard summary.totalBytes > 0 else { return "—" }
        return String(format: "%.0f%%", Double(part) / Double(summary.totalBytes) * 100)
    }

    /// The data palette, in a fixed order per category.
    private func color(for category: DeveloperCategory) -> Color {
        switch category {
        case .dependencies: return DiskMapTheme.data(0)
        case .caches: return DiskMapTheme.data(3)
        case .buildArtifacts: return DiskMapTheme.data(4)
        case .containers: return DiskMapTheme.data(1)
        case .sdksSimulators: return DiskMapTheme.data(2)
        case .other: return DiskMapTheme.data(6)
        }
    }

    private func path(of id: Int32) -> String? {
        guard let tree = model.tree, let root = model.rootURL else { return nil }
        return tree.path(of: id, root: root).path
    }

    private func revealNodes(_ ids: [Int32]) {
        NSWorkspace.shared.activateFileViewerSelecting(ids.compactMap(path(of:)).map { URL(fileURLWithPath: $0) })
    }

    /// Items whose recipe says Trash would damage the tool are never staged.
    private func stage(_ items: [DeveloperItem]) {
        let allowed = items.filter(canStage)
        if allowed.isEmpty, let recipe = items.first?.recipe, recipe.trashIsUnsafe {
            model.showToast("Use the tool instead: \(recipe.command)")
            return
        }
        Task {
            let summary = await model.stageForCleanup(allowed.map {
                CleanupStageRequest(url: URL(fileURLWithPath: $0.absolutePath), size: $0.bytes, reason: "Developer: \($0.displayName)")
            })
            model.showToast(summary.added > 0 ? "Added \(countLabel(summary.added, "item")) to Cleanup — ⇧⌘⌫ to review"
                            : summary.alreadyPresent > 0 ? "Already in Cleanup" : "Blocked by safety rules")
            checked.subtract(allowed.map(\.id))
        }
    }

    private func stageTools(_ ids: [Int32], category: String?) {
        guard let tree = model.tree, let root = model.rootURL else { return }
        Task {
            let summary = await model.stageForCleanup(ids.map { id in
                let cat = category ?? toolHits?.first { $0.id == id }?.categoryID ?? "dev"
                return CleanupStageRequest(url: tree.path(of: id, root: root), size: toolSize(id), reason: "dev: \(cat)")
            })
            model.showToast(summary.added > 0 ? "Added \(countLabel(summary.added, "folder")) to Cleanup — ⇧⌘⌫ to review"
                            : summary.alreadyPresent > 0 ? "Already in Cleanup" : "Nothing could be added")
            checkedTools.subtract(ids)
        }
    }
}

/// Inspector for one developer item: facts, the tool's own command when
/// Trash is unsafe, why, what removing costs, safety, actions.
private struct DeveloperInspector: View {
    @ObservedObject var model: ScanModel
    let item: DeveloperItem
    let project: DeveloperProject?
    var onStage: () -> Void

    var body: some View {
        let staged = model.isStaged(URL(fileURLWithPath: item.absolutePath))
        let trashUnsafe = item.recipe?.trashIsUnsafe == true
        InspectorColumn {
            InspectorHeader(name: item.displayName, size: ByteFormat.string(item.bytes),
                            detail: "\(item.category.title) · \(item.ecosystem.title)") {
                Image(systemName: item.ecosystem.symbolName)
                    .font(.system(size: DiskMapType.scaled(17)))
                    .foregroundStyle(DiskMapTheme.ink2)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DiskMapTheme.ink.opacity(0.06)))
            }
            Hairline()
            FactRow(label: "Location", value: item.displayPath)
            if let name = item.projectName { FactRow(label: "Project", value: name) }
            FactRow(label: "Rebuild", value: item.rebuildCost.title + (item.lockfile.map { " · \($0)" } ?? ""))
            if let project {
                VStack(alignment: .leading, spacing: 4) {
                    MonoLabel("Git")
                    SafetyLabel(level: nil, title: project.git.title, tint: DeveloperLabels.gitTint(project.git))
                    Text(project.git.detail)
                        .font(DiskMapType.secondary)
                        .foregroundStyle(DiskMapTheme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                FactRow(label: "Last source change", value: DeveloperLabels.lastChange(project.lastSourceDay))
                if let ignored = project.ignoredBytes, ignored > 0 {
                    FactRow(label: "Ignored by git", value: ByteFormat.string(ignored))
                }
            }
            if let recipe = item.recipe {
                VStack(alignment: .leading, spacing: 6) {
                    MonoLabel(recipe.trashIsUnsafe ? "Don’t move this to the Trash" : recipe.title,
                              tint: recipe.trashIsUnsafe ? DiskMapTheme.danger : DiskMapTheme.ink3)
                    Text(recipe.why)
                        .font(DiskMapType.secondary)
                        .foregroundStyle(DiskMapTheme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(recipe.command)
                            .font(DiskMapType.figure)
                            .foregroundStyle(DiskMapTheme.ink)
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(recipe.command, forType: .string)
                            model.showToast("Command copied — freedisk.space never runs it for you")
                        } label: { Label("Copy command", systemImage: "doc.on.doc") }
                            .buttonStyle(IconButtonStyle(size: 24))
                            .accessibilityLabel("Copy command \(recipe.command)")
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: DiskMapRadius.control, style: .continuous).fill(DiskMapTheme.ink.opacity(0.05)))
                }
            }
            Hairline()
            Note(label: "Why it's large", text: item.whyLarge)
            Note(label: "If you remove it", text: item.rebuildCost.explanation)
            SafetyLine(assessment: item.safety)
            InspectorActions(
                primaryTitle: trashUnsafe ? "Use the command above" : staged ? "In Cleanup" : "Add to Cleanup",
                primaryDone: staged,
                primaryEnabled: !trashUnsafe && !item.isProtected,
                primary: { if staged { model.isCleanupQueuePresented = true } else { onStage() } },
                path: item.absolutePath
            ) {
                Button("Open in File Browser") {
                    model.currentNode = item.nodeID
                    model.selectedNode = item.nodeID
                    model.destination = .fileBrowser
                }
                Button("Show in Visualize") {
                    model.currentNode = item.nodeID
                    model.selectedNode = item.nodeID
                    model.destination = .visualize
                }
            }
            .padding(.top, 4)
        }
    }
}

/// Short labels and tints shared by the Developer Storage table and inspector.
enum DeveloperLabels {
    static func rebuildShort(_ cost: RebuildCost) -> String {
        switch cost {
        case .free: return "Free"
        case .cheap: return "Offline build"
        case .networked: return "Re-download"
        case .networkedUnpinned: return "No lockfile"
        }
    }

    static func rebuildTint(_ cost: RebuildCost) -> Color {
        switch cost {
        case .free, .cheap: return DiskMapTheme.safe
        case .networked: return DiskMapTheme.ink2
        case .networkedUnpinned: return DiskMapTheme.review
        }
    }

    static func lastChange(_ day: Int32) -> String {
        guard day > 0 else { return "Unknown" }
        let age = max(0, AgeMap.today() - day)
        if age == 0 { return "Today" }
        if age == 1 { return "Yesterday" }
        return ForgottenAgeFormat.string(age)
    }

    static func gitShort(_ state: GitState) -> String {
        switch state {
        case .inSync: return "Pushed"
        case .noRemote: return "No remote"
        case .differs: return "Unpushed"
        case .notARepository: return "No git"
        case .unknown: return "Unknown"
        }
    }

    static func gitTint(_ state: GitState) -> Color {
        switch state {
        case .inSync: return DiskMapTheme.safe
        case .noRemote, .differs: return DiskMapTheme.review
        case .notARepository, .unknown: return DiskMapTheme.ink2
        }
    }
}
