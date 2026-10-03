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

    private static readonly HashSet<string> PersonalNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "Documents", "Desktop", "Pictures", "Music", "Videos", "Movies",
        "Saved Games", "Contacts", "Favorites", "Links", "Searches",
        "OneDrive", "Dropbox", "iCloudDrive", "Users",
    };
    private static readonly HashSet<string> DeveloperNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "Developer", "dev", "source", "repos", "projects", "code", "workspaces",
        ".npm", ".nvm", ".yarn", ".pnpm-store", ".cache", ".cargo", ".rustup",
        ".gradle", ".m2", ".nuget", ".dotnet", ".android", ".cursor",
        ".codex", ".docker", ".pyenv", ".conda", ".vscode",
    };
    private static readonly HashSet<string> SystemNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "Windows", "Program Files", "Program Files (x86)", "ProgramData",
        "Recovery", "System Volume Information", "$Recycle.Bin", "PerfLogs",
        "Boot", "Drivers",
    };

    /// <summary>
    /// Exclusive partition of the scan root's immediate children — one
    /// child contributes to exactly one category. AppData peels cache and
    /// developer subtrees out so the bytes stay exclusive, like the
    /// macOS Library split (Caches/Logs/Developer carved out of Library).
    /// </summary>
    private static List<StorageCategory> Categorize(FileTree tree, string rootPath, long[] totals)
    {
        var buckets = new Dictionary<string, (string Title, string Hint, long Bytes, int? Node)>
        {
            ["applications"] = ("Applications", "apps", 0, null),
            ["appdata"] = ("App data", "library", 0, null),
            ["downloads"] = ("Downloads", "downloads", 0, null),
            ["documents"] = ("Personal", "documents", 0, null),
            ["developer"] = ("Developer", "developer", 0, null),
            ["caches"] = ("Caches & Temp", "caches", 0, null),
            ["system"] = ("System", "system", 0, null),
            ["other"] = ("Other", "other", 0, null),
        };
        void Add(string key, long bytes, int node)
        {
            if (bytes <= 0) return;
            var b = buckets[key];
            b.Bytes += bytes;
            b.Node ??= node;
            buckets[key] = b;
        }

        foreach (var child in tree.ChildrenOf(0, totals))
        {
            long bytes = child.Size;
            if (bytes <= 0) continue;
            string name = tree.NameOf(child.Id);
            if (name.Equals("AppData", StringComparison.OrdinalIgnoreCase))
            {
                long appDataBytes = bytes;
                // Peel user-level caches and dev caches out of AppData.
                foreach (var mid in tree.ChildrenOf(child.Id, totals))   // Local/Roaming/LocalLow
                {
                    foreach (var g in tree.ChildrenOf(mid.Id, totals))
                    {
                        string gn = tree.NameOf(g.Id);
                        if (gn.Equals("Temp", StringComparison.OrdinalIgnoreCase)
                            || gn.EndsWith("cache", StringComparison.OrdinalIgnoreCase)
                            || gn.Equals("pip", StringComparison.OrdinalIgnoreCase))
                        {
                            Add("caches", g.Size, g.Id);
                            appDataBytes = Math.Max(0, appDataBytes - g.Size);
                        }
                        else if (gn.Equals("NuGet", StringComparison.OrdinalIgnoreCase))
                        {
                            Add("developer", g.Size, g.Id);
                            appDataBytes = Math.Max(0, appDataBytes - g.Size);
                        }
                    }
                }
                Add("appdata", appDataBytes, child.Id);
            }
            else if (name.Equals("Downloads", StringComparison.OrdinalIgnoreCase))
            {
                Add("downloads", bytes, child.Id);
            }
            else if (PersonalNames.Contains(name))
            {
                Add("documents", bytes, child.Id);
            }
            else if (DeveloperNames.Contains(name)
                     || name.StartsWith("Applications", StringComparison.OrdinalIgnoreCase))
            {
                Add("developer", bytes, child.Id);
            }
            else if (name.EndsWith(".cache", StringComparison.OrdinalIgnoreCase))
            {
                Add("caches", bytes, child.Id);
            }
            else if (SystemNames.Contains(name)
                     || name.StartsWith("Program Files", StringComparison.OrdinalIgnoreCase))
            {
                Add("system", bytes, child.Id);
            }
            else
            {
                Add("other", bytes, child.Id);
            }
        }

        var order = new[] { "applications", "appdata", "downloads", "documents", "developer", "caches", "system", "other" };
        return order
            .Where(k => buckets[k].Bytes > 0)
            .Select(k => new StorageCategory(k, buckets[k].Title, buckets[k].Bytes, buckets[k].Hint, buckets[k].Node))
            .ToList();
        // sum(categories) == accounted root children, exclusive by
        // construction — never inflate Other to fill the volume.
    }

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
