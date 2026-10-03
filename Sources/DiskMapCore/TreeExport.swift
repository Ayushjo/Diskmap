import Foundation

/// Scan exports shared by the `diskmap` CLI and the app (TASK-057/058).
/// Offline by construction: they write to a caller-supplied sink.
public enum ExportFormat: String, Sendable, CaseIterable {
    /// One nested JSON document: {"schema":1,…,"tree":{…,"children":[…]}}.
    case json
    /// One JSON object per line — streams into `jq`, databases, log tools.
    case ndjson
    /// RFC 4180: path,type,size_bytes,logical_bytes,modified.
    case csv
    /// ncdu's `-o` export format (`ncdu -f file` to browse it). Always the
    /// whole tree: ncdu computes folder totals itself, so filtering would make
    /// them wrong.
    case ncdu

    public var fileExtension: String {
        switch self {
        case .json, .ncdu: return "json"
        case .ndjson: return "ndjson"
        case .csv: return "csv"
        }
    }
}

public struct ExportOptions: Sendable {
    /// Leave out anything smaller than this (json/ndjson/csv only).
    public var minBytes: Int64 = 0
    /// Stop expanding below this depth; the root is depth 0.
    public var maxDepth: Int? = nil
    public init(minBytes: Int64 = 0, maxDepth: Int? = nil) {
        self.minBytes = minBytes
        self.maxDepth = maxDepth
    }
}

public enum TreeExporter {
    /// Writes `tree` in `format`. Paths are carried down the walk, never
    /// rebuilt per node (building a full path per node was the multi-second
    /// cost removed from the catalogs in TASK-069). `write` receives chunks.
    public static func export(
        tree: FileTree,
        root: URL,
        allocated: [Int64],
        logical: [Int64],
        format: ExportFormat,
        options: ExportOptions = ExportOptions(),
        scannedAt: Date = Date(),
        write: (String) -> Void
    ) {
        guard tree.count > 0, allocated.count == tree.count, logical.count == tree.count else { return }
        // The writer does not outlive this call; the buffer only holds it while exporting.
        withoutActuallyEscaping(write) { write in
            var out = Buffered(write: write)
            switch format {
            case .json:
                out.append("{\"schema\":1,\"generator\":\"diskmap\",\"root\":\(jsonString(root.path)),")
                out.append("\"scannedAt\":\(Int(scannedAt.timeIntervalSince1970)),\"sizeBasis\":\"allocated\",\"tree\":")
                writeJSONNode(0, depth: 0, name: root.path, tree: tree, allocated: allocated, logical: logical, options: options, out: &out)
                out.append("}\n")
            case .ndjson:
                walkFlat(tree: tree, root: root, allocated: allocated, options: options) { id, path, depth in
                    out.append("{\"path\":\(jsonString(path)),\"type\":\"\(tree.isDirectory[Int(id)] ? "dir" : "file")\",")
                    out.append("\"size\":\(allocated[Int(id)]),\"logicalSize\":\(logical[Int(id)]),")
                    out.append("\"modified\":\"\(isoDay(tree.modifiedDay[Int(id)]))\",\"depth\":\(depth)}\n")
                }
            case .csv:
                out.append("path,type,size_bytes,logical_bytes,modified\n")
                walkFlat(tree: tree, root: root, allocated: allocated, options: options) { id, path, _ in
                    out.append(csvField(path) + ",\(tree.isDirectory[Int(id)] ? "dir" : "file"),")
                    out.append("\(allocated[Int(id)]),\(logical[Int(id)]),\(isoDay(tree.modifiedDay[Int(id)]))\n")
                }
            case .ncdu:
                out.append("[1,1,{\"progname\":\"diskmap\",\"progver\":\"1\",\"timestamp\":\(Int(scannedAt.timeIntervalSince1970))},\n")
                writeNcduDirectory(0, name: root.path, tree: tree, out: &out)
                out.append("]\n")
            }
            out.flush()
        }
    }

    // MARK: Formats

    private static func sortedChildren(_ id: Int32, tree: FileTree, allocated: [Int64]) -> [Int32] {
        var children: [Int32] = []
        var child = tree.firstChild[Int(id)]
        while child != -1 {
            children.append(child)
            child = tree.nextSibling[Int(child)]
        }
        return children.sorted { allocated[Int($0)] != allocated[Int($1)] ? allocated[Int($0)] > allocated[Int($1)] : $0 < $1 }
    }

    private static func writeJSONNode(
        _ id: Int32, depth: Int, name: String, tree: FileTree,
        allocated: [Int64], logical: [Int64], options: ExportOptions, out: inout Buffered
    ) {
        let index = Int(id)
        out.append("{\"name\":\(jsonString(name)),\"type\":\"\(tree.isDirectory[index] ? "dir" : "file")\",")
        out.append("\"size\":\(allocated[index]),\"logicalSize\":\(logical[index]),\"modified\":\"\(isoDay(tree.modifiedDay[index]))\"")
        if tree.isDirectory[index] {
            if let maxDepth = options.maxDepth, depth >= maxDepth {
                out.append(",\"truncated\":true}")
                return
            }
            out.append(",\"children\":[")
            var first = true
            for child in sortedChildren(id, tree: tree, allocated: allocated) where allocated[Int(child)] >= options.minBytes {
                if !first { out.append(",") }
                first = false
                writeJSONNode(child, depth: depth + 1, name: tree.name(of: child), tree: tree,
                              allocated: allocated, logical: logical, options: options, out: &out)
            }
            out.append("]")
        }
        out.append("}")
    }

    /// Depth-first, largest first, carrying the path string down the stack.
    private static func walkFlat(
        tree: FileTree, root: URL, allocated: [Int64], options: ExportOptions,
        visit: (Int32, String, Int) -> Void
    ) {
        var stack: [(id: Int32, path: String, depth: Int)] = [(0, root.path, 0)]
        while let frame = stack.popLast() {
            guard frame.id == 0 || allocated[Int(frame.id)] >= options.minBytes else { continue }
            visit(frame.id, frame.path, frame.depth)
            guard tree.isDirectory[Int(frame.id)] else { continue }
            if let maxDepth = options.maxDepth, frame.depth >= maxDepth { continue }
            let prefix = frame.path.hasSuffix("/") ? frame.path : frame.path + "/"
            // Reversed so the largest child is popped (and written) first.
            for child in sortedChildren(frame.id, tree: tree, allocated: allocated).reversed() {
                stack.append((child, prefix + tree.name(of: child), frame.depth + 1))
            }
        }
    }

    /// ncdu: a directory is an array whose first element describes it; files
    /// are objects. `asize` = apparent (logical) size, `dsize` = disk usage.
    private static func writeNcduDirectory(_ id: Int32, name: String, tree: FileTree, out: inout Buffered) {
        out.append("[")
        writeNcduInfo(id, name: name, tree: tree, out: &out)
        var child = tree.firstChild[Int(id)]
        while child != -1 {
            out.append(",\n")
            if tree.isDirectory[Int(child)] {
                writeNcduDirectory(child, name: tree.name(of: child), tree: tree, out: &out)
            } else {
                writeNcduInfo(child, name: tree.name(of: child), tree: tree, out: &out)
            }
            child = tree.nextSibling[Int(child)]
        }
        out.append("]")
    }

    private static func writeNcduInfo(_ id: Int32, name: String, tree: FileTree, out: inout Buffered) {
        let index = Int(id)
        out.append("{\"name\":\(jsonString(name)),\"asize\":\(tree.logicalSize[index]),\"dsize\":\(tree.allocatedSize[index])")
        if tree.fileID[index] != 0 { out.append(",\"ino\":\(tree.fileID[index])") }
        if tree.flags[index] & NodeFlags.hardLink != 0 { out.append(",\"hlnkc\":true") }
        out.append("}")
    }

    // MARK: Encoding helpers

    static func jsonString(_ s: String) -> String {
        // Fast path: most file names need no escaping at all.
        if !s.utf8.contains(where: { $0 < 0x20 || $0 == 0x22 || $0 == 0x5C }) {
            return "\"" + s + "\""
        }
        var out = "\""
        out.reserveCapacity(s.utf8.count + 2)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func csvField(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Days since 1970-01-01 → "YYYY-MM-DD" without a DateFormatter per node
    /// (Howard Hinnant's civil-from-days). Day 0 is "unknown" → "".
    public static func isoDay(_ day: Int32) -> String {
        guard day > 0 else { return "" }
        if let cached = isoDayCache.value(day) { return cached }
        let text = computeISODay(day)
        isoDayCache.store(day, text)
        return text
    }

    /// Dates repeat heavily across a tree (a few thousand distinct days for
    /// millions of files), and `String(format:)` per row dominated NDJSON/CSV
    /// export time.
    private static let isoDayCache = DayCache()

    private final class DayCache: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [Int32: String] = [:]
        func value(_ day: Int32) -> String? { lock.lock(); defer { lock.unlock() }; return map[day] }
        func store(_ day: Int32, _ text: String) { lock.lock(); map[day] = text; lock.unlock() }
    }

    private static func computeISODay(_ day: Int32) -> String {
        let z = Int(day) + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    private struct Buffered {
        let write: (String) -> Void
        var pending = ""
        mutating func append(_ s: String) {
            pending += s
            if pending.utf8.count >= 1 << 16 { flush() }
        }
        mutating func flush() {
            guard !pending.isEmpty else { return }
            write(pending)
            pending = ""
        }
    }
}

/// Parsing of human sizes and ages for the CLI (TASK-057).
public enum HumanUnits {
    /// "50GB", "1.5 TB", "500M", "2GiB", "123" (bytes). Decimal units are
    /// powers of 1000, as Finder reports sizes; "iB" units are powers of 1024.
    public static func bytes(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        let numberPart = trimmed.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(numberPart), value >= 0 else { return nil }
        let unit = trimmed.dropFirst(numberPart.count).trimmingCharacters(in: .whitespaces)
        let multipliers: [String: Double] = [
            "": 1, "B": 1,
            "K": 1e3, "KB": 1e3, "M": 1e6, "MB": 1e6, "G": 1e9, "GB": 1e9, "T": 1e12, "TB": 1e12,
            "KIB": 1_024, "MIB": 1_048_576, "GIB": 1_073_741_824, "TIB": 1_099_511_627_776,
        ]
        guard let multiplier = multipliers[unit] else { return nil }
        let bytes = value * multiplier
        return bytes < Double(Int64.max) ? Int64(bytes) : nil
    }

    /// "30d", "2w", "6m" (30-day months), "1y" → days.
    public static func days(_ text: String) -> Int32? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let unit = trimmed.last, let value = Int32(trimmed.dropLast()), value >= 0 else { return nil }
        switch unit {
        case "d": return value
        case "w": return value * 7
        case "m": return value * 30
        case "y": return value * 365
        default: return nil
        }
    }

    public static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false   // "0 bytes", not "Zero KB"
        return formatter.string(fromByteCount: bytes)
    }
}
