import Foundation

public struct DiskSnapshot: Sendable {
    public var rootPath: String
    public var capturedAt: Date
    public var tree: FileTree

    public init(rootPath: String, capturedAt: Date, tree: FileTree) {
        self.rootPath = rootPath
        self.capturedAt = capturedAt
        self.tree = tree
    }
}

public struct SnapshotChange: Sendable, Equatable {
    public var path: String
    public var before: Int64
    public var after: Int64

    public var delta: Int64 { after - before }
}

enum SnapshotCodec {
    static let magic = Data("DMAP".utf8)
    static let version: UInt32 = 1

    static func encode(_ snapshot: DiskSnapshot) -> Data {
        var writer = Writer()
        writer.write(magic)
        writer.u32(version)
        writer.i64(Int64(snapshot.capturedAt.timeIntervalSince1970))
        writer.string(snapshot.rootPath)
        let tree = snapshot.tree
        writer.i32(Int32(tree.count))
        writer.i32(Int32(tree.nameTable.count))
        writer.i32s(tree.nameIndex)
        writer.i32s(tree.parent)
        writer.i32s(tree.firstChild)
        writer.i32s(tree.nextSibling)
        writer.i64s(tree.logicalSize)
        writer.i64s(tree.allocatedSize)
        writer.i32s(tree.modifiedDay)
        writer.flags(tree.isDirectory.map { $0 ? UInt8(1) : 0 })
        writer.flags(tree.flags)
        for name in tree.nameTable { writer.string(name) }
        return writer.data
    }

    static func decode(_ data: Data) throws -> DiskSnapshot {
        var reader = Reader(data)
        let magic = try reader.bytes(4)
        guard magic == self.magic else { throw SnapshotError.badMagic }
        guard try reader.u32() == version else { throw SnapshotError.badVersion }
        let capturedAt = Date(timeIntervalSince1970: TimeInterval(try reader.i64()))
        let rootPath = try reader.string()
        let count = Int(try reader.i32())
        let nameCount = Int(try reader.i32())
        guard count >= 0, nameCount >= 0, count < 50_000_000, nameCount < 50_000_000 else {
            throw SnapshotError.corrupt
        }
        let nameIndex = try reader.i32s(count)
        let parent = try reader.i32s(count)
        let firstChild = try reader.i32s(count)
        let nextSibling = try reader.i32s(count)
        let logicalSize = try reader.i64s(count)
        let allocatedSize = try reader.i64s(count)
        let modifiedDay = try reader.i32s(count)
        let isDirectory = try reader.flags(count).map { $0 != 0 }
        let flags = try reader.flags(count)
        var nameTable: [String] = []
        nameTable.reserveCapacity(nameCount)
        for _ in 0..<nameCount { nameTable.append(try reader.string()) }
        var tree = FileTree()
        guard tree.replacePacked(
            nameTable: nameTable,
            nameIndex: nameIndex,
            parent: parent,
            firstChild: firstChild,
            nextSibling: nextSibling,
            logicalSize: logicalSize,
            allocatedSize: allocatedSize,
            modifiedDay: modifiedDay,
            isDirectory: isDirectory,
            flags: flags
        ) else { throw SnapshotError.corrupt }
        return DiskSnapshot(rootPath: rootPath, capturedAt: capturedAt, tree: tree)
    }
}

public struct SnapshotHeader: Sendable, Equatable {
    public var rootPath: String
    public var capturedAt: Date
}

public enum SnapshotStore {
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("DiskMap/snapshots", isDirectory: true)
    }

    public static func save(_ snapshot: DiskSnapshot, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(Int(snapshot.capturedAt.timeIntervalSince1970))-\(UUID().uuidString).snapshot"
        let url = directory.appendingPathComponent(name)
        try SnapshotCodec.encode(snapshot).write(to: url, options: .atomic)
        return url
    }

    public static func load(from url: URL) throws -> DiskSnapshot {
        try SnapshotCodec.decode(Data(contentsOf: url))
    }

    /// Header only. Listing must not decode a million-node tree just to
    /// show a date.
    public static func readHeader(from url: URL) throws -> SnapshotHeader {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 65_536) ?? Data()
        var reader = Reader(data)
        let magic = try reader.bytes(4)
        guard magic == SnapshotCodec.magic else { throw SnapshotError.badMagic }
        guard try reader.u32() == SnapshotCodec.version else { throw SnapshotError.badVersion }
        let capturedAt = Date(timeIntervalSince1970: TimeInterval(try reader.i64()))
        let rootPath = try reader.string()
        return SnapshotHeader(rootPath: rootPath, capturedAt: capturedAt)
    }

    public static func summaries(in directory: URL, rootPath: String) -> [(url: URL, header: SnapshotHeader)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == "snapshot" }
            .compactMap { url -> (URL, SnapshotHeader)? in
                guard let header = try? readHeader(from: url), header.rootPath == rootPath else { return nil }
                return (url, header)
            }
            .sorted { $0.1.capturedAt < $1.1.capturedAt }
    }

    public static func list(in directory: URL, rootPath: String) -> [URL] {
        summaries(in: directory, rootPath: rootPath).map(\.url)
    }
}

public enum SnapshotDiff {
    /// Folder size changes between two snapshots of the same root, largest
    /// absolute change first. A folder present on only one side is a full
    /// grow or shrink, not an omitted row.
    public static func changes(before: DiskSnapshot, after: DiskSnapshot, basis: SizeBasis) -> [SnapshotChange] {
        let left = folderSizes(before, basis: basis)
        let right = folderSizes(after, basis: basis)
        var paths = Set(left.keys)
        paths.formUnion(right.keys)
        let rows = paths.map { path in
            SnapshotChange(path: path, before: left[path] ?? 0, after: right[path] ?? 0)
        }
        return rows
            .filter { $0.delta != 0 }
            .sorted { abs($0.delta) > abs($1.delta) }
    }

    private static func folderSizes(_ snapshot: DiskSnapshot, basis: SizeBasis) -> [String: Int64] {
        let totals = snapshot.tree.rollUpSizes(basis: basis)
        let root = URL(fileURLWithPath: snapshot.rootPath, isDirectory: true)
        var sizes: [String: Int64] = [:]
        guard snapshot.tree.count == totals.count else { return sizes }
        for id in 0..<Int32(snapshot.tree.count) where snapshot.tree.isDirectory[Int(id)] {
            sizes[snapshot.tree.path(of: id, root: root).standardizedFileURL.path] = totals[Int(id)]
        }
        return sizes
    }
}

public enum SnapshotError: Error, Equatable {
    case badMagic
    case badVersion
    case corrupt
}

private struct Writer {
    var data = Data()

    mutating func write(_ data: Data) { self.data.append(data) }
    mutating func u32(_ value: UInt32) { append(value.littleEndian) }
    mutating func i32(_ value: Int32) { append(value.littleEndian) }
    mutating func i64(_ value: Int64) { append(value.littleEndian) }
    mutating func i32s(_ values: [Int32]) { values.forEach { i32($0) } }
    mutating func i64s(_ values: [Int64]) { values.forEach { i64($0) } }
    mutating func flags(_ values: [UInt8]) { data.append(contentsOf: values) }
    mutating func string(_ value: String) {
        let bytes = Data(value.utf8)
        u32(UInt32(bytes.count))
        data.append(bytes)
    }

    private mutating func append<T>(_ value: T) {
        var copy = value
        withUnsafeBytes(of: &copy) { data.append(contentsOf: $0) }
    }
}

private struct Reader {
    let data: Data
    var offset = 0

    init(_ data: Data) { self.data = data }

    mutating func bytes(_ count: Int) throws -> Data {
        guard offset + count <= data.count else { throw SnapshotError.corrupt }
        let slice = data.subdata(in: offset..<(offset + count))
        offset += count
        return slice
    }

    mutating func u32() throws -> UInt32 { UInt32(littleEndian: try read()) }
    mutating func i32() throws -> Int32 { Int32(littleEndian: try read()) }
    mutating func i64() throws -> Int64 { Int64(littleEndian: try read()) }

    mutating func i32s(_ count: Int) throws -> [Int32] {
        try (0..<count).map { _ in try i32() }
    }

    mutating func i64s(_ count: Int) throws -> [Int64] {
        try (0..<count).map { _ in try i64() }
    }

    mutating func flags(_ count: Int) throws -> [UInt8] {
        Array(try bytes(count))
    }

    mutating func string() throws -> String {
        let count = Int(try u32())
        guard count >= 0, count < 10_000_000 else { throw SnapshotError.corrupt }
        let bytes = try bytes(count)
        guard let value = String(data: bytes, encoding: .utf8) else { throw SnapshotError.corrupt }
        return value
    }

    private mutating func read<T>() throws -> T {
        let count = MemoryLayout<T>.size
        let raw = try bytes(count)
        return raw.withUnsafeBytes { $0.loadUnaligned(as: T.self) }
    }
}
