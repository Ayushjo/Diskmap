import Foundation

public enum DeveloperCategory: String, Sendable, Equatable, CaseIterable, Identifiable {
    case dependencies
    case caches
    case buildArtifacts
    case containers
    case sdksSimulators
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dependencies: return "Dependencies"
        case .caches: return "Caches"
        case .buildArtifacts: return "Build Artifacts"
        case .containers: return "Containers"
        case .sdksSimulators: return "SDKs & Simulators"
        case .other: return "Other"
        }
    }

    public var shortTitle: String { title }
}

public enum DeveloperEcosystem: String, Sendable, Equatable, CaseIterable, Identifiable {
    case node
    case docker
    case xcode
    case python
    case android
    case rust
    case flutter
    case jvm
    case ideAI
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .node: return "Node.js"
        case .docker: return "Docker"
        case .xcode: return "Xcode"
        case .python: return "Python"
        case .android: return "Android"
        case .rust: return "Rust"
        case .flutter: return "Flutter / Dart"
        case .jvm: return "JVM / Gradle"
        case .ideAI: return "IDE / AI"
        case .other: return "Other"
        }
    }

    public var symbolName: String {
        switch self {
        case .node: return "shippingbox.fill"
        case .docker: return "shippingbox"
        case .xcode: return "hammer.fill"
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .android: return "antenna.radiowaves.left.and.right"
        case .rust: return "gearshape.2"
        case .flutter: return "paintbrush.pointed"
        case .jvm: return "cylinder.split.1x2"
        case .ideAI: return "cpu"
        case .other: return "folder"
        }
    }
}

/// Whether bytes are treated as reclaimable in the summary split.
public enum DeveloperReclaimability: String, Sendable, Equatable {
    /// Safe caches / regenerable build products.
    case reclaimable
    /// Needs judgment (deps, simulators, docker volumes).
    case reviewFirst
    /// Prefer keep (toolchains, SDKs, protected).
    case keep
}

public struct DeveloperItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var nodeID: Int32
    public var displayName: String
    public var absolutePath: String
    public var displayPath: String
    public var bytes: Int64
    public var category: DeveloperCategory
    public var ecosystem: DeveloperEcosystem
    public var safety: SafetyAssessment
    public var reclaimability: DeveloperReclaimability
    public var whyLarge: String
    public var projectKey: String?
    public var projectName: String?
    public var modifiedDay: Int32
    public var isToolRoot: Bool

    public var isProtected: Bool { safety.level == .protected }
}

public struct DeveloperProject: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var displayPath: String
    public var absolutePath: String
    public var ecosystem: DeveloperEcosystem
    public var bytes: Int64
    public var reclaimableBytes: Int64
    public var itemCount: Int
    public var modifiedDay: Int32
    public var status: String
    public var nodeIDs: [Int32]
}

public struct DeveloperEcosystemRollup: Sendable, Equatable, Identifiable {
    public var id: String { ecosystem.id }
    public var ecosystem: DeveloperEcosystem
    public var bytes: Int64
    public var itemCount: Int
}

public struct DeveloperCategoryRollup: Sendable, Equatable, Identifiable {
    public var id: String { category.id }
    public var category: DeveloperCategory
    public var bytes: Int64
}

public struct DeveloperSummary: Sendable, Equatable {
    public var totalBytes: Int64
    public var reclaimableBytes: Int64
    public var keepBytes: Int64
    public var toolCount: Int
    public var projectCount: Int
    public var itemCount: Int
    public var categories: [DeveloperCategoryRollup]
    public var ecosystems: [DeveloperEcosystemRollup]

    public static let empty = DeveloperSummary(
        totalBytes: 0, reclaimableBytes: 0, keepBytes: 0,
        toolCount: 0, projectCount: 0, itemCount: 0,
        categories: [], ecosystems: []
    )

    public var reclaimableFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(reclaimableBytes) / Double(totalBytes)
    }
}

public struct DeveloperCatalogResult: Sendable, Equatable {
    public var items: [DeveloperItem]
    public var projects: [DeveloperProject]
    public var opportunities: [DeveloperItem]
    public var summary: DeveloperSummary

    public static let empty = DeveloperCatalogResult(
        items: [], projects: [], opportunities: [], summary: .empty
    )
}

/// Classifies known developer directories from an existing scan — no second walk of disk.
public enum DeveloperCatalog {
    struct Rule {
        var names: Set<String>
        var category: DeveloperCategory
        var ecosystem: DeveloperEcosystem
        var reclaimability: DeveloperReclaimability
        var isToolRoot: Bool
        var projectFromParent: Bool
        var whyLarge: String
    }

    /// Rules are data (AGENTS.md rule 6): `developer-rules.json`, bundled.
    /// Moved out of Swift on 2026-09-28 with byte-identical catalog output on
    /// a frozen real home scan (see TASKS.md, Milestone 11).
    private static let rules: [Rule] = loadRules()

    private struct RuleFile: Decodable {
        struct Entry: Decodable {
            var names: [String]
            var category: String
            var ecosystem: String
            var reclaimability: String
            var isToolRoot: Bool
            var projectFromParent: Bool
            var whyLarge: String
        }
        var rules: [Entry]
    }

    /// A malformed or missing file yields no rules rather than a crash; the
    /// test suite asserts the bundled file decodes completely.
    static func loadRules(from data: Data? = nil) -> [Rule] {
        let bytes = data ?? Bundle.module.url(forResource: "developer-rules", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
        guard let bytes, let file = try? JSONDecoder().decode(RuleFile.self, from: bytes) else { return [] }
        return file.rules.compactMap { entry in
            guard let category = DeveloperCategory(rawValue: entry.category),
                  let ecosystem = DeveloperEcosystem(rawValue: entry.ecosystem),
                  let reclaimability = DeveloperReclaimability(rawValue: entry.reclaimability) else { return nil }
            return Rule(
                names: Set(entry.names),
                category: category,
                ecosystem: ecosystem,
                reclaimability: reclaimability,
                isToolRoot: entry.isToolRoot,
                projectFromParent: entry.projectFromParent,
                whyLarge: entry.whyLarge
            )
        }
    }

    /// For tests: how many rules the bundled file produced.
    static var loadedRuleCount: Int { rules.count }

    private static let nameToRule: [String: Rule] = {
        var map: [String: Rule] = [:]
        for rule in rules {
            for name in rule.names {
                map[name.lowercased()] = rule
            }
        }
        return map
    }()

    public static func build(
        tree: FileTree,
        root: URL,
        totals: [Int64],
        limit: Int = 500
    ) -> DeveloperCatalogResult {
        guard totals.count == tree.count else { return .empty }

        var hits: [(id: Int32, rule: Rule, bytes: Int64, path: String, name: String)] = []
        for id in 0..<Int32(tree.count) {
            let i = Int(id)
            guard tree.isDirectory[i] else { continue }
            let name = tree.name(of: id)
            let key = name.lowercased()
            guard let rule = nameToRule[key] else { continue }
            // Avoid matching bare "sdk" / "build" / "dist" / "out" outside likely contexts
            if !isPlausibleHit(name: key, pathHint: tree.path(of: id, root: root).path, rule: rule) {
                continue
            }
            let bytes = totals[i]
            guard bytes > 0 else { continue }
            let path = tree.path(of: id, root: root).path
            hits.append((id, rule, bytes, path, name))
        }

        hits.sort { $0.bytes > $1.bytes }

        // Prefer outer directories: skip if an ancestor was already kept.
        var kept: [(id: Int32, rule: Rule, bytes: Int64, path: String, name: String)] = []
        var keptIDs: [Int32] = []
        for hit in hits {
            let ancestors = Set(tree.ancestorIDs(of: hit.id))
            if keptIDs.contains(where: { ancestors.contains($0) && $0 != hit.id }) {
                continue
            }
            // Also drop if this hit contains an already-kept descendant? Prefer larger outer — already sorted by size so outer often first.
            // If a smaller nested was somehow kept first, replace: skip adding nested when ancestor kept (done).
            kept.append(hit)
            keptIDs.append(hit.id)
            if kept.count >= limit { break }
        }

        let home = root.path
        var items: [DeveloperItem] = []
        items.reserveCapacity(kept.count)

        for hit in kept {
            let safety = SafetyClassifier.assess(path: hit.path, name: hit.name, isDirectory: true)
            var reclaim = hit.rule.reclaimability
            if safety.level == .protected {
                reclaim = .keep
            } else if safety.level == .safe, reclaim == .reviewFirst {
                reclaim = .reclaimable
            } else if safety.level == .safe {
                reclaim = .reclaimable
            }

            let ecosystem = refineEcosystem(rule: hit.rule, path: hit.path, name: hit.name)
            let category = refineCategory(rule: hit.rule, path: hit.path, name: hit.name)

            var projectKey: String?
            var projectName: String?
            if hit.rule.projectFromParent {
                let parentID = tree.parent[Int(hit.id)]
                if parentID >= 0 {
                    let pname = tree.name(of: parentID)
                    let ppath = tree.path(of: parentID, root: root).path
                    projectKey = ppath
                    projectName = pname
                }
            }

            let display = safety.title.isEmpty ? displayTitle(name: hit.name, rule: hit.rule) : safety.title
            items.append(DeveloperItem(
                id: "dev-\(hit.id)",
                nodeID: hit.id,
                displayName: display,
                absolutePath: hit.path,
                displayPath: shorten(hit.path, home: home),
                bytes: hit.bytes,
                category: category,
                ecosystem: ecosystem,
                safety: safety,
                reclaimability: reclaim,
                whyLarge: hit.rule.whyLarge,
                projectKey: projectKey,
                projectName: projectName,
                modifiedDay: tree.modifiedDay[Int(hit.id)],
                isToolRoot: hit.rule.isToolRoot || projectKey == nil
            ))
        }

        items.sort { $0.bytes > $1.bytes }
        let projects = buildProjects(from: items)
        let opportunities = items
            .filter { $0.reclaimability != .keep && !$0.isProtected }
            .prefix(12)
            .map { $0 }
        let summary = summarize(items: items, projects: projects)
        return DeveloperCatalogResult(
            items: items,
            projects: projects,
            opportunities: Array(opportunities),
            summary: summary
        )
    }

    private static func isPlausibleHit(name: String, pathHint: String, rule: Rule) -> Bool {
        let lower = pathHint.lowercased()
        switch name {
        case "sdk":
            return lower.contains("android") || lower.contains("/library/android")
        case "android":
            return lower.contains("/library/") || lower.contains("android")
        case "build", "dist", "out":
            // Require sibling signals via path: node_modules parent, xcodeproj nearby is hard; require parent not home Library
            if lower.contains("/library/") && !lower.contains("/developer/") { return false }
            if lower.hasSuffix("/build") || lower.hasSuffix("/dist") || lower.hasSuffix("/out") {
                return true
            }
            return rule.projectFromParent
        case "xcode":
            return lower.contains("/developer/") || lower.contains("xcode")
        default:
            return true
        }
    }

    private static func refineEcosystem(rule: Rule, path: String, name: String) -> DeveloperEcosystem {
        let lower = path.lowercased()
        let n = name.lowercased()
        if n == "build" || n == "dist" || n == "out" || n == ".build" || n == ".next" {
            if lower.contains("node_modules") || lower.contains("/.next") || lower.contains("package.json") {
                return .node
            }
            if lower.contains(".xcodeproj") || lower.contains("/developer/") { return .xcode }
            if lower.contains("/target/") || lower.contains("cargo.toml") { return .rust }
        }
        if n == "sdk" || n == "android" || lower.contains("android") { return .android }
        if lower.contains("docker") { return .docker }
        return rule.ecosystem
    }

    private static func refineCategory(rule: Rule, path: String, name: String) -> DeveloperCategory {
        let lower = path.lowercased()
        let n = name.lowercased()
        if n == "coresimulator" || lower.contains("devicesupport") { return .sdksSimulators }
        if lower.contains("/library/containers/com.docker") || n == ".docker" { return .containers }
        return rule.category
    }

    private static func displayTitle(name: String, rule: Rule) -> String {
        switch name.lowercased() {
        case ".npm": return "npm cache"
        case "deriveddata": return "Xcode DerivedData"
        case "coresimulator": return "iOS Simulators"
        case "node_modules": return "node_modules"
        case ".docker": return "Docker data"
        default: return name
        }
    }

    private static func shorten(_ path: String, home: String) -> String {
        if path.hasPrefix(home) {
            let rest = String(path.dropFirst(home.count))
            return "~" + (rest.hasPrefix("/") ? rest : "/" + rest)
        }
        let nsHome = NSHomeDirectory()
        if path.hasPrefix(nsHome) {
            return "~" + String(path.dropFirst(nsHome.count))
        }
        return path
    }

    private static func buildProjects(from items: [DeveloperItem]) -> [DeveloperProject] {
        var groups: [String: (name: String, path: String, eco: DeveloperEcosystem, bytes: Int64, reclaim: Int64, count: Int, day: Int32, nodes: [Int32])] = [:]
        for item in items {
            guard let key = item.projectKey, let name = item.projectName else { continue }
            var g = groups[key] ?? (name, key, item.ecosystem, 0, 0, 0, 0, [])
            g.bytes += item.bytes
            if item.reclaimability != .keep { g.reclaim += item.bytes }
            g.count += 1
            g.day = max(g.day, item.modifiedDay)
            g.nodes.append(item.nodeID)
            // Prefer non-other ecosystem
            if g.eco == .other { g.eco = item.ecosystem }
            groups[key] = g
        }
        var projects: [DeveloperProject] = groups.map { key, g in
            let status: String
            if g.reclaim >= g.bytes / 2 {
                status = "Has reclaimable"
            } else if g.day > 0 {
                let age = ageLabel(modifiedDay: g.day)
                status = age
            } else {
                status = "Active unknown"
            }
            return DeveloperProject(
                id: key,
                name: g.name,
                displayPath: shorten(g.path, home: ""),
                absolutePath: g.path,
                ecosystem: g.eco,
                bytes: g.bytes,
                reclaimableBytes: g.reclaim,
                itemCount: g.count,
                modifiedDay: g.day,
                status: status,
                nodeIDs: g.nodes
            )
        }
        projects.sort { $0.bytes > $1.bytes }
        return projects
    }

    private static func ageLabel(modifiedDay: Int32) -> String {
        guard modifiedDay > 0 else { return "Unknown activity" }
        let today = Int32(Date().timeIntervalSince1970 / 86_400)
        let age = max(0, today - modifiedDay)
        if age < 30 { return "Recently active" }
        if age < 180 { return "Moderately active" }
        if age < 365 { return "Quiet" }
        return "Stale"
    }

    public static func summarize(items: [DeveloperItem], projects: [DeveloperProject]) -> DeveloperSummary {
        var total: Int64 = 0
        var reclaim: Int64 = 0
        var keep: Int64 = 0
        var catBytes: [DeveloperCategory: Int64] = [:]
        var ecoBytes: [DeveloperEcosystem: Int64] = [:]
        var ecoCount: [DeveloperEcosystem: Int] = [:]
        var toolIDs = Set<String>()

        for item in items {
            total += item.bytes
            switch item.reclaimability {
            case .reclaimable, .reviewFirst:
                reclaim += item.bytes
            case .keep:
                keep += item.bytes
            }
            catBytes[item.category, default: 0] += item.bytes
            ecoBytes[item.ecosystem, default: 0] += item.bytes
            ecoCount[item.ecosystem, default: 0] += 1
            if item.isToolRoot { toolIDs.insert(item.id) }
        }

        // Split reviewFirst half? Ref shows reclaimable vs keep — treat reviewFirst as reclaimable potential.
        // keep already counted; if reclaim+keep != total due to nothing — ok.

        let categories = DeveloperCategory.allCases.compactMap { cat -> DeveloperCategoryRollup? in
            let b = catBytes[cat] ?? 0
            guard b > 0 else { return nil }
            return DeveloperCategoryRollup(category: cat, bytes: b)
        }
        let ecosystems = ecoBytes
            .map { DeveloperEcosystemRollup(ecosystem: $0.key, bytes: $0.value, itemCount: ecoCount[$0.key] ?? 0) }
            .sorted { $0.bytes > $1.bytes }

        return DeveloperSummary(
            totalBytes: total,
            reclaimableBytes: reclaim,
            keepBytes: keep,
            toolCount: toolIDs.count,
            projectCount: projects.count,
            itemCount: items.count,
            categories: categories,
            ecosystems: ecosystems
        )
    }
}
