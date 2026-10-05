using System.Text.Json;

namespace DiskMap.Core;

/// <summary>
/// File-kind categories — the data behind "kind" badges, the "What's
/// inside?" breakdown, and type-colored tiles. The category list is data
/// (file-type-categories.json, embedded resource) matching the macOS
/// build's file-type-categories.json, extended with the disk-image and
/// application kinds the Windows file set produces (.vhdx, .exe…).
/// </summary>
public static class FileTypes
{
    public sealed record Category(
        string Id,
        string Label,
        string Color,
        string BadgeBackground,
        string BadgeForeground,
        string[] Extensions);

    public const string FolderId = "folder";
    public const string OtherId = "other";

    private static readonly Lazy<(List<Category> categories, Dictionary<string, Category> byExtension)> Data =
        new(Load, LazyThreadSafetyMode.ExecutionAndPublication);

    public static IReadOnlyList<Category> Categories => Ensure().categories;

    private static (List<Category> categories, Dictionary<string, Category> byExtension) Ensure() => Data.Value;

    private static (List<Category> categories, Dictionary<string, Category> byExtension) Load()
    {
        var categories = new List<Category>();
        var assembly = typeof(FileTypes).Assembly;
        var resourceName = assembly.GetManifestResourceNames()
            .FirstOrDefault(n => n.EndsWith("file-type-categories.json", StringComparison.OrdinalIgnoreCase));
        if (resourceName is not null)
        {
            using var stream = assembly.GetManifestResourceStream(resourceName);
            if (stream is not null)
            {
                var doc = JsonDocument.Parse(stream);
                if (doc.RootElement.TryGetProperty("categories", out var list))
                {
                    foreach (var c in list.EnumerateArray())
                    {
                        categories.Add(new Category(
                            Id: c.GetProperty("id").GetString() ?? OtherId,
                            Label: c.GetProperty("label").GetString() ?? "Other",
                            Color: c.TryGetProperty("color", out var col) ? col.GetString() ?? "#9AA3AF" : "#9AA3AF",
                            BadgeBackground: c.TryGetProperty("badgeBackground", out var bb) ? bb.GetString() ?? "#F1F5F9" : "#F1F5F9",
                            BadgeForeground: c.TryGetProperty("badgeForeground", out var bf) ? bf.GetString() ?? "#475569" : "#475569",
                            Extensions: c.GetProperty("extensions").EnumerateArray()
                                .Select(e => e.GetString() ?? "").Where(e => e.Length > 0).ToArray()));
                    }
                }
            }
        }
        var byExtension = new Dictionary<string, Category>(StringComparer.OrdinalIgnoreCase);
        foreach (var cat in categories)
            foreach (var ext in cat.Extensions)
                byExtension.TryAdd(ext, cat);
        return (categories, byExtension);
    }

    /// <summary>The category id for a file name's extension; "other" when unknown.</summary>
    public static string KindOfFile(string name)
    {
        int dot = name.LastIndexOf('.');
        if (dot < 0 || dot == name.Length - 1) return OtherId;
        var (_, byExtension) = Ensure();
        return byExtension.TryGetValue(name[(dot + 1)..], out var cat) ? cat.Id : OtherId;
    }

    public static string KindOf(FileTree tree, int id) =>
        tree.IsDirectory[id] ? FolderId : KindOfFile(tree.NameOf(id));

    public static string LabelOf(string kindId)
    {
        if (kindId == FolderId) return "Folder";
        if (kindId == OtherId) return "Other";
        var (categories, _) = Ensure();
        return categories.FirstOrDefault(c => c.Id == kindId)?.Label ?? "Other";
    }

    public static string TileColorOf(string kindId)
    {
        var (categories, _) = Ensure();
        return categories.FirstOrDefault(c => c.Id == kindId)?.Color ?? "#A9B0BC";
    }

    /// <summary>The saturated badge accent for a kind — bars, dots, icon fills.</summary>
    public static string BadgeForegroundOf(string kindId)
    {
        var (categories, _) = Ensure();
        return categories.FirstOrDefault(c => c.Id == kindId)?.BadgeForeground ?? "#6B7280";
    }

    /// <summary>
    /// Bytes per category over the files inside <paramref name="nodeId"/>
    /// (its whole subtree for a directory). Returns id → bytes, plus a
    /// bucket named <see cref="OtherId"/> for everything unclassified.
    /// </summary>
    public static Dictionary<string, long> TypeBreakdown(FileTree tree, long[] totals, int nodeId)
    {
        var result = new Dictionary<string, long>();
        if (tree.Count == 0 || totals.Length != tree.Count) return result;
        var stack = new Stack<int>();
        stack.Push(nodeId);
        while (stack.Count > 0)
        {
            int id = stack.Pop();
            if (tree.IsDirectory[id])
            {
                int child = tree.FirstChild[id];
                while (child != -1) { stack.Push(child); child = tree.NextSibling[child]; }
            }
            else
            {
                string kind = KindOfFile(tree.NameOf(id));
                result[kind] = result.GetValueOrDefault(kind) + Math.Max(0, totals[id]);
            }
        }
        return result;
    }

    /// <summary>
    /// The category holding the most bytes inside a node — what a
    /// type-colored tile shows. Directories with no classifiable file
    /// bytes return <see cref="OtherId"/>.
    /// </summary>
    public static string DominantKind(FileTree tree, long[] totals, int nodeId)
    {
        if (!tree.IsDirectory[nodeId]) return KindOfFile(tree.NameOf(nodeId));
        var breakdown = TypeBreakdown(tree, totals, nodeId);
        if (breakdown.Count == 0) return OtherId;
        return breakdown.MaxBy(kv => kv.Value).Key;
    }
}
