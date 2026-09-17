using System.Text.Json;
using System.Text.Json.Serialization;

namespace DiskMap.Core;

/// <summary>
/// Regenerable directories found in an existing scan. The pattern list is
/// data (quick-wins-patterns.json, embedded resource) so it can grow
/// without an app release. Hits are for review — nothing here deletes.
///
/// Patterns can optionally carry a display category ("Development
/// dependencies", "System caches", …) so the UI can group hits, like the
/// macOS app's categories row. Unmatched patterns fall back to
/// "Regenerable folders".
/// </summary>
public static class QuickWins
{
    public sealed record Patterns(
        List<string> DirectoryNames,
        List<string> PathSuffixes,
        Dictionary<string, string>? Categories = null);

    public sealed record Hit(int Id, string Name, string Category);

    public const string DefaultCategory = "Regenerable folders";

    public static Patterns BundledPatterns()
    {
        var assembly = typeof(QuickWins).Assembly;
        var resourceName = assembly.GetManifestResourceNames()
            .FirstOrDefault(n => n.EndsWith("quick-wins-patterns.json", StringComparison.OrdinalIgnoreCase));
        if (resourceName is not null)
        {
            using var stream = assembly.GetManifestResourceStream(resourceName);
            if (stream is not null)
            {
                var decoded = JsonSerializer.Deserialize<Patterns>(stream, new JsonSerializerOptions
                {
                    PropertyNameCaseInsensitive = true,
                });
                if (decoded is not null) return decoded;
            }
        }
        return new Patterns(
            DirectoryNames: ["node_modules", ".venv", "venv", "target", ".next", "dist", "build", "__pycache__", ".gradle"],
            PathSuffixes: [@"AppData\Local\Temp", @"AppData\Local\npm-cache", @"AppData\Local\pip\cache"]);
    }

    /// <summary>
    /// Directories whose name or path matches patterns. A match swallows
    /// its descendants so `dist` inside `node_modules` is not counted twice.
    /// </summary>
    public static List<Hit> Find(FileTree tree, string root, Patterns patterns)
    {
        var hits = new List<Hit>();
        if (tree.Count == 0) return hits;
        var names = new HashSet<string>(patterns.DirectoryNames, StringComparer.OrdinalIgnoreCase);
        var suffixTails = new HashSet<string>(
            patterns.PathSuffixes.Select(SuffixTail), StringComparer.OrdinalIgnoreCase);

        var stack = new Stack<int>();
        stack.Push(0);
        while (stack.Count > 0)
        {
            int id = stack.Pop();
            if (id != 0 && tree.IsDirectory[id] && Match(id, names, suffixTails, patterns, root, tree) is { } matched)
            {
                hits.Add(new Hit(id, tree.NameOf(id), CategoryOf(matched, patterns)));
                continue; // swallow descendants
            }
            int child = tree.FirstChild[id];
            while (child != -1)
            {
                stack.Push(child);
                child = tree.NextSibling[child];
            }
        }
        return hits;
    }

    private static string CategoryOf(string matchedPattern, Patterns patterns)
    {
        if (patterns.Categories is { } categories
            && categories.TryGetValue(matchedPattern, out string? category)
            && category.Length > 0)
        {
            return category;
        }
        return DefaultCategory;
    }

    /// <summary>Returns the pattern that matched, or null.</summary>
    private static string? Match(
        int id,
        HashSet<string> names,
        HashSet<string> suffixTails,
        Patterns patterns,
        string root,
        FileTree tree)
    {
        string name = tree.NameOf(id);
        if (names.Contains(name))
        {
            return patterns.DirectoryNames.First(n =>
                n.Equals(name, StringComparison.OrdinalIgnoreCase));
        }
        if (!suffixTails.Contains(name)) return null;
        string path = tree.PathOf(id, root);
        foreach (var suffix in patterns.PathSuffixes)
        {
            string expanded = ExpandPath(suffix);
            if (path.Equals(expanded, StringComparison.OrdinalIgnoreCase)
                || path.EndsWith("\\" + expanded, StringComparison.OrdinalIgnoreCase))
                return suffix;
            // A suffix relative to the scan root (e.g. "AppData\Local\Temp").
            string relative = expanded;
            if (relative.StartsWith(@"~\") || relative.StartsWith("~/"))
                relative = relative[2..];
            if (path.EndsWith("\\" + relative, StringComparison.OrdinalIgnoreCase))
                return suffix;
        }
        return null;
    }

    private static string ExpandPath(string path)
    {
        // Support both "~/X" (user profile) and "%VAR%" environment syntax.
        if (path.StartsWith("~/") || path.StartsWith(@"~\"))
        {
            string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            path = Path.Combine(home, path[2..]);
        }
        return Environment.ExpandEnvironmentVariables(path);
    }

    private static string SuffixTail(string suffix)
    {
        string expanded = ExpandPath(suffix).TrimEnd('\\', '/');
        int sep = expanded.LastIndexOfAny(['\\', '/']);
        return sep < 0 ? expanded : expanded[(sep + 1)..];
    }
}
