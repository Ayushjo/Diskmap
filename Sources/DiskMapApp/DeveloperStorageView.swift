import AppKit
import DiskMapCore
import SwiftUI

/// Explore → Developer Storage: taxonomy, ecosystems, projects, reclaimability.
struct DeveloperStorageView: View {
    @ObservedObject var model: ScanModel
    @Environment(\.diskMapContentWidth) private var contentWidth
    var pickFolder: () -> Void
    var onOpenCleanup: () -> Void

    @State private var selectedID: String?
    @State private var tableTab: TableTab = .projects
    @State private var query = ""
    @State private var categoryFilter: DeveloperCategory?

    private enum TableTab: String, CaseIterable, Identifiable {
        case projects, allItems, opportunities
        var id: String { rawValue }
        var title: String {
            switch self {
            case .projects: return "Projects"
            case .allItems: return "All Items"
            case .opportunities: return "Opportunities"
            }
        }
    }

    private var catalog: DeveloperCatalogResult {
        model.cachedDeveloper
    }

    private var summary: DeveloperSummary { catalog.summary }

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
                emptyScan
            } else {
                AdaptiveInspectorSplit(windowWidth: contentWidth, inspectionToken: selectedID, main: mainColumn, inspector: inspector)
            }
        }
        .background(DiskMapTheme.cream)
        .task {
            if model.cachedDeveloper.items.isEmpty, model.tree != nil {
                model.refreshDeveloperCache()
            }
        }
    }

    private var emptyScan: some View {
        VStack(spacing: 12) {
            Text("Scan to analyze developer storage.")
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Button("Choose Folder…", action: pickFolder).buttonStyle(InkButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mainColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                summaryRow
                categoryBar
                ecosystemsRow
                opportunitiesRow
                tableSection
            }
            .padding(20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Developer Storage")
                .font(DiskMapType.title)
                .foregroundStyle(DiskMapTheme.ink)
            Text("Tooling, dependencies, and build products — with reclaimability and safety. Nothing is deleted here; stage into Cleanup to confirm.")
                .font(DiskMapType.body)
                .foregroundStyle(DiskMapTheme.mutedLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summaryRow: some View {
        HStack(alignment: .top, spacing: 12) {
            summaryCard(
                title: "Developer Storage",
                value: ByteFormat.string(summary.totalBytes),
                subtitle: "\(summary.toolCount) tools · \(summary.projectCount) projects",
                tint: DiskMapTheme.developer
            )
            summaryCard(
                title: "Potentially reclaimable",
                value: ByteFormat.string(summary.reclaimableBytes),
                subtitle: percent(summary.reclaimableBytes, of: summary.totalBytes),
                tint: DiskMapTheme.safe
            )
            summaryCard(
                title: "Likely active / keep",
                value: ByteFormat.string(summary.keepBytes),
                subtitle: percent(summary.keepBytes, of: summary.totalBytes),
                tint: DiskMapTheme.review
            )
        }
    }

    private func summaryCard(title: String, value: String, subtitle: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            Text(value)
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(DiskMapTheme.mutedLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DiskMapTheme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                )
        )
    }

    private var categoryBar: some View {
        let total = max(1, summary.totalBytes)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Storage breakdown")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DiskMapTheme.ink)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(summary.categories) { roll in
                        let w = geo.size.width * CGFloat(Double(roll.bytes) / Double(total))
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(color(for: roll.category))
                            .frame(width: max(roll.bytes > 0 ? 4 : 0, w))
                            .help("\(roll.category.title): \(ByteFormat.string(roll.bytes))")
                    }
                }
            }
            .frame(height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], alignment: .leading, spacing: 6) {
                ForEach(summary.categories) { roll in
                    Button {
                        categoryFilter = categoryFilter == roll.category ? nil : roll.category
                        tableTab = .allItems
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(color(for: roll.category)).frame(width: 7, height: 7)
                            Text(roll.category.title)
                                .foregroundStyle(DiskMapTheme.ink)
                            Text(ByteFormat.string(roll.bytes))
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                                .monospacedDigit()
                            if let pct = Optional(Double(roll.bytes) / Double(total)) {
                                Text(String(format: "%.0f%%", pct * 100))
                                    .foregroundStyle(DiskMapTheme.mutedLabel)
                            }
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(categoryFilter == roll.category ? DiskMapTheme.navSelected : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private var ecosystemsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Developer ecosystems")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DiskMapTheme.ink)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(summary.ecosystems.prefix(8)) { eco in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: eco.ecosystem.symbolName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(DiskMapTheme.developer)
                                Text(eco.ecosystem.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(DiskMapTheme.ink)
                            }
                            Text(ByteFormat.string(eco.bytes))
                                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                                .foregroundStyle(DiskMapTheme.ink)
                            Text("\(eco.itemCount) items")
                                .font(.system(size: 10))
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                        }
                        .padding(12)
                        .frame(width: 140, alignment: .leading)
                        .background(cardBackground)
                    }
                }
            }
        }
    }

    private var opportunitiesRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Best opportunities")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DiskMapTheme.ink)
                Spacer()
                Button("Review all") {
                    tableTab = .opportunities
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DiskMapTheme.developer)
                .buttonStyle(.plain)
            }
            if catalog.opportunities.isEmpty {
                Text("No clear reclaim opportunities in this scan root.")
                    .font(.system(size: 12))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                    ForEach(catalog.opportunities.prefix(4)) { item in
                        Button {
                            selectedID = item.id
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.displayName)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(DiskMapTheme.ink)
                                        .lineLimit(1)
                                    Text(item.safety.level.title)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(safetyColor(item.safety.level))
                                }
                                Spacer(minLength: 0)
                                Text(ByteFormat.string(item.bytes))
                                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(DiskMapTheme.ink)
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(selectedID == item.id ? DiskMapTheme.navSelected : DiskMapTheme.cardFill)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var tableSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ForEach(TableTab.allCases) { tab in
                    let count: Int = {
                        switch tab {
                        case .projects: return catalog.projects.count
                        case .allItems: return filteredItems.count
                        case .opportunities: return catalog.opportunities.count
                        }
                    }()
                    Button {
                        tableTab = tab
                    } label: {
                        Text("\(tab.title) (\(count))")
                            .font(.system(size: 12, weight: tableTab == tab ? .semibold : .regular))
                            .foregroundStyle(tableTab == tab ? DiskMapTheme.ink : DiskMapTheme.mutedLabel)
                            .padding(.bottom, 8)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(tableTab == tab ? DiskMapTheme.developer : Color.clear)
                                    .frame(height: 2)
                            }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                TextField("Filter…", text: $query)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(width: 180)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(DiskMapTheme.cardFill)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                            )
                    )
            }
            .padding(.bottom, 8)

            Divider().overlay(DiskMapTheme.cardStroke)

            switch tableTab {
            case .projects:
                projectsTable
            case .allItems:
                itemsTable(filteredItems)
            case .opportunities:
                itemsTable(catalog.opportunities)
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private var filteredItems: [DeveloperItem] {
        var list = catalog.items
        if let categoryFilter {
            list = list.filter { $0.category == categoryFilter }
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.displayName.lowercased().contains(q)
                    || $0.displayPath.lowercased().contains(q)
                    || $0.ecosystem.title.lowercased().contains(q)
            }
        }
        return list
    }

    private var filteredProjects: [DeveloperProject] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return catalog.projects }
        return catalog.projects.filter {
            $0.name.lowercased().contains(q)
                || $0.displayPath.lowercased().contains(q)
                || $0.ecosystem.title.lowercased().contains(q)
        }
    }

    private var projectsTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Project").frame(maxWidth: .infinity, alignment: .leading)
                Text("Eco").frame(width: 72, alignment: .leading)
                Text("Size").frame(width: 72, alignment: .trailing)
                Text("Items").frame(width: 44, alignment: .trailing)
                Text("Reclaimable").frame(width: 80, alignment: .trailing)
                Text("Status").frame(width: 110, alignment: .leading)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(DiskMapTheme.mutedLabel)
            .padding(.vertical, 8)

            if filteredProjects.isEmpty {
                Text("No project-scoped developer folders found (e.g. node_modules, Pods, .venv).")
                    .font(.system(size: 12))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(filteredProjects.prefix(40)) { proj in
                    Button {
                        selectedID = catalog.items.first(where: { proj.nodeIDs.contains($0.nodeID) })?.id ?? proj.id
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(proj.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(DiskMapTheme.ink)
                                    .lineLimit(1)
                                Text(proj.displayPath)
                                    .font(.system(size: 10))
                                    .foregroundStyle(DiskMapTheme.mutedLabel)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(proj.ecosystem.title)
                                .font(.system(size: 11))
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                                .frame(width: 72, alignment: .leading)
                                .lineLimit(1)
                            Text(ByteFormat.string(proj.bytes))
                                .font(.system(size: 11).monospacedDigit())
                                .frame(width: 72, alignment: .trailing)
                            Text("\(proj.itemCount)")
                                .font(.system(size: 11).monospacedDigit())
                                .frame(width: 44, alignment: .trailing)
                            Text(ByteFormat.string(proj.reclaimableBytes))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(DiskMapTheme.safe)
                                .frame(width: 80, alignment: .trailing)
                            Text(proj.status)
                                .font(.system(size: 11))
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                                .frame(width: 110, alignment: .leading)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isProjectSelected(proj) ? DiskMapTheme.navSelected : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(DiskMapTheme.cardStroke.opacity(0.6))
                }
            }
        }
    }

    private func itemsTable(_ items: [DeveloperItem]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Item").frame(maxWidth: .infinity, alignment: .leading)
                Text("Category").frame(width: 100, alignment: .leading)
                Text("Eco").frame(width: 72, alignment: .leading)
                Text("Size").frame(width: 72, alignment: .trailing)
                Text("Safety").frame(width: 100, alignment: .leading)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(DiskMapTheme.mutedLabel)
            .padding(.vertical, 8)

            if items.isEmpty {
                Text("No matching developer items.")
                    .font(.system(size: 12))
                    .foregroundStyle(DiskMapTheme.mutedLabel)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(items.prefix(60)) { item in
                    Button {
                        selectedID = item.id
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.displayName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(DiskMapTheme.ink)
                                    .lineLimit(1)
                                Text(item.displayPath)
                                    .font(.system(size: 10))
                                    .foregroundStyle(DiskMapTheme.mutedLabel)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(item.category.shortTitle)
                                .font(.system(size: 11))
                                .frame(width: 100, alignment: .leading)
                                .lineLimit(1)
                            Text(item.ecosystem.title)
                                .font(.system(size: 11))
                                .foregroundStyle(DiskMapTheme.mutedLabel)
                                .frame(width: 72, alignment: .leading)
                                .lineLimit(1)
                            Text(ByteFormat.string(item.bytes))
                                .font(.system(size: 11).monospacedDigit())
                                .frame(width: 72, alignment: .trailing)
                            Text(item.safety.level.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(safetyColor(item.safety.level))
                                .frame(width: 100, alignment: .leading)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selectedID == item.id ? DiskMapTheme.navSelected : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(DiskMapTheme.cardStroke.opacity(0.6))
                }
            }
        }
    }

    private var inspector: some View {
        Group {
            if let item = activeItem {
                DeveloperInspector(
                    model: model,
                    item: item,
                    onOpenCleanup: onOpenCleanup
                )
            } else {
                VStack(spacing: 8) {
                    Text("Select an item")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.ink)
                    Text("Pick an opportunity, project, or developer folder to see why it’s large and whether it’s safe to clear.")
                        .font(.system(size: 12))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DiskMapTheme.cardFill.opacity(0.5))
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(DiskMapTheme.cardFill)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
            )
    }


    private func isProjectSelected(_ proj: DeveloperProject) -> Bool {
        guard let selectedID,
              let item = catalog.items.first(where: { $0.id == selectedID }) else {
            return false
        }
        return proj.nodeIDs.contains(item.nodeID)
    }

    private func percent(_ part: Int64, of total: Int64) -> String {
        guard total > 0 else { return "—" }
        return String(format: "%.0f%% of developer storage", Double(part) / Double(total) * 100)
    }

    private func color(for category: DeveloperCategory) -> Color {
        switch category {
        case .dependencies: return Color(red: 0.30, green: 0.55, blue: 0.95)
        case .caches: return DiskMapTheme.safe
        case .buildArtifacts: return DiskMapTheme.review
        case .containers: return DiskMapTheme.developer
        case .sdksSimulators: return Color(red: 0.90, green: 0.40, blue: 0.55)
        case .other: return DiskMapTheme.mutedLabel.opacity(0.55)
        }
    }

    private func safetyColor(_ level: SafetyLevel) -> Color {
        switch level {
        case .safe: return DiskMapTheme.safe
        case .review: return DiskMapTheme.review
        case .protected: return DiskMapTheme.danger
        }
    }
}

private struct DeveloperInspector: View {
    @ObservedObject var model: ScanModel
    let item: DeveloperItem
    var onOpenCleanup: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    Image(systemName: item.ecosystem.symbolName)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(DiskMapTheme.developer)
                        .frame(width: 40, height: 40)
                        .background(DiskMapTheme.navSelected, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.displayName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(DiskMapTheme.ink)
                        Text(ByteFormat.string(item.bytes))
                            .font(.system(size: 20, weight: .semibold).monospacedDigit())
                            .foregroundStyle(DiskMapTheme.ink)
                        Text(item.safety.level.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(badgeColor)
                    }
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 6) {
                    StatRow(label: "Path", value: item.displayPath)
                    StatRow(label: "Category", value: item.category.title)
                    StatRow(label: "Ecosystem", value: item.ecosystem.title)
                    if let project = item.projectName {
                        StatRow(label: "Project", value: project)
                    }
                    StatRow(label: "Reclaimability", value: reclaimTitle)
                }

                WhyCard(title: "Why is it large?", bodyText: item.whyLarge)
                SafetyCard(assessment: item.safety)

                section("What happens if I remove it?") {
                    Text(item.safety.consequences)
                        .font(.system(size: 12))
                        .foregroundStyle(DiskMapTheme.ink.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(item.safety.recommendedAction)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DiskMapTheme.mutedLabel)
                        .padding(.top, 4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 8) {
                    Button {
                        Task { await stage() }
                    } label: {
                        Label("Add to Cleanup", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryCTAStyle(fullWidth: true))
                    .disabled(item.isProtected)

                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.absolutePath)])
                    }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))

                    Button("Open in File Browser") {
                        model.currentNode = item.nodeID
                        model.selectedNode = item.nodeID
                        model.destination = .fileBrowser
                    }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))

                    Button("Visualize this folder") {
                        model.currentNode = item.nodeID
                        model.selectedNode = item.nodeID
                        model.destination = .visualize
                    }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))

                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.absolutePath, forType: .string)
                        model.showToast("Path copied")
                    }
                    .buttonStyle(InkButtonStyle(filled: false, fullWidth: true))
                }
            }
            .padding(16)
        }
    }

    private var badgeColor: Color {
        switch item.safety.level {
        case .safe: return DiskMapTheme.safe
        case .review: return DiskMapTheme.review
        case .protected: return DiskMapTheme.danger
        }
    }

    private var reclaimTitle: String {
        switch item.reclaimability {
        case .reclaimable: return "Potentially reclaimable"
        case .reviewFirst: return "Review first"
        case .keep: return "Likely keep"
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DiskMapTheme.mutedLabel)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DiskMapTheme.cream.opacity(0.8))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DiskMapTheme.cardStroke, lineWidth: 1)
                )
        )
    }

    private func stage() async {
        guard let root = model.rootURL, let tree = model.tree else { return }
        let url = tree.path(of: item.nodeID, root: root)
        let result = await model.stageForCleanup([
            CleanupStageRequest(url: url, size: item.bytes, reason: "Developer: \(item.displayName)")
        ])
        model.showToast(result.added > 0 ? "Added to Cleanup" : (result.rejected > 0 ? "Blocked by safety rules" : "Already in Cleanup"))
        if result.added > 0 || result.alreadyPresent > 0 { onOpenCleanup() }
    }
}
