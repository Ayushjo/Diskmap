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
        /// Files whose ATTR_FILE_LINKCOUNT was > 1 — candidates for the
        /// hard-link rollup correction (TASK-037).
        var hardLinkCount: Int
        /// Directories recorded but not descended because they sit on another
        /// volume. Non-zero means the totals deliberately exclude a mount.
        var crossMountSkipCount: Int
        /// Directories that could not be opened because of permissions
        /// (EACCES/EPERM): typically TCC-protected without Full Disk Access.
        var deniedDirectoryIDs: [Int32]
        /// Directories deleted between being listed and being opened.
        var vanishedDirectoryCount: Int
        /// Any other open(2) failure.
        var otherUnopenedDirectoryCount: Int
        var peakResidentBytesDuringWalk: UInt64
    }

    static func walk(
        root: URL,
        crossMounts: Bool = false,
        progress: (@Sendable (Int) -> Void)?,
        live: (@Sendable (ScanProgress) -> Void)? = nil
    ) -> Result {
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
        state.live = live
        state.rootNodeID = rootID
        state.scanRootPath = root.path
        state.crossMounts = crossMounts
        // Device id of the scan root. Children on a different device are
        // recorded but not descended, so a "/" scan does not silently absorb
        // every mounted volume — and so ATTR_CMN_FILEID stays unique per scan.
        var rootStat = stat()
        if lstat(root.path, &rootStat) == 0 {
            state.scanRootDevID = Int32(rootStat.st_dev)
            state.hasRootDevID = true
        }
        // shouldSkipDescend only ever returns true when the root is "/" or
        // under /System/Volumes. Evaluate that once here instead of building
        // and discarding a path String for every directory in publish().
        state.mayHitFirmlinkTwins = CanonicalPath.mayContainFirmlinkTwins(scanRootPath: root.path)
        state.enqueue(pathUTF8: nulTerminatedUTF8(root.path), nodeID: rootID, topLevel: -1)
        state.startPublisher()

        let workers = configuredWorkers()
        let group = DispatchGroup()
        for index in 0..<workers {
            group.enter()
            startScanThread(name: "DiskMap.scan.worker.\(index)") {
                worker(state)
                group.leave()
            }
        }
        group.wait()
        return state.finish()
    }

    /// Workers and the publisher spend most of their lives blocked on
    /// `condition` waiting for each other, so they run on dedicated threads,
    /// never on GCD's global queues or Swift's cooperative pool. Both of those
    /// pools cap how many threads may run at a QoS; once every slot is held by
    /// a thread blocked in this walk (easily reached when several scans run at
    /// once), the workers that would unblock them can never be scheduled and
    /// every scan waits forever. Observed 2026-09-28: 11 scans stuck in
    /// `group.wait()` with zero worker and zero publisher threads alive. A
    /// handful of threads per multi-second scan costs nothing measurable.
    static func startScanThread(name: String, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.start()
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
        // errno is read inside the closure, immediately after open(2), before
        // anything else can overwrite it.
        let (fd, openErrno) = job.pathUTF8.withUnsafeBytes { raw -> (Int32, Int32) in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return (-1, EINVAL) }
            let fd = Darwin.open(base, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            return (fd, fd < 0 ? errno : 0)
        }
        guard fd >= 0 else {
            state.noteUnopenedDirectory(errno: openErrno, nodeID: job.nodeID)
            return
        }
        defer { close(fd) }

        var list = attrlist()
        memset(&list, 0, MemoryLayout<attrlist>.size)
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrReturned | attrName | attrDevID | attrError | attrObjType
            | attrCrTime | attrModTime | attrFlags | attrFileID
        // ATTR_DIR_LINKCOUNT is requested purely to keep the dir and file
        // sections the same width (4 + 8 + 8 at offset 88) so `parse` can keep
        // one offset pair. Its VALUE is not trusted — on APFS it reads 1 even
        // for a directory with children (docs/perf-results/attr-probe.txt).
        list.dirattr = attrDirLinkCount | attrDirAlloc | attrDirData
        list.fileattr = attrFileLinkCount | attrFileTotal | attrFileAlloc

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
        state.submit(Batch(
            parentPathUTF8: job.pathUTF8, parent: job.nodeID, topLevel: job.topLevel,
            names: names, entries: entries
        ))
    }

    /// Offsets MEASURED by the `AttrProbe` target, not hand-derived — raw
    /// evidence in `docs/perf-results/attr-probe.txt` (2026-09-25, TASK-036).
    /// Adding ATTR_CMN_DEVID (+4 at 36), ATTR_CMN_FILEID (+8 at 80) and
    /// LINKCOUNT (+4 at 88) moved every later field and took `fixedPrefix`
    /// from 92 to 108. Re-run `swift run AttrProbe` after ANY mask change.
    /// Name is still at `nameRef + dataOffset`, which adapts on its own.
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
            let devID = load(Int32.self, buffer, offset + 36)
            let objType = load(UInt32.self, buffer, offset + 40)
            // ATTR_CMN_CRTIME then ATTR_CMN_MODTIME (each timespec = 16 bytes).
            let created = load(Int64.self, buffer, offset + 44)
            let modified = load(Int64.self, buffer, offset + 60)
            let flags = load(UInt32.self, buffer, offset + 76)
            let fileID = load(UInt64.self, buffer, offset + 80)
            let linkCount = load(UInt32.self, buffer, offset + 88)
            let firstSize = load(Int64.self, buffer, offset + 92)
            let secondSize = load(Int64.self, buffer, offset + 100)
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
                day: dayFromEpochSeconds(modified),
                createdDay: dayFromEpochSeconds(created),
                notDownloaded: dataless,
                descend: isDirectory && !isLink && !dataless,
                fileID: fileID,
                devID: devID,
                // Directories are never hard links on APFS, and
                // ATTR_DIR_LINKCOUNT is not a real link count anyway.
                isHardLink: !isDirectory && linkCount > 1
            ))
        }
    }

    private static func dayFromEpochSeconds(_ seconds: Int64) -> Int32 {
        guard seconds > 0 else { return 0 }
        let days = seconds / 86400
        guard days <= Int64(Int32.max) else { return 0 }
        return Int32(days)
    }

    private static func load<T>(_ type: T.Type, _ buffer: [UInt8], _ offset: Int) -> T {
        buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: type) }
    }

    static func pathString(fromNULTerminated utf8: [UInt8]) -> String {
        let count = max(0, utf8.count - 1)
        return String(decoding: utf8.prefix(count), as: UTF8.self)
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

    fileprivate static func nulTerminatedUTF8(_ path: String) -> [UInt8] {
        var bytes = Array(path.utf8)
        bytes.append(0)
        return bytes
    }

    private final class State: @unchecked Sendable {
        var scanRootPath: String = "/"
        var live: (@Sendable (ScanProgress) -> Void)?
        var rootNodeID: Int32 = 0
        // Publisher-thread-only live counters (TASK-044).
        private var liveBytesFound: Int64 = 0
        private var liveTopLevelBytes: [Int32: Int64] = [:]
        private var lastLiveReport: ContinuousClock.Instant?
        private let liveStarted = ContinuousClock.now
        var scanRootDevID: Int32 = 0
        var hasRootDevID = false
        var crossMounts = false
        /// False for the overwhelmingly common home scan, which lets
        /// `publish` skip building a path String per directory entirely.
        var mayHitFirmlinkTwins = false
        private let condition = NSCondition()
        private var jobs: [Job] = []
        private var batches: [Batch] = []
        private var inflight = 0
        /// Batches the publisher has taken off the queue but not finished
        /// turning into nodes and child jobs. Without this the walk can
        /// declare itself finished while a subtree is still in the
        /// publisher's hands — see `signalWorkLocked`.
        private var publishing = 0
        private var finished = false
        private var publisherExited = false
        private var tree: FileTree
        private var itemCount = 0
        private var notDownloadedCount = 0
        private var hardLinkCount = 0
        private var crossMountSkipCount = 0
        private var deniedDirectoryIDs: [Int32] = []
        private var vanishedDirectoryCount = 0
        private var otherUnopenedDirectoryCount = 0
        private var peak: UInt64
        private let progress: (@Sendable (Int) -> Void)?
        private var lastReported = 0

        init(tree: FileTree, progress: (@Sendable (Int) -> Void)?) {
            self.tree = tree
            self.progress = progress
            self.peak = ProcessMemory.current()?.residentBytes ?? 0
        }

        func startPublisher() {
            BulkScan.startScanThread(name: "DiskMap.scan.publisher") { [self] in
                self.publishLoop()
            }
        }

        func enqueue(pathUTF8: [UInt8], nodeID: Int32, topLevel: Int32) {
            condition.lock()
            jobs.append(Job(pathUTF8: pathUTF8, nodeID: nodeID, topLevel: topLevel))
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

        /// A directory the walk could not open. It stays in the tree (so it is
        /// navigable) with no children — so every total above it is SHORT by
        /// whatever it holds. Before TASK-039 this was silent. Only
        /// permission failures are reported to the user: `ENOENT` is a folder
        /// deleted mid-scan (its bytes really are gone), and anything else is
        /// counted separately. Records node ids, not paths, to keep the walk
        /// allocation-free; paths are resolved later from the tree.
        func noteUnopenedDirectory(errno code: Int32, nodeID: Int32) {
            condition.lock()
            switch code {
            case EACCES, EPERM:
                deniedDirectoryIDs.append(nodeID)
            case ENOENT:
                vanishedDirectoryCount += 1
            default:
                otherUnopenedDirectoryCount += 1
            }
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
                if batches.isEmpty {
                    batch = nil
                } else {
                    batch = batches.removeLast()
                    // Claim it BEFORE unlocking: between here and the
                    // re-lock at the end of publish() the queues look empty
                    // even though this batch's children are still coming.
                    publishing += 1
                }
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
            var hardLinkDelta = 0
            var crossMountSkipDelta = 0

            batch.names.withUnsafeBufferPointer { raw in
                guard let base = raw.baseAddress else { return }
                for entry in batch.entries where entry.include {
                    let bytes = UnsafeBufferPointer(start: base + entry.nameStart, count: entry.nameCount)
                    var flags: UInt8 = 0
                    if entry.notDownloaded {
                        flags |= NodeFlags.notDownloaded
                        notDownloadedDelta += 1
                    }
                    if entry.isHardLink {
                        flags |= NodeFlags.hardLink
                        hardLinkDelta += 1
                    }
                    let id = tree.addNode(
                        utf8: bytes,
                        parent: batch.parent,
                        isDirectory: entry.isDirectory,
                        logicalSize: entry.logical,
                        allocatedSize: entry.allocated,
                        modifiedDaysSinceEpoch: entry.day,
                        createdDaysSinceEpoch: entry.createdDay,
                        flags: flags,
                        fileID: entry.fileID
                    )
                    // Live view (TASK-044): charge files to their top-level
                    // folder. The root's children start their own bucket.
                    let top = batch.parent == self.rootNodeID ? id : batch.topLevel
                    if !entry.isDirectory {
                        liveBytesFound += entry.allocated
                        if top >= 0 { liveTopLevelBytes[top, default: 0] += entry.allocated }
                    }
                    if entry.descend {
                        // Record the directory node for navigation, but do not
                        // walk it when it lives on another volume — its bytes
                        // are not part of this scan root's storage.
                        if !self.crossMounts, self.hasRootDevID, entry.devID != self.scanRootDevID {
                            crossMountSkipDelta += 1
                            continue
                        }
                        let childPathUTF8 = BulkScan.joinPathUTF8(
                            parentPathUTF8: batch.parentPathUTF8,
                            name: bytes
                        )
                        if self.mayHitFirmlinkTwins {
                            // Only a "/" (or /System/Volumes) scan can reach the
                            // Data-volume twin of a firmlink already reachable via
                            // /Users, /Applications, etc. Building this String for
                            // every directory of a home scan was pure waste.
                            let childPath = BulkScan.pathString(fromNULTerminated: childPathUTF8)
                            if CanonicalPath.shouldSkipDescend(
                                absolutePath: childPath,
                                scanRootPath: self.scanRootPath
                            ) {
                                continue
                            }
                        }
                        children.append(Job(pathUTF8: childPathUTF8, nodeID: id, topLevel: top))
                    }
                }
            }

            var report: Int?
            condition.lock()
            itemCount += batch.entries.count
            notDownloadedCount += notDownloadedDelta
            hardLinkCount += hardLinkDelta
            crossMountSkipCount += crossMountSkipDelta
            if itemCount - lastReported >= 4000 {
                lastReported = itemCount
                report = itemCount
            }
            if !children.isEmpty {
                jobs.append(contentsOf: children)
            }
            publishing -= 1
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
            reportLiveIfDue(lastFolderUTF8: batch.parentPathUTF8)
        }

        /// A few times a second, hand the UI what the walk has found so far.
        /// Everything read here is owned by the publisher thread, so no lock:
        /// only `publish` mutates the tree and the live counters.
        private func reportLiveIfDue(lastFolderUTF8: [UInt8], force: Bool = false) {
            guard let live else { return }
            let now = ContinuousClock.now
            guard force || (lastLiveReport.map({ $0.duration(to: now) >= .milliseconds(250) }) ?? true) else { return }
            lastLiveReport = now
            let folders = liveTopLevelBytes
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(12)
                .map { ScanProgress.Folder(name: tree.name(of: $0.key), bytes: $0.value) }
            let elapsed = liveStarted.duration(to: now).components
            live(ScanProgress(
                itemCount: itemCountSnapshot(),
                bytesFound: liveBytesFound,
                elapsedSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                currentFolder: BulkScan.pathString(fromNULTerminated: lastFolderUTF8),
                topFolders: Array(folders)
            ))
        }

        private func itemCountSnapshot() -> Int {
            condition.lock()
            defer { condition.unlock() }
            return itemCount
        }

        /// The walk is done only when no worker is scanning, no batch is
        /// queued, AND the publisher is not mid-flight. Omitting `publishing`
        /// let this sequence silently drop a subtree: the publisher takes the
        /// batch for a directory and unlocks; a worker then fails to open a
        /// chmod-000 sibling and calls `noteUnopenedDirectory`, which drops
        /// `inflight` to 0 while `jobs` and `batches` are momentarily empty;
        /// `finished` is set, every worker exits, and the child jobs the
        /// publisher appends a moment later are never scanned. The tree came
        /// back missing an entire directory with no error anywhere.
        private func signalWorkLocked() {
            if inflight == 0 && publishing == 0 && jobs.isEmpty && batches.isEmpty {
                finished = true
            }
            condition.broadcast()
        }

        func finish() -> Result {
            condition.lock()
            while !publisherExited {
                condition.wait()
            }
            condition.unlock()
            // The publisher has exited, so the live counters and tree are
            // quiescent: send one final, complete report.
            reportLiveIfDue(lastFolderUTF8: BulkScan.nulTerminatedUTF8(scanRootPath), force: true)
            condition.lock()
            let result = Result(
                tree: tree,
                itemCount: itemCount,
                notDownloadedCount: notDownloadedCount,
                hardLinkCount: hardLinkCount,
                crossMountSkipCount: crossMountSkipCount,
                deniedDirectoryIDs: deniedDirectoryIDs,
                vanishedDirectoryCount: vanishedDirectoryCount,
                otherUnopenedDirectoryCount: otherUnopenedDirectoryCount,
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
    /// The root's child this directory lives under (-1 for the root itself),
    /// so the live view can attribute bytes in O(1).
    var topLevel: Int32
}

private struct Batch {
    var parentPathUTF8: [UInt8]
    var parent: Int32
    var topLevel: Int32
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
    var createdDay: Int32
    var notDownloaded: Bool
    var descend: Bool
    /// ATTR_CMN_FILEID. Unique per volume, which is why the walk refuses to
    /// cross mount points unless asked (see `State.crossMounts`).
    var fileID: UInt64
    /// ATTR_CMN_DEVID, used only to decide descent. Not stored per node.
    var devID: Int32
    /// ATTR_FILE_LINKCOUNT > 1. Files only.
    var isHardLink: Bool

    static let skipped = Entry(
        nameStart: 0,
        nameCount: 0,
        include: false,
        isDirectory: false,
        logical: 0,
        allocated: 0,
        day: 0,
        createdDay: 0,
        notDownloaded: false,
        descend: false,
        fileID: 0,
        devID: 0,
        isHardLink: false
    )
}

private let attrReturned: UInt32 = 0x80000000
private let attrName: UInt32 = 0x00000001
private let attrDevID: UInt32 = 0x00000002
private let attrObjType: UInt32 = 0x00000008
private let attrCrTime: UInt32 = 0x00000200
private let attrModTime: UInt32 = 0x00000400
private let attrFlags: UInt32 = 0x00040000
private let attrFileID: UInt32 = 0x02000000
private let attrError: UInt32 = 0x20000000
private let attrDirLinkCount: UInt32 = 0x00000001
private let attrDirAlloc: UInt32 = 0x00000008
private let attrDirData: UInt32 = 0x00000020
private let attrFileLinkCount: UInt32 = 0x00000001
private let attrFileTotal: UInt32 = 0x00000002
private let attrFileAlloc: UInt32 = 0x00000004
private let options = UInt64(FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS)
private let sfDataless: UInt32 = 0x40000000
private let vdir: UInt32 = 2
private let vlunk: UInt32 = 5
private let fixedPrefix = 108
