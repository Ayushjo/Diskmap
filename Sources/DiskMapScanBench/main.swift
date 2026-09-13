import DiskMapCore
import Foundation

/// Stable release bench for DiskMap scans.
///
/// Usage:
///   DiskMapScanBench [--repeat N] [--rollup] [--json] [--label NAME] [path]
///
/// Prints one line per run plus a summary (min / median / max). Record
/// cold vs warm disk context in docs/PERF.md alongside these numbers.
struct Args {
    var path = NSHomeDirectory()
    var repeats = 1
    var rollup = false
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
        case "--json":
            args.json = true
        case "--label":
            args.label = rest.first ?? args.label
            if !rest.isEmpty { rest.removeFirst() }
        case "--help", "-h":
            print("DiskMapScanBench [--repeat N] [--rollup] [--json] [--label NAME] [path]")
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

let args = parseArgs()
let root = URL(fileURLWithPath: args.path, isDirectory: true)
var rows: [RunRow] = []

for run in 1...args.repeats {
    let engine = ScanEngine()
    let result = await engine.scan(root: root)
    let foot = result.tree.storageFootprint()
    var rollupSeconds: Double?
    if args.rollup {
        let started = ContinuousClock.now
        _ = result.tree.rollUpBoth()
        let elapsed = started.duration(to: .now)
        let parts = elapsed.components
        rollupSeconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
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
        print(
            "run=\(run)/\(args.repeats) label=\(args.label) items=\(row.items) nodes=\(row.nodes) scan=\(String(format: "%.3f", row.scanSeconds))s\(rollup) walk_rss=\(row.walkPeakRSS) after_rss=\(row.afterScanRSS.map(String.init) ?? "n/a") names=\(row.uniqueNames) name_utf8=\(row.nameUTF8Bytes)"
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
