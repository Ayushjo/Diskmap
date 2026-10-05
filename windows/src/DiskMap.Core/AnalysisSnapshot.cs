namespace DiskMap.Core;

/// <summary>High-level storage category for the Overview page.</summary>
public sealed record StorageCategory(
    string Key,
    string Title,
    long Bytes,
    /// <summary>Semantic: appdata, downloads, developer, caches, apps, documents, filetype, other.</summary>
    string ColorHint,
    /// <summary>Primary folder node id when known.</summary>
    int? NodeId = null,
    string? ColorHex = null,
    /// <summary>The file-type id for a file-type category.</summary>
    string? FileKind = null);

/// <summary>
/// How Overview splits a scan into categories. Folder names only mean
/// something at the top of a user profile or a drive; anywhere else the
/// root's children are arbitrary, so the split is by file type instead.
/// </summary>
public enum CategoryMode
{
    /// <summary>A user profile folder: AppData, Downloads, Documents… by name.</summary>
    Home,
    /// <summary>A drive root: Users, Windows, Program Files…</summary>
    WholeDisk,
    /// <summary>Any other folder or an external drive: totals by file type.</summary>
    Folder,
}

public sealed record StorageFileHit(
    int NodeId, string Name, long Bytes, string RelativePath, int ModifiedDay);

public enum StorageHealth { Healthy, Tight, Low, Critical }

/// <summary>
/// Canonical post-scan summary consumed by Overview and inspectors —
/// the Windows counterpart of the macOS AnalysisSnapshot (TASK-040/076).
/// </summary>
public sealed class AnalysisSnapshot
{
    public string ScanRootPath { get; init; } = "";
    public VolumeInfo? Volume { get; init; }
    /// <summary>Root total on the active basis.</summary>
    public long ScannedBytes { get; init; }
    public List<StorageCategory> Categories { get; init; } = [];
    public CategoryMode Mode { get; init; } = CategoryMode.Folder;
    public List<StorageFileHit> TopFiles { get; init; } = [];
    public List<StorageFileHit> TopFolders { get; init; } = [];
    public long ReviewableBytes { get; init; }
    public long ForgottenBytes { get; init; }
    public long QuickWinBytes { get; init; }
    public StorageHealth Health { get; init; }
    public int FileCount { get; init; }
    public int FolderCount { get; init; }
    /// <summary>
    /// Root total on the ALLOCATED basis whatever <see cref="ScannedBytes"/>
    /// shows, so it can be compared with volume used space.
    /// </summary>
    public long ScannedOnDiskBytes { get; init; }
    /// <summary>What hard-link de-duplication removed (WIN-002), for honest copy.</summary>
    public FileTree.HardLinkCorrection HardLinkCorrection { get; init; }

    /// <summary>Volume "used" versus what this scan accounts for.</summary>
    public readonly record struct VolumeReconciliation(
        long UsedBytes, long ScannedBytes, long UnaccountedBytes,
        bool ScannedExceedsUsed, double CoverageFraction);

    /// <summary>
    /// Null when there is no volume to compare against. The gap is its own
    /// figure — nothing inflates a category to close it.
    /// </summary>
    public VolumeReconciliation? Reconciliation
    {
        get
        {
            if (Volume is not { } v || v.UsedBytes <= 0) return null;
            long used = v.UsedBytes;
            long scanned = Math.Max(0, ScannedOnDiskBytes);
            return new VolumeReconciliation(
                used, scanned,
                Math.Max(0, used - scanned),
                scanned > used,
                Math.Min(1, (double)scanned / used));
        }
    }

    public static CategoryMode DetectMode(FileTree tree, string rootPath)
    {
        string root = Path.GetFullPath(rootPath).TrimEnd('\\');
        string? driveRoot = Path.GetPathRoot(root)?.TrimEnd('\\');
        if (string.Equals(root, driveRoot, StringComparison.OrdinalIgnoreCase)
            && root.Length >= 2 && root[1] == ':')
        {
            return CategoryMode.WholeDisk;
        }
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile).TrimEnd('\\');
        if (string.Equals(root, home, StringComparison.OrdinalIgnoreCase)) return CategoryMode.Home;
        if (tree.Count == 0) return CategoryMode.Folder;
        // Looks-like-home: at least two of the classic profile folders.
        var homeNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            { "AppData", "Downloads", "Documents", "Desktop" };
        int matches = 0;
        int child = tree.FirstChild[0];
        while (child != -1)
        {
            if (tree.IsDirectory[child] && homeNames.Contains(tree.NameOf(child))) matches++;
            child = tree.NextSibling[child];
        }
        return matches >= 2 ? CategoryMode.Home : CategoryMode.Folder;
    }

    public static AnalysisSnapshot Build(
        FileTree tree,
        string rootPath,
        long[] logical,
        long[] allocated,
        SizeBasis basis = SizeBasis.Allocated,
        IReadOnlyList<QuickWins.Hit>? quickWins = null,
        Dictionary<string, long>? typeBreakdown = null,
        int today = 0)
    {
        var totals = basis == SizeBasis.Logical ? logical : allocated;
        if (tree.Count == 0 || totals.Length != tree.Count) return new AnalysisSnapshot();
        if (today == 0) today = AgeMap.Today();

        var volume = VolumeStats.Of(rootPath);
        long scanned = totals[0];
        var mode = DetectMode(tree, rootPath);
        var cats = mode == CategoryMode.Folder
            ? CategorizeByType(typeBreakdown ?? FileTypes.TypeBreakdown(tree, totals, 0), scanned)
            : Categorize(tree, rootPath, totals);
        var topFiles = TopHits(tree, rootPath, totals, directories: false, 12);
        var topFolders = TopHits(tree, rootPath, totals, directories: true, 12);
        var forgotten = AgeMap.Untouched(tree, totals, today, 200);
        long forgottenBytes = forgotten.Sum(id => totals[id]);
        long qwBytes = (quickWins ?? []).Sum(h => h.Id >= 0 && h.Id < totals.Length ? totals[h.Id] : 0L);
        // Conservative: quick-wins + half of forgotten (not "guaranteed reclaim").
        long reviewable = qwBytes + forgottenBytes / 2;
        var (files, folders) = tree.RollUpCounts();
        return new AnalysisSnapshot
        {
            ScanRootPath = rootPath,
            Volume = volume,
            ScannedBytes = scanned,
            Categories = cats,
            Mode = mode,
            TopFiles = topFiles,
            TopFolders = topFolders,
            ReviewableBytes = reviewable,
            ForgottenBytes = forgottenBytes,
            QuickWinBytes = qwBytes,
            Health = HealthOf(volume),
            FileCount = files[0],
            FolderCount = folders[0],
            ScannedOnDiskBytes = allocated[0],
            HardLinkCorrection = tree.GetHardLinkCorrection(),
        };
    }

    private static StorageHealth HealthOf(VolumeInfo? v)
    {
        if (v is not { } volume || volume.TotalBytes <= 0) return StorageHealth.Healthy;
        double freeFrac = (double)volume.FreeBytes / volume.TotalBytes;
        return freeFrac switch
        {
            < 0.05 => StorageHealth.Critical,
            < 0.12 => StorageHealth.Low,
            < 0.20 => StorageHealth.Tight,
            _ => StorageHealth.Healthy,
        };
    }

    /// <summary>
    /// Drive or home-folder mode: the preconfigured laptop categories
    /// (StorageClassifier) — WSL and Docker disks, code, dependencies,
    /// toolchains, AI models, personal folders, apps, system… exclusive
    /// by construction, so the rows sum to the scanned total. Key = the
    /// class id; NodeId = the biggest folder the class claimed.
    /// </summary>
    private static List<StorageCategory> Categorize(FileTree tree, string rootPath, long[] totals) =>
        StorageClassifier.Rollup(tree, rootPath, totals)
            .Select(t => new StorageCategory(t.Class.Id, t.Class.Title, t.Bytes, t.Class.Id,
                t.LargestNode, t.Class.ColorHex))
            .ToList();

    /// <summary>
    /// Folder mode: one category per file type, biggest first, then
    /// "Other" for what no type claims. The breakdown's suppressed
    /// hard-link rows already count once, so the rows sum to scanned.
    /// </summary>
    private static List<StorageCategory> CategorizeByType(Dictionary<string, long> breakdown, long scanned)
    {
        var cats = breakdown
            .Where(kv => kv.Value > 0 && kv.Key != FileTypes.OtherId)
            .OrderByDescending(kv => kv.Value)
            .Select(kv => new StorageCategory(
                $"type:{kv.Key}", FileTypes.LabelOf(kv.Key), kv.Value, "filetype",
                ColorHex: FileTypes.TileColorOf(kv.Key), FileKind: kv.Key))
            .ToList();
        long typed = cats.Sum(c => c.Bytes) + breakdown.GetValueOrDefault(FileTypes.OtherId);
        if (scanned - typed > 0)
            cats.Add(new StorageCategory("other", "Other", scanned - typed, "other"));
        return cats;
    }

    private static List<StorageFileHit> TopHits(
        FileTree tree, string rootPath, long[] totals, bool directories, int limit)
    {
        var ids = TopSizes.Largest(1, tree.Count, limit, id => totals[id],
            id => tree.IsDirectory[id] == directories && totals[id] > 0);
        return ids.Select(id => new StorageFileHit(
            id, tree.NameOf(id), totals[id],
            tree.PathOf(id, rootPath), tree.ModifiedDay[id])).ToList();
    }
}
