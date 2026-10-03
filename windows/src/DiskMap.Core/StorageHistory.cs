using System.Text.Json;
using System.Text.Json.Serialization;

namespace DiskMap.Core;

/// <summary>
/// A small record of every scan of a folder, so DiskMap can say what grew
/// since last week (TASK-079 port). JSON only; no tree is kept — one entry
/// is a few hundred folder sizes.
///
/// One file per scanned root:
/// `%LOCALAPPDATA%\DiskMap\History\&lt;fnv-1a of the path&gt;.json`.
/// Written whole and atomically after each scan; never deleted. A file
/// that no longer decodes is left alone and a `.v2.json` beside it takes
/// over.
/// </summary>
public sealed class StorageHistory
{
    public sealed record Entry(
        DateTimeOffset Date,
        long FreeBytes,
        long TotalBytes,
        long ScannedBytes,
        int DeniedCount,
        /// <summary>
        /// The sharing accounting the sizes were counted with (the macOS
        /// sharingMode counterpart): entries counted differently are not
        /// compared. Windows always dedups hard links.
        /// </summary>
        string SharingMode,
        /// <summary>Root-relative folder path → allocated bytes. Root children of
        /// 50 MB or more; for big top-level folders, their 20 largest children too.</summary>
        Dictionary<string, long> Folders)
    {
        /// <summary>The only counting mode this port writes.</summary>
        public const string SharingModeHardLinkDedup = "hardlink-dedup";
    }

    private sealed class File_
    {
        [JsonPropertyName("version")] public int Version { get; set; } = 1;
        [JsonPropertyName("rootPath")] public string RootPath { get; set; } = "";
        [JsonPropertyName("entries")] public List<Entry> Entries { get; set; } = [];
    }

    public string DirectoryPath { get; }

    public StorageHistory(string? directory = null) =>
        DirectoryPath = directory ?? DefaultDirectory();

    public static string DefaultDirectory() =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "DiskMap", "History");

    // MARK: - Building an entry

    public const long RootChildThreshold = 50_000_000;
    public const long BigFolderBytes = 5_000_000_000;
    public const double BigFolderShare = 0.05;
    public const int ChildrenPerBigFolder = 20;
    public const int MaxFolders = 300;

    /// <summary>
    /// The folder sizes worth remembering from one scan. <paramref name="totals"/>
    /// must be the allocated rollup of <paramref name="tree"/>.
    /// </summary>
    public static Dictionary<string, long> Folders(FileTree tree, long[] totals)
    {
        var result = new Dictionary<string, long>();
        if (tree.Count == 0 || totals.Length != tree.Count) return result;
        long rootTotal = totals[0];
        var children = tree.ChildrenOf(0, totals)
            .Where(c => tree.IsDirectory[c.Id] && c.Size >= RootChildThreshold)
            .OrderByDescending(c => c.Size).ThenBy(c => tree.NameOf(c.Id))
            .ToList();
        foreach (var child in children)
        {
            if (result.Count >= MaxFolders) break;
            result[tree.NameOf(child.Id)] = child.Size;
        }
        foreach (var child in children)
        {
            bool big = child.Size >= BigFolderBytes
                || (rootTotal > 0 && (double)child.Size / rootTotal >= BigFolderShare);
            if (!big) continue;
            string parentName = tree.NameOf(child.Id);
            var grandchildren = tree.ChildrenOf(child.Id, totals)
                .Where(g => tree.IsDirectory[g.Id] && g.Size > 0)
                .OrderByDescending(g => g.Size).ThenBy(g => tree.NameOf(g.Id))
                .Take(ChildrenPerBigFolder);
            foreach (var grandchild in grandchildren)
            {
                if (result.Count >= MaxFolders) break;
                result[parentName + "/" + tree.NameOf(grandchild.Id)] = grandchild.Size;
            }
        }
        return result;
    }

    // MARK: - Reading and writing

    internal static string Hash(string path)
    {
        ulong value = 0xcbf29ce484222325;
        foreach (byte b in System.Text.Encoding.UTF8.GetBytes(path))
        {
            value ^= b;
            value *= 0x00000100000001b3;
        }
        return value.ToString("x16");
    }

    private string PrimaryPath(string rootPath) =>
        Path.Combine(DirectoryPath, Hash(rootPath) + ".json");
    private string FallbackPath(string rootPath) =>
        Path.Combine(DirectoryPath, Hash(rootPath) + ".v2.json");

    /// <summary>
    /// The file in use for <paramref name="rootPath"/>: the primary one,
    /// unless it exists and cannot be read — then the fallback, leaving
    /// the damaged one in place.
    /// </summary>
    private string ActivePath(string rootPath)
    {
        string primary = PrimaryPath(rootPath);
        if (!File.Exists(primary)) return primary;
        return Decode(primary, rootPath) is not null ? primary : FallbackPath(rootPath);
    }

    private File_? Decode(string path, string rootPath)
    {
        try
        {
            var file = JsonSerializer.Deserialize<File_>(File.ReadAllText(path),
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            return file is not null && file.RootPath == rootPath ? file : null;
        }
        catch { return null; }
    }

    public List<Entry> Entries(string rootPath) =>
        Decode(ActivePath(rootPath), rootPath)?.Entries ?? [];

    /// <summary>Adds <paramref name="entry"/>, applies retention, and rewrites the file atomically.</summary>
    public List<Entry> Record(Entry entry, string rootPath)
    {
        Directory.CreateDirectory(DirectoryPath);
        string path = ActivePath(rootPath);
        var existing = Decode(path, rootPath)?.Entries ?? [];
        var kept = Retained(existing.Append(entry), entry.Date);
        var file = new File_ { RootPath = rootPath, Entries = kept };
        string tmp = path + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(file,
            new JsonSerializerOptions { WriteIndented = false }));
        File.Move(tmp, path, overwrite: true);
        return kept;
    }

    // MARK: - Retention

    /// <summary>
    /// One entry per calendar day (the day's last); every day of the last
    /// 30; the last entry of each ISO week for the rest of the year;
    /// nothing older. About 80 entries at most.
    /// </summary>
    public static List<Entry> Retained(IEnumerable<Entry> entries, DateTimeOffset now)
    {
        var sorted = entries.OrderBy(e => e.Date).ToList();
        var perDay = new Dictionary<DateOnly, Entry>();
        foreach (var e in sorted) perDay[DateOnly.FromDateTime(e.Date.LocalDateTime)] = e;
        var today = DateOnly.FromDateTime(now.LocalDateTime);
        var recentCutoff = today.AddDays(-30);
        var yearCutoff = today.AddDays(-365);
        var perWeek = new Dictionary<(int Year, int Week), Entry>();
        var recent = new List<Entry>();
        foreach (var (day, entry) in perDay)
        {
            if (day >= recentCutoff) recent.Add(entry);
            else if (day >= yearCutoff)
            {
                var key = (System.Globalization.ISOWeek.GetYear(day.ToDateTime(TimeOnly.MinValue)),
                           System.Globalization.ISOWeek.GetWeekOfYear(day.ToDateTime(TimeOnly.MinValue)));
                if (!perWeek.TryGetValue(key, out var current) || entry.Date > current.Date)
                    perWeek[key] = entry;
            }
        }
        return recent.Concat(perWeek.Values).OrderBy(e => e.Date).ToList();
    }

    // MARK: - Comparing

    public readonly record struct Growth(string Path, long Before, long After)
    {
        public long Delta => After - Before;
    }

    public sealed record Comparison(
        DateTimeOffset Since,
        /// <summary>True when the comparison point is the "about a week ago" one.</summary>
        bool IsWeek,
        long FreeDelta,
        long ScannedDelta,
        /// <summary>Largest growers first, each at least <see cref="MinGrowth"/>.</summary>
        List<Growth> Growers,
        /// <summary>Set when the two scans could not read the same folders.</summary>
        bool DeniedChanged);

    public const long MinGrowth = 100_000_000;

    /// <summary>
    /// What changed between the entry about a week before <paramref name="latest"/>
    /// and <paramref name="latest"/>. The comparison point is the entry closest
    /// to 7 days back among those at least 5 days old; failing that, the oldest
    /// at least 2 days old ("since &lt;date&gt;"); failing that, none.
    /// </summary>
    public static Comparison? Compare(IReadOnlyList<Entry> entries, Entry latest, int limit = 5)
    {
        var sameCounting = entries.Where(e =>
            e.SharingMode == latest.SharingMode && e.Date < latest.Date).ToList();
        var target = latest.Date.AddDays(-7);
        var weekCandidates = sameCounting
            .Where(e => (latest.Date - e.Date) >= TimeSpan.FromDays(5)).ToList();
        Entry? base_ = null;
        bool isWeek;
        if (weekCandidates.Count > 0)
        {
            base_ = weekCandidates.OrderBy(e =>
                Math.Abs((e.Date - target).Ticks)).First();
            isWeek = true;
        }
        else
        {
            var oldest = sameCounting
                .Where(e => (latest.Date - e.Date) >= TimeSpan.FromDays(2))
                .OrderBy(e => e.Date).FirstOrDefault();
            if (oldest is null) return null;
            base_ = oldest;
            isWeek = false;
        }

        var growers = new List<Growth>();
        foreach (string path in latest.Folders.Keys.Union(base_.Folders.Keys))
        {
            // A second-level folder is compared only when both scans looked
            // inside its parent; otherwise "new" would just mean "newly big".
            int slash = path.IndexOf('/');
            if (slash > 0)
            {
                string parent = path[..slash];
                bool bothDeep = base_.Folders.Keys.Any(k => k.StartsWith(parent + "/"))
                    && latest.Folders.Keys.Any(k => k.StartsWith(parent + "/"));
                if (!bothDeep) continue;
            }
            var growth = new Growth(path,
                base_.Folders.GetValueOrDefault(path), latest.Folders.GetValueOrDefault(path));
            if (growth.Delta >= MinGrowth) growers.Add(growth);
        }
        growers.Sort((a, b) => a.Delta != b.Delta
            ? b.Delta.CompareTo(a.Delta) : string.CompareOrdinal(a.Path, b.Path));
        // Prefer the deepest explanation: drop a parent whose growth a
        // listed child already accounts for most of.
        growers = growers.Where(g => !growers.Any(o =>
            o.Path.StartsWith(g.Path + "/") && o.Delta >= 0.8 * g.Delta)).ToList();
        return new Comparison(
            base_.Date, isWeek,
            latest.FreeBytes - base_.FreeBytes,
            latest.ScannedBytes - base_.ScannedBytes,
            growers.Take(limit).ToList(),
            latest.DeniedCount != base_.DeniedCount);
    }
}
