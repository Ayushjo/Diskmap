import Foundation

/// Parallel directory walk using `getattrlistbulk`. One syscall returns
/// a page of names and sizes. No `URL` and no `resourceValues` per file —
/// that pair was the 373 s home scan.
///
/// Record layout below was measured against the Command Line Tools SDK
/// (`ATTR_CMN_RETURNED_ATTRS` immediately after the length, `ATTR_CMN_ERROR`
/// next per the man page) and a real file whose URL size was 4 logical /
/// 4096 allocated. Changing the attribute mask moves these offsets.
///
/// Scan workers never mutate the `FileTree`. They push entry batches to a
/// dedicated publisher that owns all inserts and child-job enqueues. Child
/// paths stay as UTF-8 byte buffers (NUL-terminated for `open`) so the
/// publisher does not build intermediate `String` paths on the hot path.
///
/// Tuning (optional, for benches only):
/// - `DISKMAP_SCAN_WORKERS` — worker count (default: min(CPU count, 8))
/// - `DISKMAP_SCAN_BUFFER_MB` — getattrlistbulk buffer megabytes (default 4)
enum BulkScan {
    struct Result: Sendable {
        var tree: FileTree
        var itemCount: Int
        var notDownloadedCount: Int
        var peakResidentBytesDuringWalk: UInt64
    }

    static func walk(root: URL, progress: (@Sendable (Int) -> Void)?) -> Result {
        var tree = FileTree()
        // Home scans land near 1.7–2M nodes; reserve once so appends stay O(1).
        tree.reserveNodeCapacity(1_000_000, uniqueNames: 400_000)
        let rootID = tree.addNode(
            name: root.lastPathComponent,
            parent: -1,
            isDirectory: true,
            logicalSize: 0,
            allocatedSize: 0,
            modifiedDaysSinceEpoch: 0
        )
        let state = State(tree: tree, progress: progress)
        state.enqueue(pathUTF8: nulTerminatedUTF8(root.path), nodeID: rootID)
        state.startPublisher()

        let workers = configuredWorkers()
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

    private static func configuredWorkers() -> Int {
        let cpu = ProcessInfo.processInfo.activeProcessorCount
        let fallback = max(1, min(cpu, 8))
        guard let raw = ProcessInfo.processInfo.environment["DISKMAP_SCAN_WORKERS"],
              let value = Int(raw), value > 0 else { return fallback }
        return min(value, 32)
    }

    private static func configuredBufferBytes() -> Int {
        // 4 MB won the warm A/B median vs 1 MB on a ~1.8M-item home scan
        // (see docs/PERF.md). Override with DISKMAP_SCAN_BUFFER_MB.
        let fallback = 4 * 1024 * 1024
        guard let raw = ProcessInfo.processInfo.environment["DISKMAP_SCAN_BUFFER_MB"],
              let mb = Int(raw), mb > 0 else { return fallback }
        return min(mb, 16) * 1024 * 1024
    }

    private static func worker(_ state: State) {
        var buffer = [UInt8](repeating: 0, count: configuredBufferBytes())
        while let job = state.nextJob() {
            scan(job, buffer: &buffer, state: state)
        }
    }

    private static func scan(_ job: Job, buffer: inout [UInt8], state: State) {
        let fd = job.pathUTF8.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return -1 }
            return Darwin.open(base, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
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
        state.submit(Batch(parentPathUTF8: job.pathUTF8, parent: job.nodeID, names: names, entries: entries))
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

    /// Parent path is NUL-terminated. Name bytes are not. Result is NUL-terminated.
    private static func joinPathUTF8(parentPathUTF8: [UInt8], name: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        let parentCount = max(0, parentPathUTF8.count - 1) // drop trailing NUL
        let parentIsRoot = parentCount == 1 && parentPathUTF8.first == 0x2F
        var out = [UInt8]()
        out.reserveCapacity(parentCount + 1 + name.count + 1)
        if parentIsRoot {
            out.append(0x2F)
        } else {
            out.append(contentsOf: parentPathUTF8.prefix(parentCount))
            out.append(0x2F)
        }
        out.append(contentsOf: name)
        out.append(0)
        return out
    }

    private static func nulTerminatedUTF8(_ path: String) -> [UInt8] {
        var bytes = Array(path.utf8)
        bytes.append(0)
        return bytes
    }

    private final class State: @unchecked Sendable {
        private let condition = NSCondition()
        private var jobs: [Job] = []
        private var batches: [Batch] = []
        private var inflight = 0
        private var finished = false
        private var publisherExited = false
        private var tree: FileTree
        private var itemCount = 0
        private var notDownloadedCount = 0
        private var peak: UInt64
        private let progress: (@Sendable (Int) -> Void)?
        private var lastReported = 0

        init(tree: FileTree, progress: (@Sendable (Int) -> Void)?) {
            self.tree = tree
            self.progress = progress
            self.peak = ProcessMemory.current()?.residentBytes ?? 0
        }

        func startPublisher() {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                self.publishLoop()
            }
        }

        func enqueue(pathUTF8: [UInt8], nodeID: Int32) {
            condition.lock()
            jobs.append(Job(pathUTF8: pathUTF8, nodeID: nodeID))
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
            signalWorkLocked()
            condition.unlock()
        }

        func submit(_ batch: Batch) {
            condition.lock()
            batches.append(batch)
            inflight -= 1
            signalWorkLocked()
            condition.unlock()
        }

        private func publishLoop() {
            while true {
                let batch: Batch?
                condition.lock()
                while batches.isEmpty && !finished {
                    condition.wait()
                }
                if batches.isEmpty && finished {
                    publisherExited = true
                    condition.broadcast()
                    condition.unlock()
                    return
                }
                batch = batches.isEmpty ? nil : batches.removeLast()
                condition.unlock()
                if let batch {
                    publish(batch)
                }
            }
        }

        private func publish(_ batch: Batch) {
            var children: [Job] = []
            children.reserveCapacity(32)
            var notDownloadedDelta = 0

            batch.names.withUnsafeBufferPointer { raw in
                guard let base = raw.baseAddress else { return }
                for entry in batch.entries where entry.include {
                    let bytes = UnsafeBufferPointer(start: base + entry.nameStart, count: entry.nameCount)
                    var flags: UInt8 = 0
                    if entry.notDownloaded {
                        flags |= NodeFlags.notDownloaded
                        notDownloadedDelta += 1
                    }
                    let id = tree.addNode(
                        utf8: bytes,
                        parent: batch.parent,
                        isDirectory: entry.isDirectory,
                        logicalSize: entry.logical,
                        allocatedSize: entry.allocated,
                        modifiedDaysSinceEpoch: entry.day,
                        flags: flags
                    )
                    if entry.descend {
                        children.append(Job(
                            pathUTF8: BulkScan.joinPathUTF8(
                                parentPathUTF8: batch.parentPathUTF8,
                                name: bytes
                            ),
                            nodeID: id
                        ))
                    }
                }
            }

            var report: Int?
            condition.lock()
            itemCount += batch.entries.count
            notDownloadedCount += notDownloadedDelta
            if itemCount - lastReported >= 4000 {
                lastReported = itemCount
                report = itemCount
            }
            if !children.isEmpty {
                jobs.append(contentsOf: children)
            }
            signalWorkLocked()
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

        private func signalWorkLocked() {
            if inflight == 0 && jobs.isEmpty && batches.isEmpty {
                finished = true
            }
            condition.broadcast()
        }

        func finish() -> Result {
            condition.lock()
            while !publisherExited {
                condition.wait()
            }
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
    /// NUL-terminated absolute path bytes for `open(2)`.
    var pathUTF8: [UInt8]
    var nodeID: Int32
}

private struct Batch {
    var parentPathUTF8: [UInt8]
    var parent: Int32
    var names: [UInt8]
    var entries: [Entry]
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
