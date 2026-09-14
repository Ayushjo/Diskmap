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
var rows: [RunRow] = []

for run in 1...args.repeats {
    let engine = ScanEngine()
    let result = await engine.scan(root: root)
    let foot = result.tree.storageFootprint()
    var rollupSeconds: Double?
    var layoutSeconds: Double?
    var totals: (logical: [Int64], allocated: [Int64])?

    if args.rollup || args.layout {
        let started = ContinuousClock.now
        totals = result.tree.rollUpBoth()
        let seconds = durationSeconds(from: started)
        if args.rollup { rollupSeconds = seconds }
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
        let dupResult = await DuplicateFinder.scan(cands)
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
        "summary label=\(args.label) n=\(rows.count) scan_min=\(String(format: "%.3f", scans.min() ?? 0)) scan_median=\(String(format: "%.3f", median(scans))) scan_max=\(String(format: "%.3f", scans.max() ?? 0)) walk_rss_median=\(rows.map(\.walkPeakRSS).sorted()[rows.count / 2])"
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
