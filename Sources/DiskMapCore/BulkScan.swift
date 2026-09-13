import Foundation

/// Parallel directory walk using `getattrlistbulk`. One syscall returns
/// a page of names and sizes. No `URL` and no `resourceValues` per file —
/// that pair was the 373 s home scan.
///
/// Record layout below was measured against the Command Line Tools SDK
/// (`ATTR_CMN_RETURNED_ATTRS` immediately after the length, `ATTR_CMN_ERROR`
/// next per the man page) and a real file whose URL size was 4 logical /
/// 4096 allocated. Changing the attribute mask moves these offsets.
enum BulkScan {
    struct Result: Sendable {
        var tree: FileTree
        var itemCount: Int
        var notDownloadedCount: Int
        var peakResidentBytesDuringWalk: UInt64
    }

    static func walk(root: URL, progress: (@Sendable (Int) -> Void)?) -> Result {
        var tree = FileTree()
        let rootID = tree.addNode(
            name: root.lastPathComponent,
            parent: -1,
            isDirectory: true,
            logicalSize: 0,
            allocatedSize: 0,
            modifiedDaysSinceEpoch: 0
        )
        let state = State(tree: tree, rootID: rootID, progress: progress)
        state.enqueue(path: root.path, nodeID: rootID)
        let workers = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
        let group = DispatchGroup()
        for _ in 0..<workers {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                worker(state)
                group.leave()
            }
        }
        group.wait()
        return state.finish()
    }

    private static func worker(_ state: State) {
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while let job = state.nextJob() {
            scan(job, buffer: &buffer, state: state)
        }
    }

    private static func scan(_ job: Job, buffer: inout [UInt8], state: State) {
        let fd = job.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else {
            state.noteEmptyDirectory()
            return
        }
        defer { close(fd) }

        var list = attrlist()
        memset(&list, 0, MemoryLayout<attrlist>.size)
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrReturned | attrName | attrError | attrObjType | attrModTime | attrFlags
        list.dirattr = attrDirAlloc | attrDirData
        list.fileattr = attrFileTotal | attrFileAlloc

        var names = [UInt8]()
        names.reserveCapacity(64 * 1024)
        var entries: [Entry] = []
        entries.reserveCapacity(256)

        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int32 in
                getattrlistbulk(fd, &list, raw.baseAddress, raw.count, options)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == ERANGE, buffer.count < 8 * 1024 * 1024 {
                    buffer = [UInt8](repeating: 0, count: buffer.count * 2)
                    continue
                }
                break
            }
            parse(buffer: buffer, count: Int(count), names: &names, entries: &entries)
        }
        state.publish(parent: job.nodeID, names: names, entries: entries)
    }

    /// Offsets measured 2026-09-14. Name bytes sit at `nameRef + dataOffset`.
    private static func parse(buffer: [UInt8], count: Int, names: inout [UInt8], entries: inout [Entry]) {
        var offset = 0
        for _ in 0..<count {
            guard offset + 4 <= buffer.count else { return }
            let length = Int(load(UInt32.self, buffer, offset))
            guard length >= fixedPrefix, offset + length <= buffer.count else { return }
            let error = load(UInt32.self, buffer, offset + 24)
            let nameOffset = load(Int32.self, buffer, offset + 28)
            let nameLength = Int(load(UInt32.self, buffer, offset + 32))
            let nameStart = offset + 28 + Int(nameOffset)
            let objType = load(UInt32.self, buffer, offset + 36)
            let modified = load(Int64.self, buffer, offset + 40)
            let flags = load(UInt32.self, buffer, offset + 56)
            let firstSize = load(Int64.self, buffer, offset + 60)
            let secondSize = load(Int64.self, buffer, offset + 68)
            defer { offset += length }

            guard error == 0, nameLength > 1, nameStart >= offset, nameStart + nameLength <= offset + length else {
                entries.append(Entry.skipped)
                continue
            }
            let rawName = buffer[nameStart..<(nameStart + nameLength - 1)]
            if rawName.count == 1, rawName.first == 46 { continue }
            if rawName.count == 2, rawName.first == 46, rawName.dropFirst().first == 46 { continue }

            let isLink = objType == vlunk
            let isDirectory = objType == vdir
            let dataless = flags & sfDataless != 0
            let logical: Int64
            let allocated: Int64
            if isDirectory {
                allocated = firstSize
                logical = secondSize
            } else {
                logical = firstSize
                allocated = secondSize
            }
            let start = names.count
            names.append(contentsOf: rawName)
            entries.append(Entry(
                nameStart: start,
                nameCount: rawName.count,
                include: !isLink,
                isDirectory: isDirectory,
                logical: logical,
                allocated: allocated > 0 ? allocated : logical,
                day: modifiedDay(modified),
                notDownloaded: dataless,
                descend: isDirectory && !isLink && !dataless
            ))
        }
    }

    private static func modifiedDay(_ seconds: Int64) -> Int32 {
        guard seconds > 0 else { return 0 }
        let days = seconds / 86400
        guard days <= Int64(Int32.max) else { return 0 }
        return Int32(days)
    }

    private static func load<T>(_ type: T.Type, _ buffer: [UInt8], _ offset: Int) -> T {
        buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: type) }
    }

    private final class State: @unchecked Sendable {
        private let condition = NSCondition()
        private var jobs: [Job] = []
        private var inflight = 0
        private var finished = false
        private var tree: FileTree
        private var itemCount = 0
        private var notDownloadedCount = 0
        private var peak: UInt64
        private let progress: (@Sendable (Int) -> Void)?
        private var lastReported = 0

        init(tree: FileTree, rootID: Int32, progress: (@Sendable (Int) -> Void)?) {
            self.tree = tree
            self.progress = progress
            self.peak = ProcessMemory.current()?.residentBytes ?? 0
            _ = rootID
        }

        func enqueue(path: String, nodeID: Int32) {
            condition.lock()
            pathByNode[nodeID] = path
            jobs.append(Job(path: path, nodeID: nodeID))
            condition.broadcast()
            condition.unlock()
        }

        func nextJob() -> Job? {
            condition.lock()
            defer { condition.unlock() }
            while jobs.isEmpty && !finished {
                condition.wait()
            }
            guard !jobs.isEmpty else { return nil }
            inflight += 1
            return jobs.removeLast()
        }

        func noteEmptyDirectory() {
            condition.lock()
            inflight -= 1
            if jobs.isEmpty && inflight == 0 {
                finished = true
                condition.broadcast()
            }
            condition.unlock()
        }

        func publish(parent: Int32, names: [UInt8], entries: [Entry]) {
            var children: [(path: String, nodeID: Int32)] = []
            var report: Int?
            condition.lock()
            let parentPath = pathByNode[parent] ?? ""
            itemCount += entries.count
            if itemCount - lastReported >= 4000 {
                lastReported = itemCount
                report = itemCount
            }
            names.withUnsafeBufferPointer { raw in
                guard let base = raw.baseAddress else { return }
                for entry in entries where entry.include {
                    let bytes = UnsafeBufferPointer(start: base + entry.nameStart, count: entry.nameCount)
                    var flags: UInt8 = 0
                    if entry.notDownloaded {
                        flags |= NodeFlags.notDownloaded
                        notDownloadedCount += 1
                    }
                    let id = tree.addNode(
                        utf8: bytes,
                        parent: parent,
                        isDirectory: entry.isDirectory,
                        logicalSize: entry.logical,
                        allocatedSize: entry.allocated,
                        modifiedDaysSinceEpoch: entry.day,
                        flags: flags
                    )
                    if entry.descend {
                        let name = String(decoding: bytes, as: UTF8.self)
                        let path = parentPath == "/" ? "/" + name : parentPath + "/" + name
                        pathByNode[id] = path
                        children.append((path, id))
                    }
                }
            }
            jobs.append(contentsOf: children.map { Job(path: $0.path, nodeID: $0.nodeID) })
            inflight -= 1
            if !children.isEmpty { condition.broadcast() }
            if jobs.isEmpty && inflight == 0 {
                finished = true
                condition.broadcast()
            }
            condition.unlock()
            if let report {
                if let rss = ProcessMemory.current()?.residentBytes {
                    condition.lock()
                    if rss > peak { peak = rss }
                    condition.unlock()
                }
                progress?(report)
            }
        }

        private var pathByNode: [Int32: String] = [:]

        func finish() -> Result {
            condition.lock()
            let result = Result(
                tree: tree,
                itemCount: itemCount,
                notDownloadedCount: notDownloadedCount,
                peakResidentBytesDuringWalk: max(peak, ProcessMemory.current()?.residentBytes ?? peak)
            )
            condition.unlock()
            return result
        }
    }
}

private struct Job {
    var path: String
    var nodeID: Int32
}

private struct Entry {
    var nameStart: Int
    var nameCount: Int
    var include: Bool
    var isDirectory: Bool
    var logical: Int64
    var allocated: Int64
    var day: Int32
    var notDownloaded: Bool
    var descend: Bool

    static let skipped = Entry(
        nameStart: 0,
        nameCount: 0,
        include: false,
        isDirectory: false,
        logical: 0,
        allocated: 0,
        day: 0,
        notDownloaded: false,
        descend: false
    )
}

/// `sys/attr.h` / `sys/vnode.h` / `sys/stat.h`. Numeric because
/// `ATTR_CMN_RETURNED_ATTRS` does not import as a sign-safe `UInt32`.
private let attrReturned: UInt32 = 0x80000000
private let attrName: UInt32 = 0x00000001
private let attrObjType: UInt32 = 0x00000008
private let attrModTime: UInt32 = 0x00000400
private let attrFlags: UInt32 = 0x00040000
private let attrError: UInt32 = 0x20000000
private let attrDirAlloc: UInt32 = 0x00000008
private let attrDirData: UInt32 = 0x00000020
private let attrFileTotal: UInt32 = 0x00000002
private let attrFileAlloc: UInt32 = 0x00000004
private let options = UInt64(FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS)
private let sfDataless: UInt32 = 0x40000000
private let vdir: UInt32 = 2
private let vlunk: UInt32 = 5
private let fixedPrefix = 76
