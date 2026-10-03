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
        /// <summary>Why the walk ran instead of the MFT ("needs administrator", …); null when that was by design.</summary>
        public string? FallbackReason { get; init; }
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
            FallbackReason = walked.FallbackReason,
        };
        LogSummary(result);
        return result;
    }

    /// <summary>
    /// The MFT always reads the whole $MFT (~6 s for a full 1 TB NVMe
    /// volume) however small the folder, while the walk costs per item. So
    /// a drive root goes straight to the MFT (WizTree-style), and a folder
    /// gets a short walk first — most finish well inside it — falling
    /// through to the MFT only when the subtree turns out big.
    /// </summary>
    private static readonly TimeSpan WalkHeadStart = TimeSpan.FromSeconds(2);

    private static WalkResult Walk(string root, IProgress<int>? progress)
    {
        string? whyNot = null;
        int depth = DepthFromVolumeRoot(root);
        if (depth == 0)
        {
            if (TryMft(root, progress, out whyNot) is { } mft) return mft;
        }
        else if (depth != int.MaxValue && (whyNot = MftUnavailable(root)) is null)
        {
            if (Win32Scanner.Walk(root, progress, WalkHeadStart) is { } quick) return quick;
            if (TryMft(root, progress, out whyNot) is { } mft) return mft;
        }
        var walked = Win32Scanner.Walk(root, progress)!;
        walked.FallbackReason = whyNot;
        return walked;
    }

    private static WalkResult? TryMft(string root, IProgress<int>? progress, out string? whyNot)
    {
        try
        {
            return MftScanner.Walk(root, progress, out whyNot);
        }
        catch (Exception ex)
        {
            // Hostile on-disk state degrades to the slow path, never a crash.
            whyNot = ex.Message;
            return null;
        }
    }

    /// <summary>
    /// Why the MFT can't run here (null when it can) — checked first so a
    /// head-start walk is never thrown away for nothing.
    /// </summary>
    private static string? MftUnavailable(string root)
    {
        if (!Win32.EnableBackupPrivileges()) return "needs administrator";
        try
        {
            return new DriveInfo(Path.GetPathRoot(Path.GetFullPath(root))!).DriveFormat == "NTFS" ? null : "not NTFS";
        }
        catch (IOException) { return "volume unreadable"; }
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
            $"rss_after_walk={after} not_downloaded={result.NotDownloadedCount} mft_skipped={result.FallbackReason ?? "-"}");
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
    public string? FallbackReason { get; set; }
}
