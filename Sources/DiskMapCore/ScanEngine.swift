import Foundation

/// Walks a directory tree off the main thread and builds a `FileTree`.
///
/// The walk is `getattrlistbulk`, not `FileManager.enumerator`. The
/// enumerator built a `URL` and a resource-value object per file; on a
/// home folder that was about 373 s. Bulk attributes plus a handful of
/// worker threads is the macOS API for this.
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

    public func scan(root: URL, progress: (@Sendable (Int) -> Void)? = nil) async -> Result {
        let started = ContinuousClock.now
        // `walk` owns the enumerator. Measuring after it returns is the
        // steady state: tree retained, enumerator and per-item
        // resourceValues released. The during-walk peak is sampled only
        // inside `walk` and is not updated here.
        let walked = await Task.detached(priority: .userInitiated) {
            BulkScan.walk(root: root, progress: progress)
        }.value
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
            notDownloadedCount: walked.notDownloadedCount
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
        let line = "DiskMap scan: items=\(result.itemCount) elapsed=\(String(format: "%.3f", result.elapsedSeconds))s rss_during_walk_peak=\(result.peakResidentBytesDuringWalk) rss_after_enumerator_release=\(after) not_downloaded=\(result.notDownloadedCount)"
        print(line)
        fflush(stdout)
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
