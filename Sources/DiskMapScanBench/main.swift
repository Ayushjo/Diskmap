import CoreGraphics
import DiskMapCore
import Foundation

/// Stable release bench for DiskMap scans.
///
/// Usage:
///   DiskMapScanBench [--repeat N] [--rollup] [--layout] [--duplicates] [--json] [--label NAME] [path]
///
/// Prints one line per run plus a summary (min / median / max). Record
/// cold vs warm disk context in docs/PERF.md alongside these numbers.
struct Args {
    var path = NSHomeDirectory()
    var repeats = 1
    var rollup = false
    var layout = false
    var duplicates = false
    /// Time `StorageSharing.profile` (what staging a folder costs) on the path.
    var profileOnly = false
    /// Time every step between "walk finished" and "UI can paint", in the
    /// order ContentView.scan runs them (TASK-042).
    var phases = false
    /// Equivalence checks for catalog refactors: freeze a scan, then dump
    /// catalog output from exactly the same tree before and after a change.
    var saveSnapshot: String?
    var fromSnapshot: String?
    var catalogDump: String?
    /// With --from-snapshot: time FileQuery (TASK-059) on a frozen tree.
    var queries: [String] = []
    var json = false
    var label = "scan"
}

func parseArgs() -> Args {
    var args = Args()
    var rest = Array(CommandLine.arguments.dropFirst())
    while let token = rest.first {
        rest.removeFirst()
        switch token {
        case "--repeat":
            args.repeats = max(1, Int(rest.first ?? "1") ?? 1)
            if !rest.isEmpty { rest.removeFirst() }
        case "--rollup":
            args.rollup = true
        case "--layout":
            args.layout = true
        case "--duplicates":
            args.duplicates = true
        case "--profile":
            args.profileOnly = true
        case "--phases":
            args.phases = true
        case "--save-snapshot":
            args.saveSnapshot = rest.first
            if !rest.isEmpty { rest.removeFirst() }
        case "--from-snapshot":
            args.fromSnapshot = rest.first
            if !rest.isEmpty { rest.removeFirst() }
        case "--catalog-dump":
            args.catalogDump = rest.first
            if !rest.isEmpty { rest.removeFirst() }
        case "--query":
            if let text = rest.first { args.queries.append(text); rest.removeFirst() }
        case "--json":
            args.json = true
        case "--label":
            args.label = rest.first ?? args.label
            if !rest.isEmpty { rest.removeFirst() }
        case "--help", "-h":
            print("DiskMapScanBench [--repeat N] [--rollup] [--layout] [--duplicates] [--json] [--label NAME] [path]")
            exit(0)
        default:
            if token.hasPrefix("-") {
                fputs("unknown flag \(token)\n", stderr)
                exit(2)
            }
            args.path = token
        }
    }
    return args
}

struct RunRow: Codable {
    var label: String
    var path: String
    var run: Int
    var items: Int
    var nodes: Int
    var notDownloaded: Int
    var scanSeconds: Double
    var rollupSeconds: Double?
    var layoutSeconds: Double?
    var walkPeakRSS: UInt64
    var afterScanRSS: UInt64?
    var uniqueNames: Int
    var nameUTF8Bytes: Int
    var packedExact: Int
    var packedReserved: Int
}

struct Summary: Codable {
    var label: String
    var path: String
    var runs: [RunRow]
    var scanMin: Double
    var scanMedian: Double
    var scanMax: Double
}

/// Nearest-rank percentile. p95 is the figure TASK-046 tracks: a user who
/// sees 6 s once and 11 s the next concludes the app is unreliable, so the
/// tail matters more than the median. Needs ~20 runs to mean anything.
func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
    return sorted[max(0, min(sorted.count - 1, rank - 1))]
}

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    let mid = sorted.count / 2
    if sorted.count % 2 == 0 {
        return (sorted[mid - 1] + sorted[mid]) / 2
    }
    return sorted[mid]
}

func durationSeconds(from start: ContinuousClock.Instant) -> Double {
    let parts = start.duration(to: .now).components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
}

let args = parseArgs()
let root = URL(fileURLWithPath: args.path, isDirectory: true)

/// One line per candidate, every field that reaches the UI, sorted — so two
/// dumps of the same tree diff to nothing if a refactor is behaviour-neutral.
func dumpCatalogs(tree: FileTree, root: URL, to path: String) throws {
    let totals = tree.rollUpBoth().allocated
    let today: Int32 = 20_000   // fixed so age fields are comparable across runs
    var lines: [String] = []
    let media = MediaCatalog.build(tree: tree, root: root, totals: totals, today: today)
    for c in media.candidates {
        lines.append(["media", c.absolutePath, c.displayPath, c.name, "\(c.bytes)", "\(c.ageDays)", "\(c.kind)",
                      "\(c.location)", "\(c.status)", "\(c.safety.level)", c.whyHere, c.recommendation,
                      "\(c.isDirectory)", String(format: "%.6f", c.score)].joined(separator: "\t"))
    }
    lines.append("media-summary\t\(media.summary)")
    lines.append("media-opportunities\t" + media.opportunities.map(\.absolutePath).joined(separator: "|"))
    let downloads = OldDownloadsCatalog.build(tree: tree, root: root, totals: totals, today: today)
    for c in downloads.candidates {
        lines.append(["downloads", c.absolutePath, c.displayPath, c.name, "\(c.bytes)", "\(c.ageDays)", "\(c.kind)",
                      "\(c.status)", "\(c.safety.level)", c.whyHere, c.recommendation,
                      String(format: "%.6f", c.score)].joined(separator: "\t"))
    }
    lines.append("downloads-summary\t\(downloads.summary)")
    let dev = DeveloperCatalog.build(tree: tree, root: root, totals: totals)
    for i in dev.items {
        lines.append(["dev-item", i.absolutePath, i.displayName, i.displayPath, "\(i.bytes)", "\(i.category)", "\(i.ecosystem)",
                      "\(i.reclaimability)", "\(i.safety.level)", i.whyLarge, i.projectKey ?? "-", i.projectName ?? "-",
                      "\(i.isToolRoot)"].joined(separator: "\t"))
    }
    for p in dev.projects {
        lines.append(["dev-project", p.absolutePath, p.name, "\(p.ecosystem)", "\(p.bytes)", "\(p.reclaimableBytes)",
                      "\(p.itemCount)"].joined(separator: "\t"))
    }
    for p in dev.projects where p.repositoryPath != nil {
        lines.append(["dev-repo", p.absolutePath, p.repositoryPath ?? "-", p.git.title, "\(p.ignoredBytes ?? -1)",
                      p.manifest ?? "-", p.lockfile ?? "-", "\(p.rebuildCost)", "\(p.lastSourceDay)"].joined(separator: "\t"))
    }
    lines.append("dev-opportunities\t" + dev.opportunities.map(\.absolutePath).joined(separator: "|"))
    lines.append("dev-summary\t\(dev.summary.totalBytes)\t\(dev.summary.reclaimableBytes)\t\(dev.summary.keepBytes)\t\(dev.summary.toolCount)\t\(dev.summary.projectCount)")
    for t in FileTypeCatalog.totals(in: tree, sizes: totals, categories: FileTypeCatalog.loadBundled()) {
        lines.append("filetypes\t\(t.categoryID)\t\(t.label)\t\(t.bytes)")
    }
    try (lines.sorted().joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    print("catalog-dump lines=\(lines.count) media=\(media.candidates.count) downloads=\(downloads.candidates.count) -> \(path)")
}

if let snapshotPath = args.fromSnapshot {
    let snapshot = try SnapshotStore.load(from: URL(fileURLWithPath: snapshotPath))
    let snapRoot = URL(fileURLWithPath: snapshot.rootPath, isDirectory: true)
    if let dump = args.catalogDump {
        let started = ContinuousClock.now
        try dumpCatalogs(tree: snapshot.tree, root: snapRoot, to: dump)
        print("catalog-dump seconds=\(String(format: "%.3f", durationSeconds(from: started)))")
    }
    if !args.queries.isEmpty {
        let totals = snapshot.tree.rollUpBoth().allocated
        for text in args.queries {
            let query = FileQuery.parse(text, home: snapshot.rootPath, root: snapshot.rootPath).query
            var times: [Double] = []
            var matches = 0
            for _ in 1...args.repeats {
                let started = ContinuousClock.now
                matches = query.run(tree: snapshot.tree, root: snapRoot, totals: totals,
                                    context: .init(home: snapshot.rootPath), limit: 500).matchCount
                times.append(durationSeconds(from: started) * 1000)
            }
            times.sort()
            print("query \"\(text)\" matches=\(matches) ms min=\(String(format: "%.1f", times[0])) "
                + "median=\(String(format: "%.1f", times[times.count / 2])) max=\(String(format: "%.1f", times[times.count - 1]))")
        }
    }
    if args.phases {
        let phases = timePostWalkPhases(tree: snapshot.tree, root: snapRoot)
        print("phases-from-snapshot " + phases.map { "\($0.0)=\(String(format: "%.3f", $0.1))" }.joined(separator: " "))
    }
    exit(0)
}

if args.profileOnly {
    for run in 1...args.repeats {
        let started = ContinuousClock.now
        let profile = StorageSharing.profile(atPath: root.path)
        let seconds = durationSeconds(from: started)
        print("profile run=\(run)/\(args.repeats) label=\(args.label) seconds=\(String(format: "%.3f", seconds)) "
            + "files=\(profile?.fileCount ?? -1) allocated=\(profile?.allocatedBytes ?? -1) "
            + "unattributed_shared=\(profile?.sharedUnattributedBytes ?? -1) complete=\(profile?.isComplete ?? false) "
            + "apfs_accounting=\(profile?.usesFilesystemAccounting ?? false)")
    }
    exit(0)
}
var rows: [RunRow] = []
var phaseRuns: [[(String, Double)]] = []

/// Mirrors the detached `PreparedScan` block in ContentView.scan, step for
/// step, so the numbers describe what a user waits through after the walk.
func timePostWalkPhases(tree: FileTree, root: URL) -> [(String, Double)] {
    var out: [(String, Double)] = []
    func time<T>(_ name: String, _ body: () -> T) -> T {
        let started = ContinuousClock.now
        let value = body()
        out.append((name, durationSeconds(from: started)))
        return value
    }
    let categories = FileTypeCatalog.loadBundled()
    let both = time("rollUpBoth") { tree.rollUpBoth() }
    _ = time("rollUpDescendantCounts") { tree.rollUpDescendantCounts() }
    let quickWins = time("QuickWins") { QuickWins.find(in: tree, root: root, patterns: QuickWins.bundledPatterns()) }
    _ = time("FileTypes") { FileTypeCatalog.totals(in: tree, sizes: both.allocated, categories: categories) }
    _ = time("AnalysisSnapshot") {
        AnalysisSnapshot.build(tree: tree, root: root, allocated: both.allocated, logical: both.logical,
                               basis: .allocated, quickWins: quickWins)
    }
    _ = time("ForgottenFiles") { ForgottenFiles.candidates(tree: tree, root: root, totals: both.allocated, limit: 400) }
    _ = time("ReviewableCatalog") { ReviewableCatalog.build(tree: tree, root: root, totals: both.allocated, quickWins: quickWins) }
    _ = time("DeveloperCatalog") { DeveloperCatalog.build(tree: tree, root: root, totals: both.allocated) }
    _ = time("OldDownloadsCatalog") { OldDownloadsCatalog.build(tree: tree, root: root, totals: both.allocated) }
    _ = time("MediaCatalog") { MediaCatalog.build(tree: tree, root: root, totals: both.allocated) }
    _ = time("layout") {
        _ = ChartLayout.slices(of: 0, in: tree, totals: both.allocated)
        let children = tree.children(of: 0, totals: both.allocated)
        _ = SquarifiedTreemap.layout(items: children, in: CGRect(x: 0, y: 0, width: 1200, height: 800))
        return 0
    }
    return out
}

for run in 1...args.repeats {
    let engine = ScanEngine()
    let result = await engine.scan(root: root)
    let foot = result.tree.storageFootprint()
    if let target = args.saveSnapshot, run == 1 {
        // `target` is a directory; SnapshotStore picks the file name.
        let directory = URL(fileURLWithPath: target, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let saved = try SnapshotStore.save(
            DiskSnapshot(rootPath: root.path, capturedAt: Date(), tree: result.tree), in: directory)
        print("snapshot saved -> \(saved.path)")
    }
    if args.phases {
        let phases = [("walk", result.elapsedSeconds)] + timePostWalkPhases(tree: result.tree, root: root)
        phaseRuns.append(phases)
        let postWalk = phases.dropFirst().map(\.1).reduce(0, +)
        print("phases run=\(run)/\(args.repeats) label=\(args.label) "
            + phases.map { "\($0.0)=\(String(format: "%.3f", $0.1))" }.joined(separator: " ")
            + " post_walk_total=\(String(format: "%.3f", postWalk))")
        fflush(stdout)
    }
    var rollupSeconds: Double?
    var layoutSeconds: Double?
    var totals: (logical: [Int64], allocated: [Int64])?

    if args.rollup || args.layout {
        let started = ContinuousClock.now
        totals = result.tree.rollUpBoth()
        let seconds = durationSeconds(from: started)
        if args.rollup { rollupSeconds = seconds }
        // TASK-037: what hard-link de-duplication removed from those totals.
        let correction = result.tree.hardLinkCorrection()
        print("hardlinks label=\(args.label) flagged=\(result.hardLinkCount) "
            + "inodes=\(correction.inodeCount) duplicate_names=\(correction.duplicateNameCount) "
            + "allocated_not_double_counted=\(correction.allocatedBytes) "
            + "logical_not_double_counted=\(correction.logicalBytes) "
            + "cross_mount_skips=\(result.crossMountSkipCount)")
        fflush(stdout)
    }

    if args.layout, let totals {
        let started = ContinuousClock.now
        let tree = result.tree
        let allocated = totals.allocated
        _ = ChartLayout.slices(of: 0, in: tree, totals: allocated)
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let children = tree.children(of: 0, totals: allocated)
        _ = SquarifiedTreemap.layout(items: children, in: bounds)
        _ = TopSizes.ranked(totals: allocated, limit: 50)
        _ = AgeMap.bucketSizes(in: tree, totals: allocated, today: AgeMap.today())
        _ = AgeMap.untouched(in: tree, totals: allocated, today: AgeMap.today(), limit: 100)
        layoutSeconds = durationSeconds(from: started)
    }

    if args.duplicates {
        let tree = result.tree
        let cands = DuplicateFinder.candidates(in: tree, root: root)
        let before = ProcessMemory.current()
        let samplePeak = MutexPeak()
        samplePeak.value = before?.residentBytes ?? 0
        let sampler = Task.detached {
            while !Task.isCancelled {
                if let rss = ProcessMemory.current()?.residentBytes {
                    samplePeak.update(rss)
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        let started = ContinuousClock.now
        let dupResult = try await DuplicateFinder.scan(cands)
        let dupSeconds = durationSeconds(from: started)
        sampler.cancel()
        let after = ProcessMemory.current()
        let peak = max(samplePeak.value, after?.residentBytes ?? 0, before?.residentBytes ?? 0)
        print(
            "duplicates label=\(args.label) candidates=\(cands.count) groups=\(dupResult.groups.count) full_hash_calls=\(dupResult.fullContentHashCalls) elapsed=\(String(format: "%.3f", dupSeconds))s rss_before=\(before?.residentBytes ?? 0) rss_peak_sampled=\(peak) rss_after=\(after?.residentBytes ?? 0) task_peak=\(after?.peakResidentBytes ?? 0)"
        )
    }

    let row = RunRow(
        label: args.label,
        path: root.path,
        run: run,
        items: result.itemCount,
        nodes: result.tree.count,
        notDownloaded: result.notDownloadedCount,
        scanSeconds: result.elapsedSeconds,
        rollupSeconds: rollupSeconds,
        layoutSeconds: layoutSeconds,
        walkPeakRSS: result.peakResidentBytesDuringWalk,
        afterScanRSS: result.residentBytesAfterEnumeratorRelease,
        uniqueNames: foot.uniqueNameCount,
        nameUTF8Bytes: foot.nameUTF8Bytes,
        packedExact: foot.packedNodeBytesExact,
        packedReserved: foot.packedNodeBytesReserved
    )
    rows.append(row)
    if !args.json {
        let rollup = row.rollupSeconds.map { String(format: " rollup=%.3fs", $0) } ?? ""
        let layout = row.layoutSeconds.map { String(format: " layout=%.3fs", $0) } ?? ""
        print(
            "run=\(run)/\(args.repeats) label=\(args.label) items=\(row.items) nodes=\(row.nodes) scan=\(String(format: "%.3f", row.scanSeconds))s\(rollup)\(layout) walk_rss=\(row.walkPeakRSS) after_rss=\(row.afterScanRSS.map(String.init) ?? "n/a") names=\(row.uniqueNames) name_utf8=\(row.nameUTF8Bytes)"
        )
    }
}

if args.phases, let first = phaseRuns.first {
    print("phase summary label=\(args.label) n=\(phaseRuns.count)  (seconds: min / median / max)")
    var names = first.map(\.0)
    names.append("post_walk_total")
    for (index, name) in names.enumerated() {
        let values: [Double] = phaseRuns.map { run in
            name == "post_walk_total" ? run.dropFirst().map(\.1).reduce(0, +) : run[index].1
        }
        print("  \(name.padding(toLength: 24, withPad: " ", startingAt: 0)) "
            + "\(String(format: "%.3f", values.min() ?? 0)) / \(String(format: "%.3f", median(values))) / \(String(format: "%.3f", values.max() ?? 0))")
    }
}

let scans = rows.map(\.scanSeconds)
if args.json {
    let payload = Summary(
        label: args.label,
        path: root.path,
        runs: rows,
        scanMin: scans.min() ?? 0,
        scanMedian: median(scans),
        scanMax: scans.max() ?? 0
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(payload)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} else {
    print(
        "summary label=\(args.label) n=\(rows.count) scan_min=\(String(format: "%.3f", scans.min() ?? 0)) scan_median=\(String(format: "%.3f", median(scans))) scan_max=\(String(format: "%.3f", scans.max() ?? 0)) scan_p95=\(String(format: "%.3f", percentile(scans, 95))) walk_rss_median=\(rows.map(\.walkPeakRSS).sorted()[rows.count / 2])"
    )
}


/// Tiny peak tracker for the duplicates RSS sampler.
final class MutexPeak: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: UInt64 = 0
    var value: UInt64 {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
    func update(_ rss: UInt64) {
        lock.lock()
        if rss > _value { _value = rss }
        lock.unlock()
    }
}
