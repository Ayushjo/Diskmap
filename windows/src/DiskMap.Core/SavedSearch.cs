using System.Text.Json;
using System.Text.Json.Serialization;

namespace DiskMap.Core;

/// <summary>
/// A Find query kept in the sidebar (TASK-081 port). Stored as JSON under
/// %LOCALAPPDATA%\DiskMap; nothing here touches the disk beyond that.
/// </summary>
public sealed record SavedSearch(
    Guid Id,
    string Name,
    string Query,
    string Sort)
{
    public FileQuery.Sort FileSort =>
        Enum.TryParse<FileQuery.Sort>(Sort, ignoreCase: true, out var sort)
            ? sort : FileQuery.Sort.Largest;

    public static SavedSearch New(string name, string query, FileQuery.Sort sort = FileQuery.Sort.Largest) =>
        new(Guid.NewGuid(), name, query, sort.ToString());
}

public static class SavedSearches
{
    /// <summary>Each one costs a pass over the tree after every scan.</summary>
    public const int Limit = 20;

    public readonly record struct Total(int Count, long Bytes);

    /// <summary>Offered in Find's empty state, never added on their own.</summary>
    public static readonly (string Name, string Query)[] Starters =
    [
        ("Old installers", "ext:exe,msi,zip age>30d in:downloads"),
        ("Big videos", "kind:video size>1GB"),
        ("Logs", "name:*.log size>50MB"),
    ];

    public static string DefaultPath() =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "DiskMap", "saved-searches.json");

    public static List<SavedSearch> Load(string? path = null)
    {
        try
        {
            path ??= DefaultPath();
            if (!File.Exists(path)) return [];
            var list = JsonSerializer.Deserialize<List<SavedSearch>>(File.ReadAllText(path),
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            return (list ?? []).Take(Limit).ToList();
        }
        catch { return []; }
    }

    public static void Save(IEnumerable<SavedSearch> list, string? path = null)
    {
        try
        {
            path ??= DefaultPath();
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            string tmp = path + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(list.Take(Limit).ToList()));
            File.Move(tmp, path, overwrite: true);
        }
        catch { }
    }

    /// <summary>
    /// The query's plain-language meaning, short enough for a sidebar row
    /// ("Videos · larger than 1 GB").
    /// </summary>
    public static string DefaultName(string text, string root)
    {
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var parsed = FileQuery.Parse(text, home, root);
        var parts = parsed.Query.Describe();
        // "Files" alone says nothing; drop it when something follows.
        var useful = parts.Count > 1 && parts[0] is "Files" or "Files and folders"
            ? parts.Skip(1).ToList() : parts;
        string name = string.Join(" · ", useful);
        if (name.Length == 0) name = text.Trim();
        if (name.Length > 0) name = char.ToUpperInvariant(name[0]) + name[1..];
        return name.Length > 40 ? name[..39] + "…" : name;
    }

    /// <summary>
    /// Match count and bytes for every saved search over one scan — one
    /// count-only FileQuery pass each, off the UI thread.
    /// </summary>
    public static Dictionary<Guid, Total> Totals(
        IReadOnlyList<SavedSearch> list,
        FileTree tree,
        string rootPath,
        long[] totals,
        FileQuery.Context context,
        Func<bool>? isCancelled = null)
    {
        isCancelled ??= () => false;
        var result = new Dictionary<Guid, Total>();
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        foreach (var search in list.Take(Limit))
        {
            if (isCancelled()) break;
            var parsed = FileQuery.Parse(search.Query, home, rootPath);
            var run = parsed.Query.Run(tree, rootPath, totals, context,
                search.FileSort, limit: 0, isCancelled);
            if (run.WasCancelled) break;
            result[search.Id] = new Total(run.MatchCount, run.MatchedBytes);
        }
        return result;
    }
}
