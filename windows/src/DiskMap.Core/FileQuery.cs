namespace DiskMap.Core;

/// <summary>
/// A small search language over one scan — the Windows port of the macOS
/// FileQuery (TASK-059), shared by the Find box, chips and the CLI:
///
///     ext:mp4 size>500MB age>1y in:downloads
///     name:*.log size>100MB -archive
///
/// Every field is already in FileTree; nothing touches the disk. Name
/// tests run once per *distinct* name and `in:`/`path:` filters are one
/// forward pass over parent links, so no path is built for any node that
/// is not displayed.
/// </summary>
public sealed class FileQuery : IEquatable<FileQuery>
{
    public enum Comparison { Greater, GreaterOrEqual, Less, LessOrEqual }

    public enum NodeType { Files, Folders, Any }

    /// <summary>Named locations `in:` accepts (Windows names; "library" maps to AppData).</summary>
    public enum Place { Downloads, Desktop, Documents, AppData, Caches }

    public enum Flag { Duplicate, HardLink, Cloud }

    public readonly record struct Bound(Comparison Comparison, long Value);

    /// <summary>Case-insensitive substrings every name must contain.</summary>
    public List<string> Words { get; } = [];
    /// <summary>Case-insensitive substrings no name may contain (<c>-word</c>).</summary>
    public List<string> ExcludedWords { get; } = [];
    /// <summary><c>name:</c> patterns — globs when they contain * ? [, substrings otherwise.</summary>
    public List<string> NamePatterns { get; } = [];
    /// <summary>Lowercased, without the dot. Any may match (<c>ext:mp4,mov</c>).</summary>
    public List<string> Extensions { get; } = [];
    /// <summary>File-type category ids from file-type-categories.json, plus "media".</summary>
    public List<string> Kinds { get; } = [];
    public List<Bound> SizeBounds { get; } = [];
    /// <summary>Days since last modification.</summary>
    public List<Bound> AgeBounds { get; } = [];
    /// <summary>Absolute folder paths (<c>path:</c>); any may contain the match.</summary>
    public List<string> Paths { get; } = [];
    public List<Place> Places { get; } = [];
    public List<Flag> Flags { get; } = [];
    public NodeType? ExplicitType { get; set; }

    /// <summary>
    /// Size, age, extension, kind and file flags describe files. Folder
    /// totals nest, so <c>size&gt;1GB</c> over folders would list every
    /// ancestor of one big file; asking for folders takes an explicit
    /// <c>type:folder</c>.
    /// </summary>
    public NodeType EffectiveType => ExplicitType
        ?? (SizeBounds.Count > 0 || AgeBounds.Count > 0 || Extensions.Count > 0
            || Kinds.Count > 0 || Flags.Count > 0 ? NodeType.Files : NodeType.Any);

    public bool IsEmpty => Equals(new FileQuery());

    /// <summary>True when the text used any key: or comparison — not just bare words.</summary>
    public bool IsStructured
    {
        get
        {
            var plain = new FileQuery();
            plain.Words.AddRange(Words);
            return !Equals(plain);
        }
    }

    public bool Equals(FileQuery? other) =>
        other is not null
        && Words.SequenceEqual(other.Words) && ExcludedWords.SequenceEqual(other.ExcludedWords)
        && NamePatterns.SequenceEqual(other.NamePatterns) && Extensions.SequenceEqual(other.Extensions)
        && Kinds.SequenceEqual(other.Kinds) && SizeBounds.SequenceEqual(other.SizeBounds)
        && AgeBounds.SequenceEqual(other.AgeBounds) && Paths.SequenceEqual(other.Paths)
        && Places.SequenceEqual(other.Places) && Flags.SequenceEqual(other.Flags)
        && ExplicitType == other.ExplicitType;

    public override bool Equals(object? obj) => obj is FileQuery q && Equals(q);
    public override int GetHashCode() => Words.Count ^ Extensions.Count ^ SizeBounds.Count;

    // MARK: Parsing

    public readonly record struct Problem(string Token, string Message);
    public readonly record struct Parsed(FileQuery Query, List<Problem> Problems);

    private static readonly HashSet<string> Keys =
        ["ext", "name", "path", "in", "is", "type", "kind", "size", "age"];

    /// <summary><paramref name="home"/> expands ~; <paramref name="root"/> anchors relative path: values.</summary>
    public static Parsed Parse(string text, string home, string root)
    {
        var query = new FileQuery();
        var problems = new List<Problem>();
        foreach (var token in Tokenize(text))
        {
            if (Apply(token, query, home, root) is { } problem)
                problems.Add(new Problem(token, problem));
        }
        return new Parsed(query, problems);
    }

    /// <summary>Returns a problem message, or null when the token applied.</summary>
    private static string? Apply(string raw, FileQuery query, string home, string root)
    {
        string token = Unquoted(raw);
        string lower = token.ToLowerInvariant();

        foreach (var key in new[] { "size", "age" })
        {
            if (!lower.StartsWith(key)) continue;
            var rest = lower[key.Length..];
            if (rest.StartsWith(':')) rest = rest[1..];
            if (rest.Length == 0 || (rest[0] != '>' && rest[0] != '<'))
            {
                if (lower.StartsWith(key + ":"))
                    return key == "size"
                        ? "Use size>500MB or size<10KB"
                        : "Use age>1y (older than) or age<7d (newer than)";
                continue;   // "sizeable", "ageing": ordinary words
            }
            var comparison = rest.StartsWith(">=") ? Comparison.GreaterOrEqual
                : rest.StartsWith("<=") ? Comparison.LessOrEqual
                : rest[0] == '>' ? Comparison.Greater : Comparison.Less;
            string valueText = rest[(comparison is Comparison.GreaterOrEqual or Comparison.LessOrEqual ? 2 : 1)..];
            if (key == "size")
            {
                if (HumanUnits.Bytes(valueText) is not { } bytes)
                    return "Size needs a value like 500MB, 2GB or 1.5TB";
                query.SizeBounds.Add(new Bound(comparison, bytes));
            }
            else
            {
                if (HumanUnits.Days(valueText) is not { } days)
                    return "Age needs a value like 30d, 2w, 6m or 1y";
                query.AgeBounds.Add(new Bound(comparison, days));
            }
            return null;
        }

        int colon = token.IndexOf(':');
        if (colon > 0)
        {
            string key = token[..colon].ToLowerInvariant();
            string value = Unquoted(token[(colon + 1)..]);
            if (Keys.Contains(key))
            {
                if (value.Length == 0) return $"{key}: needs a value";
                return ApplyKey(key, value, query, home, root);
            }
        }

        if (lower.StartsWith('-') && lower.Length > 1) query.ExcludedWords.Add(lower[1..]);
        else if (lower.Length > 0) query.Words.Add(lower);
        return null;
    }

    private static string? ApplyKey(string key, string value, FileQuery query, string home, string root)
    {
        string lower = value.ToLowerInvariant();
        switch (key)
        {
            case "ext":
            {
                var list = lower.Split(',')
                    .Select(e => e.Trim().TrimStart('.'))
                    .Where(e => e.Length > 0).ToList();
                if (list.Count == 0) return "ext: needs an extension, like ext:mp4";
                query.Extensions.AddRange(list);
                return null;
            }
            case "name":
                query.NamePatterns.Add(lower);
                return null;
            case "kind":
            {
                var known = KindExtensions.Keys;
                var list = lower.Split(',').Select(k => k.Trim()).Where(k => k.Length > 0).ToList();
                var bad = list.FirstOrDefault(k => !known.Contains(k));
                if (bad is not null)
                    return $"Unknown kind \"{bad}\" — try {string.Join(", ", known.OrderBy(k => k))}";
                query.Kinds.AddRange(list);
                return null;
            }
            case "type":
                switch (lower)
                {
                    case "file" or "files" or "f": query.ExplicitType = NodeType.Files; return null;
                    case "dir" or "dirs" or "folder" or "folders" or "d":
                        query.ExplicitType = NodeType.Folders; return null;
                    case "any" or "all": query.ExplicitType = NodeType.Any; return null;
                    default: return "type: is file, folder or any";
                }
            case "in":
                var place = ParsePlace(lower);
                if (place is null)
                    return "in: is one of downloads, desktop, documents, appdata, caches";
                query.Places.Add(place.Value);
                return null;
            case "is":
                var flag = lower switch
                {
                    "duplicate" => (Flag?)Flag.Duplicate,
                    "hardlink" or "hard-link" or "hardlinked" => Flag.HardLink,
                    "cloud" or "ondemand" or "placeholder" => Flag.Cloud,
                    _ => null,
                };
                if (flag is null) return "is: is one of duplicate, hardlink, cloud";
                query.Flags.Add(flag.Value);
                return null;
            case "path":
                query.Paths.Add(AbsolutePath(value, home, root));
                return null;
            default:
                return $"Unknown key {key}:";
        }
    }

    private static Place? ParsePlace(string value) => value switch
    {
        "downloads" => Place.Downloads,
        "desktop" => Place.Desktop,
        "documents" => Place.Documents,
        "appdata" or "library" => Place.AppData,
        "caches" => Place.Caches,
        _ => null,
    };

    private static string AbsolutePath(string value, string home, string root)
    {
        string path = Environment.ExpandEnvironmentVariables(value.Trim());
        if (path is "~" or "~\\" or "~/") path = home;
        else if (path.StartsWith("~/") || path.StartsWith("~\\"))
            path = Path.Combine(home, path[2..]);
        else if (path.StartsWith('\\'))   // rooted on the scan drive
            path = (Path.GetPathRoot(root) ?? "C:").TrimEnd('\\') + path;
        else if (!(path.Length >= 2 && path[1] == ':'))
            path = Path.Combine(root, path);
        return Path.GetFullPath(path).TrimEnd('\\');
    }

    /// <summary>Whitespace-separated, with double quotes grouping (<c>path:"C:\My Stuff"</c>).</summary>
    public static List<string> Tokenize(string text)
    {
        var tokens = new List<string>();
        var current = new System.Text.StringBuilder();
        bool inQuotes = false;
        foreach (char c in text)
        {
            if (c == '"') { inQuotes = !inQuotes; current.Append(c); }
            else if (char.IsWhiteSpace(c) && !inQuotes)
            {
                if (current.Length > 0) { tokens.Add(current.ToString()); current.Clear(); }
            }
            else current.Append(c);
        }
        if (current.Length > 0) tokens.Add(current.ToString());
        return tokens;
    }

    private static string Unquoted(string text) => text.Replace("\"", "");

    /// <summary>Adds token to text, or removes it when present — a chip is exactly this.</summary>
    public static string Toggling(string token, string text)
    {
        var tokens = Tokenize(text);
        var existing = tokens.FirstOrDefault(t =>
            t.Equals(token, StringComparison.OrdinalIgnoreCase));
        return existing is not null
            ? string.Join(' ', tokens.Where(t => !t.Equals(token, StringComparison.OrdinalIgnoreCase)))
            : string.Join(' ', tokens.Append(token));
    }

    public static bool ContainsToken(string token, string text) =>
        Tokenize(text).Any(t => t.Equals(token, StringComparison.OrdinalIgnoreCase));

    // MARK: Description

    /// <summary>
    /// Plain-language pieces of what the query means, for display beside it
    /// ("Files · larger than 500 MB · in Downloads").
    /// </summary>
    public List<string> Describe()
    {
        var parts = new List<string>
        {
            EffectiveType switch
            {
                NodeType.Files => "Files",
                NodeType.Folders => "Folders",
                _ => "Files and folders",
            },
        };
        foreach (var bound in SizeBounds)
        {
            string size = HumanUnits.Format(bound.Value);
            parts.Add(bound.Comparison switch
            {
                Comparison.Greater => $"larger than {size}",
                Comparison.GreaterOrEqual => $"at least {size}",
                Comparison.Less => $"smaller than {size}",
                _ => $"at most {size}",
            });
        }
        foreach (var bound in AgeBounds)
        {
            string age = DescribeDays(bound.Value);
            parts.Add(bound.Comparison is Comparison.Greater or Comparison.GreaterOrEqual
                ? $"untouched for {age}+" : $"changed in the last {age}");
        }
        if (Extensions.Count > 0) parts.Add(string.Join(" or ", Extensions.Select(e => "." + e)));
        if (Kinds.Count > 0) parts.Add(string.Join(" or ", Kinds.Select(KindLabel)));
        foreach (var pattern in NamePatterns) parts.Add($"named {pattern}");
        foreach (var word in Words) parts.Add($"name contains “{word}”");
        foreach (var word in ExcludedWords) parts.Add($"not “{word}”");
        var placeNames = Places.Select(p => p switch
            {
                Place.Caches => "caches",
                Place.AppData => "AppData",
                _ => p.ToString(),
            }).Concat(Paths).ToList();
        if (placeNames.Count > 0) parts.Add("in " + string.Join(" or ", placeNames));
        foreach (var flag in Flags)
        {
            parts.Add(flag switch
            {
                Flag.Duplicate => "duplicated",
                Flag.HardLink => "hard-linked",
                _ => "cloud-only",
            });
        }
        return parts;
    }

    private static string DescribeDays(long days)
    {
        static string Unit(long n, string word) => $"{n} {word}{(n == 1 ? "" : "s")}";
        if (days >= 365 && days % 365 == 0) return Unit(days / 365, "year");
        if (days >= 30 && days % 30 == 0) return Unit(days / 30, "month");
        if (days >= 7 && days % 7 == 0) return Unit(days / 7, "week");
        return Unit(days, "day");
    }

    // MARK: Kinds

    /// <summary>Category id → extensions, from the same JSON as the type charts.</summary>
    private static readonly Lazy<Dictionary<string, HashSet<string>>> KindExtensionsLazy = new(() =>
    {
        var map = FileTypes.Categories.ToDictionary(
            c => c.Id, c => new HashSet<string>(c.Extensions, StringComparer.OrdinalIgnoreCase),
            StringComparer.OrdinalIgnoreCase);
        map["media"] = new HashSet<string>(
            (map.GetValueOrDefault("video") ?? []).Concat(map.GetValueOrDefault("audio") ?? [])
                .Concat(map.GetValueOrDefault("image") ?? []),
            StringComparer.OrdinalIgnoreCase);
        return map;
    });
    private static Dictionary<string, HashSet<string>> KindExtensions => KindExtensionsLazy.Value;

    private static string KindLabel(string id) =>
        id == "media" ? "Media" : FileTypes.LabelOf(id);

    // MARK: Running a query

    public enum Sort { Largest, Oldest, Newest }

    /// <summary>Context the matcher needs: duplicate ids (if found yet), today's day number.</summary>
    public sealed record Context(HashSet<int>? DuplicateFileIDs = null, int Today = 0)
    {
        public int EffectiveToday => Today > 0 ? Today : AgeMap.Today();
    }

    public sealed record Result(
        /// <summary>The first `limit` matches in sort order.</summary>
        List<int> Ids,
        int MatchCount,
        /// <summary>Bytes in all matches — a folder inside a matched folder counts once.</summary>
        long MatchedBytes,
        /// <summary>Things the query asked for that this scan cannot answer.</summary>
        List<string> Notes,
        bool WasCancelled)
    {
        public static readonly Result Empty = new([], 0, 0, [], false);
    }

    public Result Run(
        FileTree tree,
        string rootPath,
        long[] totals,
        Context context,
        Sort sort = Sort.Largest,
        int limit = 500,
        Func<bool>? isCancelled = null)
    {
        isCancelled ??= () => false;
        if (tree.Count <= 1 || totals.Length != tree.Count) return Result.Empty;
        var notes = new List<string>();
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        int today = context.EffectiveToday;

        // Places: resolve to tree nodes once, mark descendants in one
        // forward pass (parent[i] < i) — no paths built.
        var placeRoots = new HashSet<int>();
        bool wantsCaches = false;
        var placePaths = new List<string>(Paths);
        foreach (var place in Places)
        {
            switch (place)
            {
                case Place.Caches: wantsCaches = true; break;
                case Place.AppData:
                    placePaths.Add(Path.Combine(home, "AppData")); break;
                default:
                    placePaths.Add(Path.Combine(home, place.ToString())); break;
            }
        }
        foreach (var path in placePaths)
        {
            var lookup = NodeAt(path, tree, rootPath);
            switch (lookup.Kind)
            {
                case NodeLookupKind.Found: placeRoots.Add(lookup.Id); break;
                case NodeLookupKind.Outside: notes.Add($"{path} is outside this scan"); break;
                case NodeLookupKind.Missing: notes.Add($"{path} isn't in this scan"); break;
            }
        }
        bool hasPlaces = placePaths.Count > 0 || wantsCaches;
        bool[]? inPlace = null;
        if (hasPlaces)
        {
            var cacheName = new byte[tree.NameTable.Count];  // 0 unknown, 1 yes, 2 no
            inPlace = new bool[tree.Count];
            inPlace[0] = placeRoots.Contains(0);
            for (int index = 1; index < tree.Count; index++)
            {
                int parentId = tree.Parent[index];
                bool hit = (parentId >= 0 && parentId < index && inPlace[parentId])
                    || placeRoots.Contains(index);
                if (!hit && wantsCaches && tree.IsDirectory[index])
                {
                    int nameId = tree.NameIndex[index];
                    if (cacheName[nameId] == 0)
                        cacheName[nameId] = IsCacheName(tree.NameTable[nameId]) ? (byte)1 : (byte)2;
                    hit = cacheName[nameId] == 1;
                }
                inPlace[index] = hit;
            }
        }

        if (Flags.Contains(Flag.Duplicate) && context.DuplicateFileIDs is null)
            notes.Add("Duplicates haven't been searched in this scan yet");

        // Name predicates, evaluated once per distinct name.
        var kindSet = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var k in Kinds)
            if (KindExtensions.TryGetValue(k, out var exts))
                kindSet.UnionWith(exts);
        bool usesName = Words.Count > 0 || ExcludedWords.Count > 0 || NamePatterns.Count > 0
            || Extensions.Count > 0 || kindSet.Count > 0;
        var nameVerdict = usesName ? new byte[tree.NameTable.Count] : null;

        var type = EffectiveType;
        bool foldersCanMatch = type != NodeType.Files;
        var covered = foldersCanMatch ? new bool[tree.Count] : null;
        var top = new TopK(limit, Ordering(sort, tree, totals));
        int matchCount = 0;
        long matchedBytes = 0;

        for (int index = 1; index < tree.Count; index++)
        {
            if ((index & 0xFFFF) == 0 && isCancelled())
                return new Result(top.Sorted(), matchCount, matchedBytes, notes, true);
            int parentId = tree.Parent[index];
            bool ancestorMatched = covered is not null && parentId >= 0 && parentId < index
                && covered[parentId];
            if (!Matches(index))
            {
                if (covered is not null) covered[index] = ancestorMatched;
                continue;
            }
            if (covered is not null) covered[index] = true;
            matchCount++;
            if (!ancestorMatched) matchedBytes += totals[index];
            top.Insert(index);
        }
        return new Result(top.Sorted(), matchCount, matchedBytes, notes, false);

        bool Matches(int index)
        {
            bool isDirectory = tree.IsDirectory[index];
            switch (type)
            {
                case NodeType.Files when isDirectory: return false;
                case NodeType.Folders when !isDirectory: return false;
            }
            if (inPlace is not null && !inPlace[index]) return false;
            foreach (var bound in SizeBounds)
                if (!Holds(bound.Comparison, totals[index], bound.Value)) return false;
            if (AgeBounds.Count > 0)
            {
                int day = tree.ModifiedDay[index];
                if (day <= 0) return false;
                long age = today - day;
                foreach (var bound in AgeBounds)
                    if (!Holds(bound.Comparison, age, bound.Value)) return false;
            }
            foreach (var flag in Flags)
            {
                switch (flag)
                {
                    case Flag.Duplicate:
                        if (context.DuplicateFileIDs is not { } ids || !ids.Contains(index))
                            return false;
                        break;
                    case Flag.HardLink:
                        if ((tree.Flags[index] & NodeFlags.HardLink) == 0) return false;
                        break;
                    case Flag.Cloud:
                        if ((tree.Flags[index] & NodeFlags.NotDownloaded) == 0) return false;
                        break;
                }
            }
            if (usesName && nameVerdict is not null)
            {
                int nameId = tree.NameIndex[index];
                if (nameVerdict[nameId] == 0)
                    nameVerdict[nameId] =
                        NameMatches(tree.NameTable[nameId], kindSet) ? (byte)1 : (byte)2;
                if (nameVerdict[nameId] != 1) return false;
                // Kind and extension describe file contents; a folder
                // called "x.mp4" is not a video.
                if (isDirectory && (kindSet.Count > 0 || Extensions.Count > 0)) return false;
            }
            return true;
        }
    }

    private static bool Holds(Comparison comparison, long value, long bound) => comparison switch
    {
        Comparison.Greater => value > bound,
        Comparison.GreaterOrEqual => value >= bound,
        Comparison.Less => value < bound,
        _ => value <= bound,
    };

    private static bool IsCacheName(string name) =>
        name.Equals("caches", StringComparison.OrdinalIgnoreCase)
        || name.Equals("cache", StringComparison.OrdinalIgnoreCase)
        || name.Equals(".cache", StringComparison.OrdinalIgnoreCase)
        || name.Equals("temp", StringComparison.OrdinalIgnoreCase);

    private bool NameMatches(string name, HashSet<string> kindSet)
    {
        string lower = name.ToLowerInvariant();
        foreach (var word in Words) if (!lower.Contains(word)) return false;
        foreach (var word in ExcludedWords) if (lower.Contains(word)) return false;
        foreach (var pattern in NamePatterns)
        {
            if (pattern.IndexOfAny(['*', '?', '[']) >= 0)
            {
                if (!GlobMatch(pattern, lower)) return false;
            }
            else if (!lower.Contains(pattern)) return false;
        }
        if (Extensions.Count > 0 && !Extensions.Any(e =>
                lower.EndsWith("." + e) && lower.Length > e.Length + 1))
            return false;
        if (kindSet.Count > 0)
        {
            int dot = lower.LastIndexOf('.');
            if (dot <= 0 || !kindSet.Contains(lower[(dot + 1)..])) return false;
        }
        return true;
    }

    /// <summary>
    /// Glob match: * runs of anything, ? one character, [abc]/[!abc]/[a-z]
    /// sets. fnmatch-shaped, evaluated over the already-lowercased name.
    /// </summary>
    internal static bool GlobMatch(string pattern, string name)
    {
        return Match(pattern, 0, name, 0);

        static bool Match(string p, int pi, string n, int ni)
        {
            while (pi < p.Length)
            {
                char pc = p[pi];
                if (pc == '*')
                {
                    while (pi < p.Length && p[pi] == '*') pi++;
                    if (pi == p.Length) return true;
                    for (int i = ni; i <= n.Length; i++)
                        if (Match(p, pi, n, i)) return true;
                    return false;
                }
                if (ni >= n.Length) return false;
                if (pc == '?') { pi++; ni++; continue; }
                if (pc == '[')
                {
                    int j = pi + 1;
                    bool negate = j < p.Length && (p[j] == '!' || p[j] == '^');
                    if (negate) j++;
                    bool hit = false;
                    bool first = true;
                    while (j < p.Length && (p[j] != ']' || first))
                    {
                        first = false;
                        if (j + 2 < p.Length && p[j + 1] == '-' && p[j + 2] != ']')
                        {
                            if (n[ni] >= p[j] && n[ni] <= p[j + 2]) hit = true;
                            j += 3;
                        }
                        else
                        {
                            if (n[ni] == p[j]) hit = true;
                            j++;
                        }
                    }
                    if (j >= p.Length) return false;   // unclosed set
                    if (hit == negate) return false;
                    pi = j + 1;
                    ni++;
                    continue;
                }
                if (pc != n[ni]) return false;
                pi++;
                ni++;
            }
            return ni == n.Length;
        }
    }

    public enum NodeLookupKind { Found, Outside, Missing }
    public readonly record struct NodeLookup(NodeLookupKind Kind, int Id)
    {
        public static NodeLookup FoundId(int id) => new(NodeLookupKind.Found, id);
        public static readonly NodeLookup Outside = new(NodeLookupKind.Outside, 0);
        public static readonly NodeLookup Missing = new(NodeLookupKind.Missing, 0);
    }

    /// <summary>
    /// Finds a folder by walking child names from the root — a handful of
    /// sibling scans, never a path per node. Case-insensitive: Windows
    /// paths are.
    /// </summary>
    public static NodeLookup NodeAt(string path, FileTree tree, string rootPath)
    {
        string normalized = Path.GetFullPath(path).TrimEnd('\\');
        string root = Path.GetFullPath(rootPath).TrimEnd('\\');
        if (string.Equals(normalized, root, StringComparison.OrdinalIgnoreCase))
            return NodeLookup.FoundId(0);
        string prefix = root + "\\";
        if (!normalized.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return NodeLookup.Outside;
        int current = 0;
        foreach (var component in normalized[prefix.Length..].Split('\\', StringSplitOptions.RemoveEmptyEntries))
        {
            int child = tree.FirstChild[current];
            int next = -1;
            while (child != -1)
            {
                if (tree.NameOf(child).Equals(component, StringComparison.OrdinalIgnoreCase))
                {
                    next = child;
                    break;
                }
                child = tree.NextSibling[child];
            }
            if (next == -1) return NodeLookup.Missing;
            current = next;
        }
        return NodeLookup.FoundId(current);
    }

    /// <summary>Comparer's meaning: a ranks ahead of b.</summary>
    private static Comparison<int> Ordering(Sort sort, FileTree tree, long[] totals) => sort switch
    {
        Sort.Largest => (a, b) =>
            totals[a] != totals[b] ? totals[a].CompareTo(totals[b]) : b.CompareTo(a),
        _ => (a, b) =>
        {
            int da = tree.ModifiedDay[a], db = tree.ModifiedDay[b];
            if (da != db)
            {
                // Unknown dates last either way.
                if (da == 0) return 1;
                if (db == 0) return -1;
                return sort == Sort.Oldest ? db.CompareTo(da) : da.CompareTo(db);
            }
            return totals[a] != totals[b] ? totals[a].CompareTo(totals[b]) : b.CompareTo(a);
        },
    };

    /// <summary>Keeps the best `limit` ids seen, as a heap with the weakest on top.</summary>
    private sealed class TopK
    {
        private readonly int _limit;
        private readonly Comparison<int> _before;
        private readonly List<int> _heap = [];

        public TopK(int limit, Comparison<int> before)
        {
            _limit = limit;
            _before = before;
        }

        public void Insert(int id)
        {
            if (_limit <= 0) return;
            if (_heap.Count < _limit)
            {
                _heap.Add(id);
                int child = _heap.Count - 1;
                while (child > 0)
                {
                    int parent = (child - 1) / 2;
                    // Weakest on top: a parent ranking ahead (stronger)
                    // sinks below its weaker child.
                    if (_before(_heap[parent], _heap[child]) <= 0) break;
                    (_heap[child], _heap[parent]) = (_heap[parent], _heap[child]);
                    child = parent;
                }
            }
            else if (_before(id, _heap[0]) > 0)
            {
                _heap[0] = id;
                int parent = 0;
                while (true)
                {
                    int left = parent * 2 + 1;
                    if (left >= _heap.Count) break;
                    int weaker = left;
                    if (left + 1 < _heap.Count && _before(_heap[left], _heap[left + 1]) > 0) weaker = left + 1;
                    if (_before(_heap[parent], _heap[weaker]) <= 0) break;
                    (_heap[parent], _heap[weaker]) = (_heap[weaker], _heap[parent]);
                    parent = weaker;
                }
            }
        }

        public List<int> Sorted()
        {
            var copy = _heap.ToList();
            copy.Sort((a, b) => -_before(a, b));
            return copy;
        }
    }
}

/// <summary>Parsing of human sizes and ages (the CLI's "50GB"/"30d" contract).</summary>
public static class HumanUnits
{
    /// <summary>
    /// "50GB", "1.5 TB", "500M", "2GiB", "123" (bytes). Decimal units are
    /// powers of 1000, as Windows reports sizes; "iB" units are powers of 1024.
    /// </summary>
    public static long? Bytes(string text)
    {
        string trimmed = text.Trim().ToUpperInvariant();
        int split = 0;
        while (split < trimmed.Length && (char.IsDigit(trimmed[split]) || trimmed[split] == '.')) split++;
        if (!double.TryParse(trimmed[..split], out double value) || value < 0) return null;
        string unit = trimmed[split..].Trim();
        double multiplier = unit switch
        {
            "" or "B" => 1,
            "K" or "KB" => 1e3,
            "M" or "MB" => 1e6,
            "G" or "GB" => 1e9,
            "T" or "TB" => 1e12,
            "KIB" => 1024.0,
            "MIB" => 1_048_576.0,
            "GIB" => 1_073_741_824.0,
            "TIB" => 1_099_511_627_776.0,
            _ => double.NaN,
        };
        if (double.IsNaN(multiplier)) return null;
        double bytes = value * multiplier;
        return bytes < long.MaxValue ? (long)bytes : null;
    }

    /// <summary>"30d", "2w", "6m" (30-day months), "1y" → days.</summary>
    public static int? Days(string text)
    {
        string trimmed = text.Trim().ToLowerInvariant();
        if (trimmed.Length < 2) return null;
        char unit = trimmed[^1];
        if (!int.TryParse(trimmed[..^1], out int value) || value < 0) return null;
        return unit switch
        {
            'd' => value,
            'w' => value * 7,
            'm' => value * 30,
            'y' => value * 365,
            _ => null,
        };
    }

    /// <summary>Decimal-unit formatting — same scale as Windows Explorer.</summary>
    public static string Format(long bytes)
    {
        const long kb = 1000, mb = kb * 1000, gb = mb * 1000, tb = gb * 1000;
        return bytes switch
        {
            >= tb => $"{bytes / (double)tb:0.##} TB",
            >= gb => $"{bytes / (double)gb:0.##} GB",
            >= mb => $"{bytes / (double)mb:0.##} MB",
            >= kb => $"{bytes / (double)kb:0.#} KB",
            _ => $"{bytes} B",
        };
    }
}
