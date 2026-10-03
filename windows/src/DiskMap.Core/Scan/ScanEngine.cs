using DiskMap.Core.Native;

namespace DiskMap.Core;

/// <summary>
/// Walks a directory tree off the main thread and builds a <see cref="FileTree"/>.
///
/// Primary path is the NTFS MFT (WizTree-style: read $MFT, parse FILE
/// records, rebuild the subtree). Fallback is a FindFirstFileExW work-queue —
/// needed regardless for non-NTFS volumes, non-elevated runs, and network
/// drives. Both produce the same WalkResult.
/// </summary>
public sealed class ScanEngine
{
    public sealed class Result
    {
        public required FileTree Tree { get; init; }
        public required int ItemCount { get; init; }
        public required double ElapsedSeconds { get; init; }
        /// <summary>Max working-set sampled while the walk was still running.</summary>
        public ulong PeakResidentBytesDuringWalk { get; init; }
        /// <summary>Working set after the walk returned, tree retained.</summary>
        public ulong? ResidentBytesAfterWalk { get; init; }
        public int NotDownloadedCount { get; init; }
        /// <summary>"mft" or "win32" — which backend produced this scan.</summary>
        public required string Backend { get; init; }
    }

    /// <summary>
    /// What to store for one enumerated item. Split out so the cloud-
    /// placeholder decision can be unit-tested without a fixture on disk.
    /// </summary>
    public readonly record struct ItemDecision(
        bool Include,
        long LogicalSize,
        long AllocatedSize,
        bool NotDownloaded,
        bool SkipDescendants);

    public async Task<Result> ScanAsync(string root, IProgress<int>? progress = null)
    {
        var started = System.Diagnostics.Stopwatch.StartNew();
        var walked = await Task.Run(() => Walk(root, progress));
        walked.Tree.Compact();
        var afterRelease = ProcessMemory.Current();
        started.Stop();
        var result = new Result
        {
            Tree = walked.Tree,
            ItemCount = walked.ItemCount,
            ElapsedSeconds = started.Elapsed.TotalSeconds,
            PeakResidentBytesDuringWalk = walked.PeakResidentBytesDuringWalk,
            ResidentBytesAfterWalk = afterRelease?.ResidentBytes,
            NotDownloadedCount = walked.NotDownloadedCount,
            Backend = walked.Backend,
        };
        LogSummary(result);
        return result;
    }

    private static WalkResult Walk(string root, IProgress<int>? progress)
    {
        // MFT pays off when the subtree is a large fraction of the volume:
        // it always reads the whole $MFT, so it wins for drive roots and
        // near-root scans (C:\, C:\Users\me — the "scan my drive/profile"
        // cases). Deep subtrees get the proportional FindFirstFileExW walk
        // instead of parsing millions of unrelated records.
        if (DepthFromVolumeRoot(root) <= 2)
        {
            var mft = MftScanner.Walk(root, progress);
            if (mft is not null) return mft;
        }
        return Win32Scanner.Walk(root, progress);
    }

    /// <summary>
    /// Path depth below the volume root: C:\ → 0, C:\Users → 1,
    /// C:\Users\me → 2. Non-local paths (UNC) return int.MaxValue.
    /// </summary>
    internal static int DepthFromVolumeRoot(string path)
    {
        string full = Path.GetFullPath(path).TrimEnd('\\', '/');
        string? root = Path.GetPathRoot(full);
        if (root is null || full.StartsWith(@"\\")) return int.MaxValue;
        var rel = Path.GetRelativePath(root, full);
        if (rel is "." or "") return 0;
        return rel.Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries).Length;
    }

    /// <summary>
    /// Reparse points are skipped — but only after the cloud check: OneDrive
    /// placeholders ARE reparse points (tags IO_REPARSE_TAG_CLOUD*), and the
    /// interesting signal is "in the cloud", not "is a reparse point". A
    /// junction to a local dir is skipped like a symlink on macOS — the
    /// target is counted at its real location, never double-counted here.
    ///
    /// A cloud placeholder is recorded, not opened: enumeration does not
    /// recall the content, opening the file would. Allocated size is the
    /// local footprint (0 when fully evicted); logical size is the cloud
    /// size. Descendants of a not-downloaded directory are skipped so
    /// listing them can't materialize the folder.
    /// </summary>
    public static ItemDecision Decide(
        bool isDirectory,
        bool isReparsePoint,
        bool isCloudPlaceholder,
        long logicalSize,
        long allocatedSize)
    {
        if (isReparsePoint && !isCloudPlaceholder)
        {
            return new ItemDecision(
                Include: false, LogicalSize: 0, AllocatedSize: 0,
                NotDownloaded: false, SkipDescendants: true);
        }
        if (isCloudPlaceholder)
        {
            return new ItemDecision(
                Include: true, LogicalSize: logicalSize, AllocatedSize: allocatedSize,
                NotDownloaded: true, SkipDescendants: isDirectory);
        }
        return new ItemDecision(
            Include: true, LogicalSize: logicalSize, AllocatedSize: allocatedSize,
            NotDownloaded: false, SkipDescendants: false);
    }

    /// <summary>
    /// FILE_ATTRIBUTE_* → the decide() inputs. Shared by both scanners.
    /// </summary>
    internal static ItemDecision DecideFromAttributes(
        uint attributes, long logicalSize, long allocatedSize)
    {
        bool isDir = (attributes & Win32.FILE_ATTRIBUTE_DIRECTORY) != 0;
        bool isReparse = (attributes & Win32.FILE_ATTRIBUTE_REPARSE_POINT) != 0;
        bool isCloud = (attributes & (Win32.FILE_ATTRIBUTE_OFFLINE
            | Win32.FILE_ATTRIBUTE_RECALL_ON_OPEN
            | Win32.FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS)) != 0;
        return Decide(isDir, isReparse, isCloud, logicalSize, allocatedSize);
    }

    private static void LogSummary(Result result)
    {
        string after = result.ResidentBytesAfterWalk?.ToString() ?? "unavailable";
        Console.WriteLine(
            $"DiskMap scan: backend={result.Backend} items={result.ItemCount} " +
            $"elapsed={result.ElapsedSeconds:0.000}s rss_during_walk_peak={result.PeakResidentBytesDuringWalk} " +
            $"rss_after_walk={after} not_downloaded={result.NotDownloadedCount}");
        Console.Out.Flush();
    }
}

/// <summary>Shared output of both scan backends.</summary>
internal sealed class WalkResult
{
    public required FileTree Tree { get; init; }
    public required int ItemCount { get; init; }
    public int NotDownloadedCount { get; init; }
    public ulong PeakResidentBytesDuringWalk { get; init; }
    public required string Backend { get; init; }
}
