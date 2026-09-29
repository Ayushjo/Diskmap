import CoreServices
import Foundation

/// Reads the FSEvents history for one folder (TASK-061). Replay only: no
/// stream is left running, and nothing here watches the disk in the
/// background.
///
/// FSEvents is a hint, never a guarantee — its own docs say history can be
/// dropped, coalesced or reset. Every answer it cannot vouch for comes back
/// as a reason to walk the disk in full.
public enum FSEventHistory {

    /// The system-wide id of the most recent event. Capture it *before* a
    /// walk starts: anything that changes during the walk is then replayed
    /// next time (re-listing a folder twice is harmless; missing one is not).
    public static func currentEventID() -> UInt64 {
        FSEventsGetCurrentEventId()
    }

    /// Identifies the event database of the volume holding `path`. When it
    /// changes, old event ids mean nothing (the database was reset).
    public static func volumeUUID(forPath path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0, let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    public struct Changes: Sendable, Equatable {
        /// Folders whose direct contents changed.
        public var directories: Set<String> = []
        /// Folders FSEvents could not describe in detail: walk all of them.
        public var subtrees: Set<String> = []
        /// Set when nothing short of a full walk is trustworthy.
        public var fullRescanReason: String?
        public var eventCount = 0
    }

    private final class Collector: @unchecked Sendable {
        var changes = Changes()
        let done = DispatchSemaphore(value: 0)
        var finished = false
    }

    /// Events under `realPath` since `eventID`. `realPath` must be the
    /// symlink-free path (FSEvents reports real paths). Nil on timeout.
    static func changes(since eventID: UInt64, realPath: String, timeout: TimeInterval = 20) -> Changes? {
        let collector = Collector()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(collector).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let collector = Unmanaged<Collector>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            for index in 0..<min(count, list.count) {
                let flag = Int(flags[index])
                func has(_ bit: Int) -> Bool { flag & bit != 0 }
                if has(kFSEventStreamEventFlagHistoryDone) {
                    if !collector.finished {
                        collector.finished = true
                        collector.done.signal()
                    }
                    continue
                }
                collector.changes.eventCount += 1
                let path = FSEventHistory.normalized(list[index])
                if has(kFSEventStreamEventFlagEventIdsWrapped) {
                    collector.changes.fullRescanReason = "the event history wrapped around"
                } else if has(kFSEventStreamEventFlagRootChanged) {
                    collector.changes.fullRescanReason = "the scanned folder was moved or replaced"
                } else if has(kFSEventStreamEventFlagMustScanSubDirs) || has(kFSEventStreamEventFlagUserDropped)
                            || has(kFSEventStreamEventFlagKernelDropped) || has(kFSEventStreamEventFlagMount)
                            || has(kFSEventStreamEventFlagUnmount) {
                    collector.changes.subtrees.insert(path)
                } else {
                    collector.changes.directories.insert(path)
                }
            }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [realPath] as CFArray,
                                               FSEventStreamEventId(eventID), 0, flags) else { return nil }
        let queue = DispatchQueue(label: "DiskMap.FSEventHistory")
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        let result = collector.done.wait(timeout: .now() + timeout)
        // Deliver anything fseventsd holds for this stream. It does not help
        // with changes the kernel has not handed over yet; that is what
        // `waitForPendingEvents` is for.
        if result == .success { FSEventStreamFlushSync(stream) }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        // After invalidation no callback can run, so reading is safe.
        return queue.sync { result == .success ? collector.changes : nil }
    }

    private final class BarrierWatch: @unchecked Sendable {
        let target: String
        let seen = DispatchSemaphore(value: 0)
        var signalled = false
        init(target: String) { self.target = target }
    }

    /// Changes get their event id ~0.1 s after the syscall (measured), so a
    /// replay started right after a change can miss it. The kernel hands
    /// events over in order: once an event for a marker written *now* has
    /// arrived, every earlier change has an id and is in the history.
    /// `marker` must be a file the caller owns; it is overwritten in place.
    @discardableResult
    static func waitForPendingEvents(marker: URL, timeout: TimeInterval = 2) -> Bool {
        let directory = marker.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let realDirectory = realPath(directory.path)
        let watch = BarrierWatch(target: normalized(realDirectory + "/" + marker.lastPathComponent))
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(watch).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watch = Unmanaged<BarrierWatch>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            for index in 0..<min(count, list.count) where FSEventHistory.normalized(list[index]) == watch.target {
                if !watch.signalled {
                    watch.signalled = true
                    watch.seen.signal()
                }
            }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [realDirectory] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0, flags) else { return false }
        let queue = DispatchQueue(label: "DiskMap.FSEventHistory.barrier")
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        let stamp = Data("\(Date().timeIntervalSince1970)\n".utf8)
        let wrote = (try? stamp.write(to: marker)) != nil
        let result = wrote ? watch.seen.wait(timeout: .now() + timeout) : .timedOut
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        return result == .success
    }

    /// No trailing slash; the Data-volume spelling of a firmlinked path
    /// ("/System/Volumes/Data/Users/…") mapped back to "/Users/…".
    static func normalized(_ path: String) -> String {
        var result = path
        let data = "/System/Volumes/Data"
        if result.hasPrefix(data + "/") { result = String(result.dropFirst(data.count)) }
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }

    /// realpath(3): FSEvents reports /private/var/…, not /var/….
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
