import Foundation

/// Walks a directory tree off the main thread and builds a `FileTree`.
///
/// The walk is `getattrlistbulk`, not `FileManager.enumerator`. The
/// enumerator built a `URL` and a resource-value object per file; on a
/// home folder that was about 373 s. Bulk attributes plus a handful of
/// worker threads is the macOS API for this.
/// What a scan has found so far, a few times a second (TASK-044). Byte
/// figures are running sums of on-disk size and are approximate until the
/// walk ends (hard links are de-duplicated only in the final rollup).
public struct ScanProgress: Sendable, Equatable {
    public struct Folder: Sendable, Equatable {
        public var name: String
        public var bytes: Int64
    }
    public var itemCount: Int
    public var bytesFound: Int64
    public var elapsedSeconds: Double
    public var currentFolder: String
    /// Largest folders directly inside the scan root, largest first (≤ 12).
    public var topFolders: [Folder]

    public var itemsPerSecond: Double {
        elapsedSeconds > 0 ? Double(itemCount) / elapsedSeconds : 0
    }
}

public actor ScanEngine {

    public struct Result: Sendable {
        public var tree: FileTree
        public var itemCount: Int
        public var elapsedSeconds: Double
        /// Max `resident_size` sampled while the walk was still running
        /// (enumerator and per-item `resourceValues` still alive). Not the
        /// process-lifetime `resident_size_max`.
        public var peakResidentBytesDuringWalk: UInt64
        /// `resident_size` after the walk function has returned, so the
        /// enumerator is released and the tree is still retained.
        public var residentBytesAfterEnumeratorRelease: UInt64?
        public var notDownloadedCount: Int
        /// Files with ATTR_FILE_LINKCOUNT > 1. These are the only nodes the
        /// hard-link rollup correction has to consider (TASK-037).
        public var hardLinkCount: Int
        /// Directories recorded but not walked because they live on another
        /// volume. Non-zero means these totals deliberately exclude a mount.
        public var crossMountSkipCount: Int
        /// Directories the walk could not open for lack of permission. They
        /// are in the tree with no children, so every total above them is
        /// short. Usually TCC-protected folders without Full Disk Access.
        public var deniedDirectoryIDs: [Int32]
        /// Deleted between being listed and being opened — not an error.
        public var vanishedDirectoryCount: Int
        public var otherUnopenedDirectoryCount: Int
        /// FSEvents id read just before the walk began: the point an
        /// incremental update replays from (TASK-061).
        public var eventIDAtStart: UInt64 = 0
    }

    /// What to store for one enumerated item. Split out so the iCloud
    /// decision can be unit-tested without an evicted file on disk.
    public struct ItemDecision: Sendable, Equatable {
        public var include: Bool
        public var logicalSize: Int64
        public var allocatedSize: Int64
        public var notDownloaded: Bool
        public var skipDescendants: Bool
    }

    public init() {}

    /// - Parameter crossMounts: when false (the default) the walk records a
    ///   directory that sits on another volume but does not descend into it,
    ///   so a "/" scan does not silently absorb every mounted disk. Pass true
    ///   only when the caller genuinely wants every reachable filesystem.
    /// - Parameter sharing: read APFS clone facts so clone families count
    ///   once (TASK-077). Off by default: it lengthens the walk.
    public func scan(
        root: URL,
        crossMounts: Bool = false,
        sharing: SharingMode = .off,
        progress: (@Sendable (Int) -> Void)? = nil,
        live: (@Sendable (ScanProgress) -> Void)? = nil
    ) async -> Result {
        let started = ContinuousClock.now
        let eventIDAtStart = FSEventHistory.currentEventID()
        // `walk` owns the enumerator. Measuring after it returns is the
        // steady state: tree retained, enumerator and per-item
        // resourceValues released. The during-walk peak is sampled only
        // inside `walk` and is not updated here.
        // `walk` blocks until the scan is done. It must not do that on a
        // Swift-concurrency thread: that pool assumes its threads never block,
        // and enough parallel scans parked there starved the walk's own
        // workers into a permanent hang. Run it on a dedicated thread and
        // resume when it finishes.
        let walked = await withCheckedContinuation { (continuation: CheckedContinuation<BulkScan.Result, Never>) in
            BulkScan.startScanThread(name: "DiskMap.scan.coordinator") {
                continuation.resume(returning: BulkScan.walk(
                    root: root, crossMounts: crossMounts, sharing: sharing, progress: progress, live: live
                ))
            }
        }
        var tree = walked.tree
        tree.compact()
        let afterRelease = ProcessMemory.current()
        let elapsed = started.duration(to: .now)
        let result = Result(
            tree: tree,
            itemCount: walked.itemCount,
            elapsedSeconds: seconds(elapsed),
            peakResidentBytesDuringWalk: walked.peakResidentBytesDuringWalk,
            residentBytesAfterEnumeratorRelease: afterRelease?.residentBytes,
            notDownloadedCount: walked.notDownloadedCount,
            hardLinkCount: walked.hardLinkCount,
            crossMountSkipCount: walked.crossMountSkipCount,
            deniedDirectoryIDs: walked.deniedDirectoryIDs,
            vanishedDirectoryCount: walked.vanishedDirectoryCount,
            otherUnopenedDirectoryCount: walked.otherUnopenedDirectoryCount,
            eventIDAtStart: eventIDAtStart
        )
        logSummary(result)
        return result
    }

    /// Symlinks are skipped (the enumerator does not follow them, and
    /// recording the link would double-count whatever it points at).
    /// An evicted iCloud item is recorded, not opened: size keys do not
    /// start a download (see `scan`), so allocated size is the local
    /// footprint (0 when fully evicted) and logical size is the cloud
    /// size. Descendants of a not-downloaded directory are skipped so
    /// listing them can't materialize the folder.
    public static func decide(_ values: URLResourceValues) -> ItemDecision {
        decide(
            isDirectory: values.isDirectory ?? false,
            isSymbolicLink: values.isSymbolicLink ?? false,
            logicalSize: values.fileSize.map(Int64.init),
            allocatedSize: values.totalFileAllocatedSize.map(Int64.init),
            isUbiquitous: values.isUbiquitousItem ?? false,
            downloadingStatusNotDownloaded: values.ubiquitousItemDownloadingStatus == .notDownloaded
        )
    }

    public static func decide(
        isDirectory: Bool,
        isSymbolicLink: Bool,
        logicalSize: Int64?,
        allocatedSize: Int64?,
        isUbiquitous: Bool,
        downloadingStatusNotDownloaded: Bool
    ) -> ItemDecision {
        if isSymbolicLink {
            return ItemDecision(
                include: false,
                logicalSize: 0,
                allocatedSize: 0,
                notDownloaded: false,
                skipDescendants: true
            )
        }

        let notDownloaded = isUbiquitous && downloadingStatusNotDownloaded
        return ItemDecision(
            include: true,
            logicalSize: logicalSize ?? 0,
            allocatedSize: allocatedSize ?? logicalSize ?? 0,
            notDownloaded: notDownloaded,
            skipDescendants: notDownloaded && isDirectory
        )
    }

    private func logSummary(_ result: Result) {
        let after = result.residentBytesAfterEnumeratorRelease.map(String.init) ?? "unavailable"
        let line = "DiskMap scan: items=\(result.itemCount) elapsed=\(String(format: "%.3f", result.elapsedSeconds))s rss_during_walk_peak=\(result.peakResidentBytesDuringWalk) rss_after_enumerator_release=\(after) not_downloaded=\(result.notDownloadedCount) hard_links=\(result.hardLinkCount) cross_mount_skips=\(result.crossMountSkipCount) denied_dirs=\(result.deniedDirectoryIDs.count) sharing_rows=\(result.tree.sharing.count) sharing_read=\(result.tree.hasSharingInfo)"
        // Diagnostics go to stderr: stdout belongs to whoever embeds the
        // engine (the diskmap CLI's --json output must stay parseable).
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
