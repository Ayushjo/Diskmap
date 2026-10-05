using System.Text.Json;
using System.Text.Json.Serialization;

namespace DiskMap.Core;

/// <summary>
/// A tool's own cleanup command for a folder (TASK-055). DiskMap shows the
/// command and never runs it: <see cref="CleanupQueue"/> remains the only
/// way DiskMap removes anything, and it only moves to the Recycle Bin.
/// </summary>
public sealed class CleanupRecipe
{
    public required string Id { get; init; }
    public required string Title { get; init; }
    public required string Command { get; init; }
    public required string Why { get; init; }
    /// <summary>
    /// Recycling the folder damages the tool's state (Docker's disk image,
    /// a package store's index) — steer to the command instead.
    /// </summary>
    public bool TrashIsUnsafe { get; init; }
    public List<string> Names { get; init; } = [];
    public List<string> PathSuffixes { get; init; } = [];
    public List<string> PathContains { get; init; } = [];

    public bool Matches(string path)
    {
        string normalized = Normalize(path);
        string last = normalized[(normalized.LastIndexOf('\\') + 1)..];
        return Names.Any(n => n.Equals(last, StringComparison.OrdinalIgnoreCase))
            || PathSuffixes.Any(s => normalized.EndsWith(Normalize(s), StringComparison.OrdinalIgnoreCase))
            || PathContains.Any(s => normalized.Contains(Normalize(s), StringComparison.OrdinalIgnoreCase));
    }

    private static string Normalize(string path) => path.Replace('/', '\\').TrimEnd('\\');
}

public static class CleanupRecipes
{
    private sealed class File { public List<CleanupRecipe>? Recipes { get; set; } }

    private static readonly Lazy<List<CleanupRecipe>> BundledLazy = new(() => Load());

    public static List<CleanupRecipe> Bundled => BundledLazy.Value;

    internal static List<CleanupRecipe> Load(byte[]? data = null)
    {
        byte[]? bytes = data;
        if (bytes is null)
        {
            var assembly = typeof(CleanupRecipes).Assembly;
            var resourceName = assembly.GetManifestResourceNames()
                .FirstOrDefault(n => n.EndsWith("cleanup-recipes.json", StringComparison.OrdinalIgnoreCase));
            if (resourceName is null) return [];
            using var stream = assembly.GetManifestResourceStream(resourceName);
            if (stream is null) return [];
            using var ms = new MemoryStream();
            stream.CopyTo(ms);
            bytes = ms.ToArray();
        }
        try
        {
            var file = JsonSerializer.Deserialize<File>(bytes, new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true,
                ReadCommentHandling = JsonCommentHandling.Skip,
            });
            return file?.Recipes ?? [];
        }
        catch { return []; }
    }

    /// <summary>The first recipe for <paramref name="path"/>, if a tool owns it.</summary>
    public static CleanupRecipe? RecipeFor(string path, List<CleanupRecipe>? recipes = null) =>
        (recipes ?? Bundled).FirstOrDefault(r => r.Matches(path));
}
