using System.Text.Json;
using System.Text.Json.Serialization;

namespace DiskMap.Core;

/// <summary>
/// What it costs to get a developer folder back after deleting it
/// (TASK-052). This, not size, is the decision a developer actually makes.
/// </summary>
public enum RebuildCost
{
    /// <summary>Regenerated automatically and offline the next time the tool runs.</summary>
    Free,
    /// <summary>An offline rebuild: CPU time, no network.</summary>
    Cheap,
    /// <summary>Re-downloaded from a registry or vendor.</summary>
    Networked,
    /// <summary>Re-downloaded, and the project has no lockfile: reinstalling may not reproduce what is there now.</summary>
    NetworkedUnpinned,
}

public static class RebuildCostExtensions
{
    public static string Title(this RebuildCost cost) => cost switch
    {
        RebuildCost.Free => "Free to rebuild",
        RebuildCost.Cheap => "Rebuilds offline",
        RebuildCost.Networked => "Re-downloads",
        RebuildCost.NetworkedUnpinned => "Re-downloads · no lockfile",
        _ => "Unknown",
    };

    public static string Explanation(this RebuildCost cost) => cost switch
    {
        RebuildCost.Free => "Regenerated automatically, offline, the next time the tool runs.",
        RebuildCost.Cheap => "Rebuilt from your source on the next build — takes CPU time, no network.",
        RebuildCost.Networked => "Downloaded again from a package registry on the next install.",
        RebuildCost.NetworkedUnpinned =>
            "Downloaded again on the next install — and this project has no lockfile, so the versions you get may not match what is installed now.",
        _ => "",
    };
}

public enum DeveloperCategory
{
    Dependencies,
    Caches,
    BuildArtifacts,
    Containers,
    SdksSimulators,
    Other,
}

public static class DeveloperCategoryExtensions
{
    public static string Title(this DeveloperCategory category) => category switch
    {
        DeveloperCategory.Dependencies => "Dependencies",
        DeveloperCategory.Caches => "Caches",
        DeveloperCategory.BuildArtifacts => "Build Artifacts",
        DeveloperCategory.Containers => "Containers",
        DeveloperCategory.SdksSimulators => "SDKs & Simulators",
        _ => "Other",
    };
}

public enum DeveloperEcosystem
{
    Node, Docker, Dotnet, Python, Android, Rust, Flutter, Jvm, IdeAi, Other,
}

public static class DeveloperEcosystemExtensions
{
    public static string Title(this DeveloperEcosystem ecosystem) => ecosystem switch
    {
        DeveloperEcosystem.Node => "Node.js",
        DeveloperEcosystem.Docker => "Docker",
        DeveloperEcosystem.Dotnet => ".NET / Visual Studio",
        DeveloperEcosystem.Python => "Python",
        DeveloperEcosystem.Android => "Android",
        DeveloperEcosystem.Rust => "Rust",
        DeveloperEcosystem.Flutter => "Flutter / Dart",
        DeveloperEcosystem.Jvm => "JVM / Gradle",
        DeveloperEcosystem.IdeAi => "IDE / AI",
        _ => "Other",
    };
}

/// <summary>Whether bytes are treated as reclaimable in the summary split.</summary>
public enum DeveloperReclaimability
{
    /// <summary>Safe caches / regenerable build products.</summary>
    Reclaimable,
    /// <summary>Needs judgment (deps, simulators, docker volumes).</summary>
    ReviewFirst,
    /// <summary>Prefer keep (toolchains, SDKs, protected).</summary>
    Keep,
}

public sealed record DeveloperItem(
    int NodeID,
    string DisplayName,
    string AbsolutePath,
    long Bytes,
    DeveloperCategory Category,
    DeveloperEcosystem Ecosystem,
    /// <summary>True when the path sits under a protected prefix — never offered for cleanup.</summary>
    bool IsProtected,
    DeveloperReclaimability Reclaimability,
    string WhyLarge,
    string? ProjectKey,
    string? ProjectName,
    int ModifiedDay,
    bool IsToolRoot,
    /// <summary>What getting this folder back would cost (TASK-052).</summary>
    RebuildCost RebuildCost,
    /// <summary>For dependency folders: the lockfile that pins them, if any.</summary>
    string? Lockfile,
    /// <summary>The manifest that identified the project root (TASK-051), if any.</summary>
    string? ProjectManifest,
    /// <summary>Tree node of the project root, when the item belongs to a project.</summary>
    int? ProjectNodeID,
    /// <summary>The owning tool's cleanup command, when one exists (TASK-055).</summary>
    CleanupRecipe? Recipe);

public sealed record DeveloperProject(
    string Key,
    string Name,
    string AbsolutePath,
    DeveloperEcosystem Ecosystem,
    long Bytes,
    long ReclaimableBytes,
    int ItemCount,
    int ModifiedDay,
    List<int> NodeIDs)
{
    public string Status { get; set; } = "";
    /// <summary>The manifest that makes this folder a project (TASK-051).</summary>
    public string? Manifest { get; set; }
    /// <summary>Lockfile pinning its dependencies, if it has dependency folders.</summary>
    public string? Lockfile { get; set; }
    /// <summary>Most expensive rebuild among its folders (TASK-052).</summary>
    public RebuildCost RebuildCost { get; set; } = RebuildCost.Cheap;
    /// <summary>
    /// Newest file in the project that is not generated — excluding .git
    /// and every dependency/build folder. When a person last worked on it
    /// (TASK-056). 0 = unknown.
    /// </summary>
    public int LastSourceDay { get; set; }
    public string? RepositoryPath { get; set; }
    /// <summary>(TASK-053)</summary>
    public GitState Git { get; set; } = new GitState.NotARepository();
    /// <summary>
    /// Bytes in the repository that .gitignore marks disposable (TASK-054).
    /// Null when the project is not in a repository.
    /// </summary>
    public long? IgnoredBytes { get; set; }
}

public sealed record DeveloperCategoryRollup(DeveloperCategory Category, long Bytes);
public sealed record DeveloperEcosystemRollup(DeveloperEcosystem Ecosystem, long Bytes, int ItemCount);

public sealed class DeveloperSummary
{
    public long TotalBytes { get; init; }
    public long ReclaimableBytes { get; init; }
    public long KeepBytes { get; init; }
    public int ToolCount { get; init; }
    public int ProjectCount { get; init; }
    public int ItemCount { get; init; }
    public List<DeveloperCategoryRollup> Categories { get; init; } = [];
    public List<DeveloperEcosystemRollup> Ecosystems { get; init; } = [];
    /// <summary>Projects with no source change for <see cref="StaleAfterDays"/> (TASK-056).</summary>
    public int StaleProjectCount { get; set; }
    /// <summary>Reclaimable bytes held by those stale projects — the headline.</summary>
    public long StaleReclaimableBytes { get; set; }
    /// <summary>Dependency folders with no lockfile: reinstalling may not reproduce them.</summary>
    public long UnpinnedBytes { get; set; }

    public const int StaleAfterDays = 180;

    public static readonly DeveloperSummary Empty = new();

    public double ReclaimableFraction =>
        TotalBytes > 0 ? (double)ReclaimableBytes / TotalBytes : 0;
}

public sealed record DeveloperCatalogResult(
    List<DeveloperItem> Items,
    List<DeveloperProject> Projects,
    List<DeveloperItem> Opportunities,
    DeveloperSummary Summary)
{
    public static readonly DeveloperCatalogResult EmptyResult =
        new([], [], [], DeveloperSummary.Empty);
}

/// <summary>
/// Answers project questions from the scan tree alone: which folder is the
/// project (nearest manifest), whether a lockfile exists, where the git
/// repository starts. Child names of each folder are read once and cached,
/// since many hits share ancestors.
/// </summary>
internal sealed class ProjectLocator
{
    private readonly FileTree _tree;
    private readonly HashSet<string> _manifestNames;
    private readonly string[] _manifestSuffixes;
    private readonly Dictionary<int, HashSet<string>> _childNamesCache = [];

    public ProjectLocator(FileTree tree, HashSet<string> manifestNames, string[] manifestSuffixes)
    {
        _tree = tree;
        _manifestNames = manifestNames;
        _manifestSuffixes = manifestSuffixes;
    }

    public HashSet<string> ChildNames(int id)
    {
        if (_childNamesCache.TryGetValue(id, out var cached)) return cached;
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        int child = _tree.FirstChild[id];
        while (child != -1)
        {
            names.Add(_tree.NameOf(child));
            child = _tree.NextSibling[child];
        }
        _childNamesCache[id] = names;
        return names;
    }

    /// <summary>The manifest that makes <paramref name="id"/> a project root, if any.</summary>
    public string? ManifestIn(int id)
    {
        var names = ChildNames(id);
        var hit = names.Where(n => _manifestNames.Contains(n)).Min();
        if (hit is not null) return hit;   // deterministic when several exist
        return names.Where(n => _manifestSuffixes.Any(s =>
                n.EndsWith(s, StringComparison.OrdinalIgnoreCase))).Min();
    }

    /// <summary>
    /// Nearest folder at or above <paramref name="start"/> that holds a
    /// manifest, never going above the scan root (node 0).
    /// </summary>
    public (int Id, string Manifest)? ProjectRoot(int start)
    {
        int current = start;
        for (int steps = 0; current >= 0 && steps < 64; steps++)
        {
            if (ManifestIn(current) is { } manifest) return (current, manifest);
            if (current == 0) return null;
            current = _tree.Parent[current];
        }
        return null;
    }

    /// <summary>Nearest folder at or above start containing .git (a folder or a worktree file).</summary>
    public int? RepositoryRoot(int start)
    {
        int current = start;
        for (int steps = 0; current >= 0 && steps < 64; steps++)
        {
            if (ChildNames(current).Contains(".git")) return current;
            if (current == 0) return null;
            current = _tree.Parent[current];
        }
        return null;
    }

    /// <summary>
    /// First lockfile found in <paramref name="from"/> or any folder above
    /// it, up to and including <paramref name="stopAt"/> (the repository
    /// root) or the scan root. Workspace managers keep one lockfile at top.
    /// </summary>
    public string? Lockfile(string[] candidates, int from, int? stopAt)
    {
        int current = from;
        for (int steps = 0; current >= 0 && steps < 64; steps++)
        {
            var names = ChildNames(current);
            var hit = candidates.FirstOrDefault(c => names.Contains(c));
            if (hit is not null) return hit;
            if (current == stopAt || current == 0) return null;
            current = _tree.Parent[current];
        }
        return null;
    }
}

/// <summary>
/// Classifies known developer directories from an existing scan — no
/// second walk of disk. Rules are data (developer-rules.json, embedded).
/// </summary>
public static class DeveloperCatalog
{
    private sealed class Rule
    {
        public required HashSet<string> Names { get; init; }
        public required DeveloperCategory Category { get; init; }
        public required DeveloperEcosystem Ecosystem { get; init; }
        public required DeveloperReclaimability Reclaimability { get; init; }
        public required bool IsToolRoot { get; init; }
        public required bool ProjectFromParent { get; init; }
        public required string WhyLarge { get; init; }
        public RebuildCost RebuildCost { get; init; } = RebuildCost.Cheap;
        /// <summary>Set for dependency folders whose reproducibility depends on a lockfile.</summary>
        public string? LockEcosystem { get; init; }
    }

    // JSON decode shapes — snake_case property names.
    private sealed class RuleEntry
    {
        [JsonPropertyName("names")] public List<string> Names { get; set; } = [];
        [JsonPropertyName("category")] public string Category { get; set; } = "";
        [JsonPropertyName("ecosystem")] public string Ecosystem { get; set; } = "";
        [JsonPropertyName("reclaimability")] public string Reclaimability { get; set; } = "";
        [JsonPropertyName("isToolRoot")] public bool IsToolRoot { get; set; }
        [JsonPropertyName("projectFromParent")] public bool ProjectFromParent { get; set; }
        [JsonPropertyName("whyLarge")] public string WhyLarge { get; set; } = "";
        [JsonPropertyName("rebuildCost")] public string? RebuildCost { get; set; }
        [JsonPropertyName("lockEcosystem")] public string? LockEcosystem { get; set; }
    }

    private sealed class ManifestsBlock
    {
        [JsonPropertyName("names")] public List<string> Names { get; set; } = [];
        [JsonPropertyName("suffixes")] public List<string> Suffixes { get; set; } = [];
    }

    private sealed class RuleFile
    {
        [JsonPropertyName("rules")] public List<RuleEntry> Rules { get; set; } = [];
        [JsonPropertyName("manifests")] public ManifestsBlock? Manifests { get; set; }
        [JsonPropertyName("lockfiles")] public Dictionary<string, JsonElement>? Lockfiles { get; set; }
    }

    private static readonly Lazy<RuleFile?> RuleFileLazy = new(LoadRuleFile);
    private static RuleFile? File_ => RuleFileLazy.Value;

    private static RuleFile? LoadRuleFile()
    {
        var assembly = typeof(DeveloperCatalog).Assembly;
        var resourceName = assembly.GetManifestResourceNames()
            .FirstOrDefault(n => n.EndsWith("developer-rules.json", StringComparison.OrdinalIgnoreCase));
        if (resourceName is null) return null;
        using var stream = assembly.GetManifestResourceStream(resourceName);
        if (stream is null) return null;
        try
        {
            return JsonSerializer.Deserialize<RuleFile>(stream, new JsonSerializerOptions
            {
                ReadCommentHandling = JsonCommentHandling.Skip,
            });
        }
        catch { return null; }
    }

    internal static HashSet<string> ManifestNames =>
        new(File_?.Manifests?.Names ?? [], StringComparer.OrdinalIgnoreCase);
    internal static string[] ManifestSuffixes => File_?.Manifests?.Suffixes.ToArray() ?? [];

    internal static Dictionary<string, string[]> LockfilesByEcosystem
    {
        get
        {
            var map = new Dictionary<string, string[]>();
            if (File_?.Lockfiles is not { } blocks) return map;
            foreach (var (key, element) in blocks)
            {
                if (element.ValueKind == JsonValueKind.Array)
                    map[key] = element.EnumerateArray()
                        .Select(e => e.GetString() ?? "").Where(s => s.Length > 0).ToArray();
            }
            return map;
        }
    }

    private static List<Rule> LoadRules(byte[]? data = null)
    {
        RuleFile? file;
        if (data is not null)
        {
            try
            {
                file = JsonSerializer.Deserialize<RuleFile>(data, new JsonSerializerOptions
                {
                    ReadCommentHandling = JsonCommentHandling.Skip,
                });
            }
            catch { return []; }
        }
        else file = File_;
        if (file is null) return [];
        return file.Rules.Select(entry =>
        {
            if (!TryEnum<DeveloperCategory>(entry.Category, out var category)
                || !TryEnum<DeveloperEcosystem>(entry.Ecosystem, out var ecosystem)
                || !TryEnum<DeveloperReclaimability>(entry.Reclaimability, out var reclaimability))
                return null;
            return new Rule
            {
                Names = new HashSet<string>(entry.Names, StringComparer.OrdinalIgnoreCase),
                Category = category,
                Ecosystem = ecosystem,
                Reclaimability = reclaimability,
                IsToolRoot = entry.IsToolRoot,
                ProjectFromParent = entry.ProjectFromParent,
                WhyLarge = entry.WhyLarge,
                RebuildCost = entry.RebuildCost is { } rc && TryEnum<RebuildCost>(rc, out var cost)
                    ? cost : RebuildCost.Cheap,
                LockEcosystem = entry.LockEcosystem,
            };
        }).Where(r => r is not null).Cast<Rule>().ToList();

        static bool TryEnum<T>(string value, out T result) where T : struct
        {
            // "sdksSimulators" → SdksSimulators, "ideAI" → IdeAi, "networkedUnpinned" → NetworkedUnpinned
            if (Enum.TryParse(value, ignoreCase: true, out result)) return true;
            result = default;
            return false;
        }
    }

    /// <summary>For tests: how many rules the bundled file produced.</summary>
    internal static int LoadedRuleCount => LoadRules().Count;

    private static readonly Lazy<Dictionary<string, Rule>> NameToRuleLazy = new(() =>
    {
        var map = new Dictionary<string, Rule>(StringComparer.OrdinalIgnoreCase);
        foreach (var rule in LoadRules())
            foreach (var name in rule.Names)
                map[name] = rule;   // a later rule wins for a duplicate name
        return map;
    });

    public static DeveloperCatalogResult Build(
        FileTree tree,
        string rootPath,
        long[] totals,
        int limit = 500,
        int today = 0)
    {
        if (totals.Length != tree.Count) return DeveloperCatalogResult.EmptyResult;
        if (today == 0) today = AgeMap.Today();
        var nameToRule = NameToRuleLazy.Value;

        var hits = new List<(int Id, Rule Rule, long Bytes, string Path, string Name)>();
        for (int i = 0; i < tree.Count; i++)
        {
            if (!tree.IsDirectory[i]) continue;
            string name = tree.NameOf(i);
            if (!nameToRule.TryGetValue(name, out var rule)) continue;
            long bytes = totals[i];
            if (bytes <= 0) continue;
            string path = tree.PathOf(i, rootPath);
            if (!IsPlausibleHit(name, path, rule)) continue;
            if (StorageClassifier.IsSystemHolding(path)) continue;
            // A folder inside an installed app's directory is part of that
            // app, not a developer artifact — node_modules inside an
            // Electron app under Program Files, a site-packages bundled
            // with a product. Removing it breaks the app.
            if (CleanupQueue.IsInsideInstalledApp(path)) continue;
            hits.Add((i, rule, bytes, path, name));
        }
        // Biggest first; on a tie the outer folder first — a parent holding
        // only its matched child (Android -> Android\Sdk) has the same bytes,
        // and keeping the child first would count those bytes twice.
        hits.Sort((a, b) => b.Bytes != a.Bytes
            ? b.Bytes.CompareTo(a.Bytes)
            : a.Path.Length.CompareTo(b.Path.Length));

        // Prefer outer directories: skip a hit whose ancestor is already kept.
        var kept = new List<(int Id, Rule Rule, long Bytes, string Path, string Name)>();
        var keptIds = new List<int>();
        foreach (var hit in hits)
        {
            bool inside = false;
            for (int ancestor = tree.Parent[hit.Id]; ancestor >= 0; ancestor = tree.Parent[ancestor])
            {
                if (keptIds.Contains(ancestor)) { inside = true; break; }
            }
            if (inside) continue;
            kept.Add(hit);
            keptIds.Add(hit.Id);
            if (kept.Count >= limit) break;
        }

        var items = new List<DeveloperItem>(kept.Count);
        var locator = new ProjectLocator(tree, ManifestNames, ManifestSuffixes);
        var lockfiles = LockfilesByEcosystem;
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
            .TrimEnd('\\');

        foreach (var hit in kept)
        {
            bool isProtected = CleanupQueue.IsExcludedPath(hit.Path);
            var reclaim = hit.Rule.Reclaimability;
            if (isProtected) reclaim = DeveloperReclaimability.Keep;
            var ecosystem = RefineEcosystem(hit.Rule, hit.Path, hit.Name);
            var category = RefineCategory(hit.Rule, hit.Path, hit.Name);

            string? projectKey = null, projectName = null, projectManifest = null;
            int? projectRootId = null;
            if (hit.Rule.ProjectFromParent && tree.Parent[hit.Id] >= 0)
            {
                int parentId = tree.Parent[hit.Id];
                // The project is the nearest folder with a manifest, not
                // simply the parent — which was wrong for monorepos and
                // nested packages. Falls back to the parent when no
                // manifest is found anywhere above.
                var located = locator.ProjectRoot(parentId);
                // A stray ~\package.json (from an `npm init` in the
                // profile folder) must not make home the project of every
                // build folder on the disk.
                if (located is { } found
                    && tree.PathOf(found.Id, rootPath).TrimEnd('\\')
                        .Equals(home, StringComparison.OrdinalIgnoreCase))
                {
                    located = null;
                }
                int rootId = located?.Id ?? parentId;
                projectRootId = rootId;
                projectManifest = located?.Manifest;
                projectKey = tree.PathOf(rootId, rootPath);
                projectName = tree.NameOf(rootId);
            }

            // Dependency folders are only reproducible if pinned.
            var rebuildCost = hit.Rule.RebuildCost;
            string? lockfile = null;
            if (hit.Rule.LockEcosystem is { } ecoKey
                && lockfiles.TryGetValue(ecoKey, out var candidates))
            {
                int start = projectRootId ?? (tree.Parent[hit.Id] >= 0 ? tree.Parent[hit.Id] : hit.Id);
                var repo = locator.RepositoryRoot(start);
                lockfile = locator.Lockfile(candidates, start, repo);
                if (lockfile is null) rebuildCost = RebuildCost.NetworkedUnpinned;
            }

            string display = DisplayTitle(hit.Name);
            items.Add(new DeveloperItem(
                NodeID: hit.Id,
                DisplayName: display,
                AbsolutePath: hit.Path,
                Bytes: hit.Bytes,
                Category: category,
                Ecosystem: ecosystem,
                IsProtected: isProtected,
                Reclaimability: reclaim,
                WhyLarge: hit.Rule.WhyLarge,
                ProjectKey: projectKey,
                ProjectName: projectName,
                ModifiedDay: tree.ModifiedDay[hit.Id],
                IsToolRoot: hit.Rule.IsToolRoot || projectKey is null,
                RebuildCost: rebuildCost,
                Lockfile: lockfile,
                ProjectManifest: projectManifest,
                ProjectNodeID: projectRootId,
                Recipe: CleanupRecipes.RecipeFor(hit.Path)));
        }

        items.Sort((a, b) => b.Bytes.CompareTo(a.Bytes));
        var projects = BuildProjects(items);
        EnrichProjects(projects, items, tree, rootPath, totals, today, locator);
        var opportunities = items
            .Where(i => i.Reclaimability != DeveloperReclaimability.Keep && !i.IsProtected)
            .Take(12).ToList();
        var summary = Summarize(items, projects);
        var stale = projects.Where(p =>
            p.LastSourceDay > 0 && today - p.LastSourceDay >= DeveloperSummary.StaleAfterDays).ToList();
        summary.StaleProjectCount = stale.Count;
        summary.StaleReclaimableBytes = stale.Sum(p => p.ReclaimableBytes);
        summary.UnpinnedBytes = items
            .Where(i => i.RebuildCost == RebuildCost.NetworkedUnpinned).Sum(i => i.Bytes);
        return new DeveloperCatalogResult(items, projects, opportunities, summary);
    }

    private static bool IsPlausibleHit(string name, string path, Rule rule)
    {
        string lower = path.ToLowerInvariant();
        string n = name.ToLowerInvariant();
        switch (n)
        {
            case "sdk":
                return lower.Contains("android");
            case "android":
                return lower.Contains("android") || lower.Contains("\\appdata\\");
            case "build" or "dist" or "out" or "bin" or "obj" or "publish":
                // Require a project context — these names are too generic to
                // flag in arbitrary locations (C:\Tools\bin is not build
                // output). The macOS version checks the path tail; here we
                // additionally require the parent chain to hold a manifest,
                // decided later by ProjectLocator — reject only obvious
                // non-dev spots.
                return !lower.Contains("\\windows\\")
                    && !lower.Contains("\\program files")
                    && !lower.Contains("\\programdata\\");
            case "env":
                // ".env" is a config FILE name as often as a venv dir; bare
                // "env" only counts when the parent looks like a project.
                return rule.ProjectFromParent
                    && !lower.Contains("\\windows\\") && !lower.Contains("\\programdata\\");
            case "windows.old":
                return true;
            case "nvm":
                return lower.Contains("nvm") && (lower.Contains("\\appdata\\") || lower.Contains("program"));
            default:
                return true;
        }
    }

    private static DeveloperEcosystem RefineEcosystem(Rule rule, string path, string name)
    {
        string lower = path.ToLowerInvariant();
        string n = name.ToLowerInvariant();
        if (n is "build" or "dist" or "out" or ".build" or ".next" or ".nuxt")
        {
            if (lower.Contains("node_modules") || lower.Contains("\\.next") || lower.Contains("package.json"))
                return DeveloperEcosystem.Node;
            if (lower.Contains("\\target\\") || lower.Contains("cargo.toml")) return DeveloperEcosystem.Rust;
            if (lower.Contains("obj") || lower.Contains("\\bin") || lower.Contains(".csproj")
                || lower.Contains(".sln")) return DeveloperEcosystem.Dotnet;
        }
        if (n == "sdk" || n == "android" || lower.Contains("android")) return DeveloperEcosystem.Android;
        if (lower.Contains("docker")) return DeveloperEcosystem.Docker;
        return rule.Ecosystem;
    }

    private static DeveloperCategory RefineCategory(Rule rule, string path, string name)
    {
        string lower = path.ToLowerInvariant();
        if (name.Equals("DockerDesktop", StringComparison.OrdinalIgnoreCase)
            || lower.Contains("\\appdata\\local\\docker"))
            return DeveloperCategory.Containers;
        return rule.Category;
    }

    private static string DisplayTitle(string name) => name.ToLowerInvariant() switch
    {
        ".npm" or "npm-cache" or "_cacache" => "npm cache",
        ".nuget" => "NuGet cache",
        ".vs" => "Visual Studio cache",
        ".docker" or "dockerdesktop" => "Docker data",
        "windows.old" => "Windows.old",
        _ => name,
    };

    private static List<DeveloperProject> BuildProjects(List<DeveloperItem> items)
    {
        var groups = new Dictionary<string, (
            string Name, DeveloperEcosystem Eco, long Bytes, long Reclaim,
            int Count, int Day, List<int> Nodes)>();
        foreach (var item in items)
        {
            if (item.ProjectKey is not { } key || item.ProjectName is not { } name) continue;
            if (!groups.TryGetValue(key, out var g)) g = (name, item.Ecosystem, 0, 0, 0, 0, []);
            g.Bytes += item.Bytes;
            if (item.Reclaimability != DeveloperReclaimability.Keep) g.Reclaim += item.Bytes;
            g.Count += 1;
            g.Day = Math.Max(g.Day, item.ModifiedDay);
            g.Nodes.Add(item.NodeID);
            if (g.Eco == DeveloperEcosystem.Other) g.Eco = item.Ecosystem;
            groups[key] = g;
        }
        var projects = groups.Select(kv =>
        {
            var (key, g) = (kv.Key, kv.Value);
            string status;
            if (g.Reclaim >= g.Bytes / 2) status = "Has reclaimable";
            else if (g.Day > 0) status = AgeLabel(g.Day);
            else status = "Active unknown";
            return new DeveloperProject(key, g.Name, key, g.Eco, g.Bytes, g.Reclaim,
                g.Count, g.Day, g.Nodes) { Status = status };
        }).OrderByDescending(p => p.Bytes).ToList();
        return projects;
    }

    /// <summary>
    /// What a developer needs to decide, per project (TASK-051..054/056).
    /// Git state and ignored bytes are computed once per repository.
    /// </summary>
    private static void EnrichProjects(
        List<DeveloperProject> projects,
        List<DeveloperItem> items,
        FileTree tree,
        string rootPath,
        long[] totals,
        int today,
        ProjectLocator locator)
    {
        var itemsByProject = items.Where(i => i.ProjectKey is not null)
            .GroupBy(i => i.ProjectKey!).ToDictionary(g => g.Key, g => g.ToList());
        var generatedNames = new HashSet<string>(NameToRuleLazy.Value.Keys, StringComparer.OrdinalIgnoreCase);
        var gitCache = new Dictionary<int, (string Path, GitState State, long Ignored)>();

        foreach (var project in projects)
        {
            if (!itemsByProject.TryGetValue(project.Key, out var members)) continue;
            if (members.Select(m => m.ProjectNodeID).FirstOrDefault(n => n is not null) is not { } rootId)
                continue;
            project.Manifest = members.Select(m => m.ProjectManifest).FirstOrDefault(m => m is not null);
            project.Lockfile = members.Select(m => m.Lockfile).FirstOrDefault(m => m is not null);
            // Worst rebuild cost wins — enum order is the cost order.
            project.RebuildCost = members.Select(m => m.RebuildCost).DefaultIfEmpty(RebuildCost.Cheap).Max();
            var skip = members.Select(m => m.NodeID).ToHashSet();
            project.LastSourceDay = LastSourceDay(tree, rootId, skip, generatedNames);
            if (locator.RepositoryRoot(rootId) is { } repoId)
            {
                if (!gitCache.TryGetValue(repoId, out var repo))
                {
                    string path = tree.PathOf(repoId, rootPath);
                    long ignored = GitIgnoreRules.IgnoredBytes(tree, repoId, path, totals).IgnoredBytes;
                    repo = (path, GitInspector.Inspect(path), ignored);
                    gitCache[repoId] = repo;
                }
                project.RepositoryPath = repo.Path;
                project.Git = repo.State;
                project.IgnoredBytes = repo.Ignored;
            }
            int age = project.LastSourceDay > 0 ? today - project.LastSourceDay : 0;
            if (project.LastSourceDay > 0 && age >= DeveloperSummary.StaleAfterDays)
                project.Status = $"Untouched {age / 30} months";
        }
    }

    /// <summary>
    /// Newest file under a project that a person could have edited: skips
    /// .git, the project's own dependency/build folders, and any folder a
    /// developer rule names (a nested node_modules below the item limit).
    /// </summary>
    internal static int LastSourceDay(
        FileTree tree, int projectId, HashSet<int> skipping, HashSet<string> generatedNames)
    {
        int newest = 0;
        var stack = new Stack<int>();
        stack.Push(projectId);
        while (stack.Count > 0)
        {
            int id = stack.Pop();
            int child = tree.FirstChild[id];
            while (child != -1)
            {
                if (tree.IsDirectory[child])
                {
                    string lowered = tree.NameOf(child);
                    if (!skipping.Contains(child) && !lowered.Equals(".git", StringComparison.OrdinalIgnoreCase)
                        && !generatedNames.Contains(lowered))
                    {
                        stack.Push(child);
                    }
                }
                else newest = Math.Max(newest, tree.ModifiedDay[child]);
                child = tree.NextSibling[child];
            }
        }
        return newest;
    }

    private static string AgeLabel(int modifiedDay)
    {
        if (modifiedDay <= 0) return "Unknown activity";
        int age = Math.Max(0, AgeMap.Today() - modifiedDay);
        if (age < 30) return "Recently active";
        if (age < 180) return "Moderately active";
        if (age < 365) return "Quiet";
        return "Stale";
    }

    private static DeveloperSummary Summarize(List<DeveloperItem> items, List<DeveloperProject> projects)
    {
        long total = 0, reclaim = 0, keep = 0;
        var catBytes = new Dictionary<DeveloperCategory, long>();
        var ecoBytes = new Dictionary<DeveloperEcosystem, long>();
        var ecoCount = new Dictionary<DeveloperEcosystem, int>();
        var toolIds = new HashSet<int>();

        foreach (var item in items)
        {
            total += item.Bytes;
            switch (item.Reclaimability)
            {
                case DeveloperReclaimability.Reclaimable or DeveloperReclaimability.ReviewFirst:
                    reclaim += item.Bytes; break;
                case DeveloperReclaimability.Keep:
                    keep += item.Bytes; break;
            }
            catBytes[item.Category] = catBytes.GetValueOrDefault(item.Category) + item.Bytes;
            ecoBytes[item.Ecosystem] = ecoBytes.GetValueOrDefault(item.Ecosystem) + item.Bytes;
            ecoCount[item.Ecosystem] = ecoCount.GetValueOrDefault(item.Ecosystem) + 1;
            if (item.IsToolRoot) toolIds.Add(item.NodeID);
        }

        var categories = Enum.GetValues<DeveloperCategory>()
            .Select(c => new DeveloperCategoryRollup(c, catBytes.GetValueOrDefault(c)))
            .Where(r => r.Bytes > 0).ToList();
        var ecosystems = ecoBytes
            .Select(kv => new DeveloperEcosystemRollup(kv.Key, kv.Value, ecoCount.GetValueOrDefault(kv.Key)))
            .OrderByDescending(e => e.Bytes).ToList();

        return new DeveloperSummary
        {
            TotalBytes = total, ReclaimableBytes = reclaim, KeepBytes = keep,
            ToolCount = toolIds.Count, ProjectCount = projects.Count, ItemCount = items.Count,
            Categories = categories, Ecosystems = ecosystems,
        };
    }
}
