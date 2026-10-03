import DiskMapCore
import Foundation

// diskmap — the command-line companion (TASK-057). A thin layer over
// DiskMapCore, which has no UI imports precisely so this can exist.
// Reads only. Never deletes, never touches the network.

let usage = """
diskmap — offline disk usage for your Mac. Reads only; never deletes anything.

USAGE
  diskmap scan <path> [--top N] [--json]
      Size of a folder, its largest subfolders and files.
  diskmap dev [<path>] [--reclaimable] [--older-than 6m] [--json]
      Developer storage: dependencies, build output, caches — with rebuild
      cost, lockfile, git state and last change per project. Default path: ~
  diskmap dup <path> [--min-size 1MB] [--json]
      Files with identical contents (APFS clones are reported as shared).
  diskmap check <path> --fail-over <size> [--json]
      Exit 1 when the folder is larger than <size> — for CI or git hooks.
  diskmap find <path> <query…> [--sort largest|oldest|newest] [--limit N] [--json]
      Files matching a query, e.g.  diskmap find ~ ext:mp4 size>500MB age>1y
      Keys: ext: name: kind: size> size< age> age< path: in: is: type:
      (in: downloads desktop documents library caches · is: duplicate
      hardlink cloud · kind: video audio image media document developer
      archive). Bare words match names; -word excludes.
  diskmap export <path> --format json|ndjson|csv|ncdu [--out FILE]
                 [--min-size SIZE] [--max-depth N]
      The whole scan, for jq, spreadsheets, or `ncdu -f FILE`.

--clones (any command): count each APFS clone family once — a file copied
    by Finder, cp -c or tools like pnpm shares blocks with the original.
    Without it every copy counts. Makes the scan roughly 15–20% longer.

--incremental (any command): start from the last scan of the same folder
    and re-read only what macOS reports as changed; falls back to a full
    walk when that can't be trusted. The cache lives in
    ~/Library/Application Support/DiskMap/ScanCache.

SIZES   50GB, 1.5TB, 500MB, 2GiB (GB = 1000³, as Finder reports; GiB = 1024³)
AGES    30d, 2w, 6m, 1y

EXIT CODES
  0 ok · 1 check threshold exceeded · 2 usage error · 3 path not readable
"""

enum Exit: Int32 { case ok = 0, thresholdExceeded = 1, usage = 2, path = 3 }

func fail(_ message: String, _ code: Exit) -> Never {
    FileHandle.standardError.write(Data(("diskmap: " + message + "\n").utf8))
    exit(code.rawValue)
}

func say(_ line: String = "") { print(line) }

// MARK: - Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
    say(usage)
    exit(arguments.isEmpty ? Exit.usage.rawValue : Exit.ok.rawValue)
}
if arguments.first == "--version" { say("diskmap 1"); exit(0) }

let command = arguments.removeFirst()
var flags: [String: String] = [:]
var switches = Set<String>()
var positional: [String] = []
let valued: Set<String> = ["--sort", "--limit", "--top", "--older-than", "--min-size", "--fail-over", "--format", "--out", "--max-depth"]
let booleans: Set<String> = ["--json", "--reclaimable", "--incremental", "--clones"]
while !arguments.isEmpty {
    let token = arguments.removeFirst()
    if valued.contains(token) {
        guard let value = arguments.first else { fail("\(token) needs a value", .usage) }
        flags[token] = value
        arguments.removeFirst()
    } else if booleans.contains(token) {
        switches.insert(token)
    } else if token.hasPrefix("--") || (token.hasPrefix("-") && command != "find") {
        fail("unknown option \(token) (see diskmap --help)", .usage)
    } else {
        positional.append(token)
    }
}
let json = switches.contains("--json")
let incremental = switches.contains("--incremental")
let sharing: SharingMode = switches.contains("--clones") ? .refcount : .off

func rootURL(default fallback: String? = nil) -> URL {
    guard let raw = positional.first ?? fallback else { fail("\(command) needs a path", .usage) }
    let expanded = (raw as NSString).expandingTildeInPath
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
        fail("not a readable folder: \(raw)", .path)
    }
    return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
}

func display(_ path: String) -> String { CanonicalPath.displayPath(absolutePath: path) }

// MARK: - Scanning

/// Progress goes to stderr, and only to a terminal: piped output stays clean.
func scan(_ root: URL) async -> ScanEngine.Result {
    let cache = ScanCache(directory: ScanCache.defaultDirectory(), slot: "cli")
    if incremental {
        switch await IncrementalScan.update(root: root, cache: cache, sharing: sharing) {
        case .updated(let update):
            FileHandle.standardError.write(Data(("updated from the last scan: \(update.changedDirectories) folders re-read, "
                + "\(update.rewalkedSubtrees) walked, \(update.spotChecked) spot-checked, "
                + "\(String(format: "%.2f", update.elapsedSeconds)) s\n").utf8))
            try? cache.save(tree: update.tree, baseline: update.baseline)
            return update.scanResult
        case .fullScanNeeded(let reason):
            FileHandle.standardError.write(Data("full scan: \(reason)\n".utf8))
        }
    }
    let interactive = isatty(STDERR_FILENO) != 0
    let result = await ScanEngine().scan(root: root, sharing: sharing, progress: { count in
        guard interactive else { return }
        FileHandle.standardError.write(Data("\rScanning… \(count.formatted()) items".utf8))
    })
    if interactive { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
    if incremental,
       let baseline = IncrementalScan.baselineAfterFullScan(
           root: root, eventIDAtStart: result.eventIDAtStart,
           deniedPaths: result.deniedDirectoryIDs.map { result.tree.path(of: $0, root: root).path }) {
        try? cache.save(tree: result.tree, baseline: baseline)
    }
    return result
}

func emitJSON(_ object: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
        fail("could not encode JSON", .usage)
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func deniedPaths(_ result: ScanEngine.Result, root: URL) -> [String] {
    result.deniedDirectoryIDs.map { result.tree.path(of: $0, root: root).path }
}

func warnDenied(_ denied: [String]) {
    guard !denied.isEmpty else { return }
    FileHandle.standardError.write(Data(("warning: \(denied.count) folder\(denied.count == 1 ? "" : "s") could not be read, so "
        + "totals are short. Grant Full Disk Access to your terminal to include them.\n").utf8))
}

// MARK: - Commands

switch command {
case "scan":
    let root = rootURL()
    let top = Int(flags["--top"] ?? "10") ?? 10
    let result = await scan(root)
    let tree = result.tree
    let totals = tree.rollUpBoth()
    let children = tree.children(of: 0, totals: totals.allocated).sorted { $0.size > $1.size }.prefix(top)
    let files = TopSizes.rankedFiles(tree: tree, totals: totals.allocated, limit: top)
    let denied = deniedPaths(result, root: root)
    let correction = tree.hardLinkCorrection()
    let clones = tree.sharingCorrection()
    if json {
        emitJSON([
            "schema": 1, "root": root.path,
            "sizeBytes": totals.allocated[0], "logicalBytes": totals.logical[0],
            "items": result.itemCount, "elapsedSeconds": result.elapsedSeconds,
            "hardLinkBytesNotDoubleCounted": correction.allocatedBytes,
            "clonesCountedOnce": tree.hasSharingInfo,
            "cloneBytesNotDoubleCounted": clones.bytes,
            "unreadableFolders": denied,
            "largestFolders": children.map { ["path": tree.path(of: $0.id, root: root).path, "sizeBytes": $0.size] },
            "largestFiles": files.map { ["path": tree.path(of: $0, root: root).path, "sizeBytes": totals.allocated[Int($0)]] },
        ])
    } else {
        say("\(display(root.path))  \(HumanUnits.format(totals.allocated[0])) on disk"
            + " · \(result.itemCount.formatted()) items · \(String(format: "%.1f", result.elapsedSeconds)) s")
        if correction.allocatedBytes > 0 {
            say("  (hard links: \(HumanUnits.format(correction.allocatedBytes)) counted once, not \(correction.duplicateNameCount + correction.inodeCount) times)")
        }
        if clones.bytes > 0 {
            say("  (APFS clones: \(HumanUnits.format(clones.bytes)) in \(clones.cloneCount.formatted()) copies counted once)")
        }
        say("\nLargest folders")
        for child in children where tree.isDirectory[Int(child.id)] {
            say("  \(HumanUnits.format(child.size).padding(toLength: 10, withPad: " ", startingAt: 0))  \(display(tree.path(of: child.id, root: root).path))")
        }
        say("\nLargest files")
        for id in files {
            say("  \(HumanUnits.format(totals.allocated[Int(id)]).padding(toLength: 10, withPad: " ", startingAt: 0))  \(display(tree.path(of: id, root: root).path))")
        }
    }
    warnDenied(denied)

case "dev":
    let root = rootURL(default: "~")
    var olderThan: Int32?
    if let raw = flags["--older-than"] {
        guard let days = HumanUnits.days(raw) else { fail("can't read age \(raw) (try 6m, 90d, 1y)", .usage) }
        olderThan = days
    }
    let result = await scan(root)
    let totals = result.tree.rollUpBoth().allocated
    let catalog = DeveloperCatalog.build(tree: result.tree, root: root, totals: totals)
    let today = AgeMap.today()
    var projects = catalog.projects
    if let olderThan {
        projects = projects.filter { $0.lastSourceDay > 0 && today - $0.lastSourceDay >= olderThan }
    }
    let keys = Set(projects.map(\.id))
    var items = catalog.items
    if olderThan != nil { items = items.filter { $0.projectKey.map(keys.contains) ?? false } }
    if switches.contains("--reclaimable") { items = items.filter { $0.reclaimability != .keep && !$0.isProtected } }
    if json {
        emitJSON([
            "schema": 1, "root": root.path,
            "summary": [
                "totalBytes": catalog.summary.totalBytes, "reclaimableBytes": catalog.summary.reclaimableBytes,
                "staleProjects": catalog.summary.staleProjectCount, "staleReclaimableBytes": catalog.summary.staleReclaimableBytes,
                "unpinnedBytes": catalog.summary.unpinnedBytes,
            ],
            "items": items.map { item -> [String: Any] in
                var row: [String: Any] = [
                    "path": item.absolutePath, "sizeBytes": item.bytes, "category": item.category.rawValue,
                    "ecosystem": item.ecosystem.rawValue, "rebuildCost": item.rebuildCost.rawValue,
                    "reclaimability": item.reclaimability.rawValue,
                ]
                if let project = item.projectKey { row["project"] = project }
                if let lockfile = item.lockfile { row["lockfile"] = lockfile }
                if let recipe = item.recipe { row["recipe"] = ["command": recipe.command, "trashIsUnsafe": recipe.trashIsUnsafe] }
                return row
            },
            "projects": projects.map { p -> [String: Any] in
                [
                    "path": p.absolutePath, "sizeBytes": p.bytes, "reclaimableBytes": p.reclaimableBytes,
                    "rebuildCost": p.rebuildCost.rawValue, "git": DevGit.key(p.git),
                    "lastSourceChange": TreeExporter.isoDay(p.lastSourceDay),
                    "ignoredByGitBytes": p.ignoredBytes ?? NSNull(),
                ]
            },
        ])
    } else {
        let s = catalog.summary
        say("Developer storage under \(display(root.path)): \(HumanUnits.format(s.totalBytes)), \(HumanUnits.format(s.reclaimableBytes)) potentially reclaimable")
        if s.staleProjectCount > 0 {
            say("\(s.staleProjectCount) project\(s.staleProjectCount == 1 ? " is" : "s are") untouched for 6+ months, holding \(HumanUnits.format(s.staleReclaimableBytes))")
        }
        if s.unpinnedBytes > 0 { say("\(HumanUnits.format(s.unpinnedBytes)) of dependencies have no lockfile") }
        say("\nFolders")
        for item in items.prefix(30) {
            let cost = DevGit.cost(item.rebuildCost).padding(toLength: 14, withPad: " ", startingAt: 0)
            say("  \(HumanUnits.format(item.bytes).padding(toLength: 10, withPad: " ", startingAt: 0))  \(cost)  \(display(item.absolutePath))")
            if let recipe = item.recipe {
                say("              \(recipe.trashIsUnsafe ? "don't trash — run" : "or run"): \(recipe.command)")
            }
        }
        say("\nProjects")
        for p in projects.prefix(20) {
            say("  \(HumanUnits.format(p.reclaimableBytes).padding(toLength: 10, withPad: " ", startingAt: 0))  "
                + "\(DevGit.key(p.git).padding(toLength: 10, withPad: " ", startingAt: 0))  "
                + "\(TreeExporter.isoDay(p.lastSourceDay).padding(toLength: 10, withPad: " ", startingAt: 0))  \(display(p.absolutePath))")
        }
    }

case "dup":
    let root = rootURL()
    let minSize = flags["--min-size"].map { HumanUnits.bytes($0) ?? -1 } ?? 1
    guard minSize >= 0 else { fail("can't read size \(flags["--min-size"] ?? "")", .usage) }
    let result = await scan(root)
    let candidates = DuplicateFinder.candidates(in: result.tree, root: root).filter { $0.size >= minSize }
    let groups = (try? await DuplicateFinder.scan(candidates))?.groups ?? []
    let sorted = groups.sorted { $0.sizeEach * Int64($0.fileIDs.count) > $1.sizeEach * Int64($1.fileIDs.count) }
    let onDisk: (Int32) -> Int64 = { result.tree.allocatedSize[Int($0)] }
    if json {
        emitJSON([
            "schema": 1, "root": root.path,
            "groups": sorted.map { g -> [String: Any] in
                [
                    "sizeEach": g.sizeEach, "sharesStorage": g.sharesStorage,
                    "reclaimableIfAllButOneRemoved": g.reclaimableBytes(deleting: Set(g.fileIDs.dropFirst()), onDisk: onDisk),
                    "paths": g.fileIDs.map { result.tree.path(of: $0, root: root).path },
                ]
            },
        ])
    } else {
        let total = sorted.reduce(Int64(0)) { $0 + $1.reclaimableBytes(deleting: Set($1.fileIDs.dropFirst()), onDisk: onDisk) }
        say("\(sorted.count) duplicate group\(sorted.count == 1 ? "" : "s"); keeping one of each frees \(HumanUnits.format(total))")
        for g in sorted.prefix(25) {
            say("\n\(HumanUnits.format(g.sizeEach)) × \(g.fileIDs.count)\(g.sharesStorage ? "  (APFS clones — share storage; frees nothing unless all go)" : "")")
            for id in g.fileIDs { say("  \(display(result.tree.path(of: id, root: root).path))") }
        }
    }

case "check":
    let root = rootURL()
    guard let raw = flags["--fail-over"] else { fail("check needs --fail-over <size>", .usage) }
    guard let limit = HumanUnits.bytes(raw) else { fail("can't read size \(raw)", .usage) }
    let result = await scan(root)
    let size = result.tree.rollUpBoth().allocated[0]
    let passed = size <= limit
    if json {
        emitJSON(["schema": 1, "root": root.path, "sizeBytes": size, "limitBytes": limit, "passed": passed])
    } else {
        say("\(passed ? "OK" : "FAIL")  \(display(root.path)) is \(HumanUnits.format(size)) (limit \(HumanUnits.format(limit)))")
    }
    warnDenied(deniedPaths(result, root: root))
    exit(passed ? Exit.ok.rawValue : Exit.thresholdExceeded.rawValue)

case "find":
    let root = rootURL()
    let text = positional.dropFirst().joined(separator: " ")
    guard !text.isEmpty else { fail("find needs a query, e.g. diskmap find ~ ext:mp4 size>500MB", .usage) }
    let home = NSHomeDirectory()
    let parsed = FileQuery.parse(text, home: home, root: root.path)
    for problem in parsed.problems {
        FileHandle.standardError.write(Data("warning: ignoring \(problem.token): \(problem.message)\n".utf8))
    }
    guard let sort = FileQuery.Sort(rawValue: flags["--sort"] ?? "largest") else { fail("--sort is largest, oldest or newest", .usage) }
    guard let limit = Int(flags["--limit"] ?? "50"), limit >= 0 else { fail("--limit needs a number", .usage) }
    let result = await scan(root)
    let tree = result.tree
    let totals = tree.rollUpBoth().allocated
    var duplicates: Set<Int32>?
    if parsed.query.flags.contains(.duplicate) {
        let groups = (try? await DuplicateFinder.scan(DuplicateFinder.candidates(in: tree, root: root)))?.groups ?? []
        duplicates = Set(groups.flatMap(\.fileIDs))
    }
    let started = Date()
    let found = parsed.query.run(tree: tree, root: root, totals: totals,
                                 context: .init(home: home, duplicateFileIDs: duplicates), sort: sort, limit: limit)
    let queryMilliseconds = Int(Date().timeIntervalSince(started) * 1000)
    for note in found.notes { FileHandle.standardError.write(Data("note: \(note)\n".utf8)) }
    if json {
        emitJSON([
            "schema": 1, "root": root.path, "query": text,
            "meaning": parsed.query.describe(home: home),
            "matchCount": found.matchCount, "matchedBytes": found.matchedBytes, "queryMilliseconds": queryMilliseconds,
            "results": found.ids.map { id -> [String: Any] in
                ["path": tree.path(of: id, root: root).path, "sizeBytes": totals[Int(id)],
                 "type": tree.isDirectory[Int(id)] ? "dir" : "file",
                 "modified": TreeExporter.isoDay(tree.modifiedDay[Int(id)])]
            },
        ])
    } else {
        say("\(parsed.query.describe(home: home).joined(separator: " · "))")
        say("\(found.matchCount.formatted()) match\(found.matchCount == 1 ? "" : "es") · \(HumanUnits.format(found.matchedBytes))"
            + (found.matchCount > found.ids.count ? " · showing \(found.ids.count) (--limit)" : "") + "\n")
        for id in found.ids {
            let day = TreeExporter.isoDay(tree.modifiedDay[Int(id)])
            say("  \(HumanUnits.format(totals[Int(id)]).padding(toLength: 10, withPad: " ", startingAt: 0))  \(day.padding(toLength: 10, withPad: " ", startingAt: 0))  \(display(tree.path(of: id, root: root).path))")
        }
    }
    warnDenied(deniedPaths(result, root: root))

case "export":
    let root = rootURL()
    guard let rawFormat = flags["--format"], let format = ExportFormat(rawValue: rawFormat) else {
        fail("export needs --format json|ndjson|csv|ncdu", .usage)
    }
    var options = ExportOptions()
    if let raw = flags["--min-size"] {
        guard let bytes = HumanUnits.bytes(raw) else { fail("can't read size \(raw)", .usage) }
        options.minBytes = bytes
    }
    if let raw = flags["--max-depth"] {
        guard let depth = Int(raw), depth >= 0 else { fail("--max-depth needs a number", .usage) }
        options.maxDepth = depth
    }
    if format == .ncdu && (options.minBytes > 0 || options.maxDepth != nil) {
        FileHandle.standardError.write(Data("note: ncdu exports are always the whole tree (ncdu sums folders itself)\n".utf8))
    }
    let result = await scan(root)
    let totals = result.tree.rollUpBoth()
    let handle: FileHandle
    if let out = flags["--out"] {
        let path = (out as NSString).expandingTildeInPath
        guard FileManager.default.createFile(atPath: path, contents: nil), let h = FileHandle(forWritingAtPath: path) else {
            fail("can't write \(out)", .path)
        }
        handle = h
    } else {
        handle = FileHandle.standardOutput
    }
    TreeExporter.export(tree: result.tree, root: root, allocated: totals.allocated, logical: totals.logical,
                        format: format, options: options) { chunk in handle.write(Data(chunk.utf8)) }
    if flags["--out"] != nil { try? handle.close() }
    warnDenied(deniedPaths(result, root: root))

default:
    fail("unknown command \(command) (see diskmap --help)", .usage)
}

enum DevGit {
    static func cost(_ cost: RebuildCost) -> String {
        switch cost {
        case .free: return "free"
        case .cheap: return "offline-build"
        case .networked: return "re-download"
        case .networkedUnpinned: return "no-lockfile"
        }
    }

    static func key(_ state: GitState) -> String {
        switch state {
        case .inSync: return "pushed"
        case .noRemote: return "no-remote"
        case .differs: return "unpushed"
        case .notARepository: return "no-git"
        case .unknown: return "unknown"
        }
    }
}
