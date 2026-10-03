using System.Text.RegularExpressions;

namespace DiskMap.Core;

/// <summary>
/// Whether deleting a repository's folder would lose committed work
/// (TASK-053). Read from <c>.git</c> directly — no <c>git</c> subprocess,
/// no network, consistent with the offline promise. Remote-tracking refs
/// are as of the last fetch, so "differs" cannot tell unpushed from
/// not-yet-pulled; the copy says so. Uncommitted working-tree changes are
/// not detected at all.
/// </summary>
public abstract record GitState
{
    public sealed record NotARepository : GitState;
    /// <summary>A repository with no remote: this folder may be the only copy.</summary>
    public sealed record NoRemote : GitState;
    /// <summary>Every local branch matches its remote-tracking branch.</summary>
    public sealed record InSync : GitState;
    /// <summary>These local branches are missing from, or differ from, the remote.</summary>
    public sealed record Differs(List<string> Branches) : GitState;
    /// <summary><c>.git</c> is a file (worktree or submodule), or could not be read.</summary>
    public sealed record Unknown(string Reason) : GitState;

    public string Title => this switch
    {
        NotARepository => "Not a git repository",
        NoRemote => "No remote — may be the only copy",
        InSync => "Committed work is on the remote",
        Differs { Branches: { Count: 1 } b } => $"Branch “{b[0]}” isn’t on the remote",
        Differs d => $"{d.Branches.Count} branches aren’t on the remote",
        Unknown => "Git status unknown",
        _ => "Git status unknown",
    };

    public string Detail => this switch
    {
        NotARepository =>
            "No version control found, so nothing guarantees this folder can be recovered.",
        NoRemote =>
            "The repository has no remote to push to. Deleting the folder deletes its history.",
        InSync =>
            "Every local branch matches the remote as of the last fetch. Uncommitted changes are not checked.",
        Differs =>
            "These branches have commits that differ from the remote — unpushed work, or changes not yet pulled. Uncommitted changes are not checked.",
        Unknown u => u.Reason,
        _ => "",
    };

    /// <summary>Only this state says the folder's committed history exists elsewhere.</summary>
    public bool IsBackedUp => this is InSync;
}

public static class GitInspector
{
    public static GitState Inspect(string repositoryPath)
    {
        string git = Path.Combine(repositoryPath, ".git");
        if (!File.Exists(git) && !Directory.Exists(git)) return new GitState.NotARepository();
        if (!Directory.Exists(git))
            return new GitState.Unknown(
                "This is a git worktree or submodule; its status lives in another repository.");
        string? config = Read(Path.Combine(git, "config"));
        if (config is null)
            return new GitState.Unknown("The repository’s configuration could not be read.");
        var remotes = RemoteNames(config);
        if (remotes.Count == 0) return new GitState.NoRemote();
        string remote = remotes.Contains("origin") ? "origin" : remotes.OrderBy(r => r).First();

        var packed = PackedRefs(Path.Combine(git, "packed-refs"));
        var local = packed.Where(kv => kv.Key.StartsWith("refs/heads/"))
            .ToDictionary(kv => kv.Key, kv => kv.Value);
        var tracking = packed.Where(kv => kv.Key.StartsWith($"refs/remotes/{remote}/"))
            .ToDictionary(kv => kv.Key, kv => kv.Value);
        foreach (var (refName, sha) in LooseRefs(git, "refs/heads")) local[refName] = sha;
        foreach (var (refName, sha) in LooseRefs(git, $"refs/remotes/{remote}")) tracking[refName] = sha;

        if (local.Count == 0)
            return new GitState.Unknown("The repository has no branches yet.");
        var differing = new List<string>();
        foreach (var (refName, sha) in local)
        {
            string branch = refName["refs/heads/".Length..];
            if (!tracking.TryGetValue($"refs/remotes/{remote}/{branch}", out string? remoteSha)
                || remoteSha != sha)
            {
                differing.Add(branch);
            }
        }
        return differing.Count == 0 ? new GitState.InSync()
            : new GitState.Differs(differing.OrderBy(b => b).ToList());
    }

    /// <summary><c>[remote "name"]</c> section headers.</summary>
    internal static List<string> RemoteNames(string config) =>
        config.Split('\n')
            .Select(l => l.Trim())
            .Where(l => l.StartsWith("[remote \"") && l.EndsWith("\"]"))
            .Select(l => l[9..^2])
            .ToList();

    internal static Dictionary<string, string> PackedRefs(string path)
    {
        var refs = new Dictionary<string, string>();
        if (Read(path) is not { } text) return refs;
        foreach (var rawLine in text.Split('\n'))
        {
            string line = rawLine.Trim();
            if (line.StartsWith('#') || line.StartsWith('^')) continue;
            int space = line.IndexOf(' ');
            if (space <= 0) continue;
            refs[line[(space + 1)..]] = line[..space];
        }
        return refs;
    }

    /// <summary>Loose ref files under <c>.git/{prefix}</c>, recursively (branch names may contain slashes).</summary>
    internal static Dictionary<string, string> LooseRefs(string git, string prefix)
    {
        string baseDir = Path.Combine(git, prefix.Replace('/', Path.DirectorySeparatorChar));
        var refs = new Dictionary<string, string>();
        if (!Directory.Exists(baseDir)) return refs;
        IEnumerable<string> files;
        try { files = Directory.EnumerateFiles(baseDir, "*", SearchOption.AllDirectories); }
        catch { return refs; }
        foreach (var file in files)
        {
            string relative = Path.GetRelativePath(baseDir, file).Replace(Path.DirectorySeparatorChar, '/');
            string? sha = Read(file)?.Trim();
            if (sha is null || sha.Length < 40 || sha.StartsWith("ref:")) continue;
            refs[$"{prefix}/{relative}"] = sha;
        }
        return refs;
    }

    internal static string? Read(string path)
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.Length >= 16 * 1024 * 1024) return null;
            return File.ReadAllText(path);
        }
        catch { return null; }
    }
}

/// <summary>
/// <c>.gitignore</c> evaluation over the scan tree (TASK-054): how many
/// bytes in a repository git itself treats as disposable. Anything ignored
/// is, by the repository author's own declaration, generated or local — a
/// stronger signal than any name list, and it covers tools DiskMap has no
/// rule for.
///
/// Supported: nested <c>.gitignore</c> files and <c>.git/info/exclude</c>;
/// blank lines and <c>#</c> comments; <c>!</c> negation; trailing <c>/</c>
/// (directories only); leading or inner <c>/</c> (anchored to the file's
/// folder); <c>*</c>, <c>?</c>, <c>[...]</c>, <c>**</c>; <c>\</c> escapes.
/// Not supported: the global excludes file (<c>core.excludesFile</c>).
/// As in git, an ignored folder is not descended into, so a negation
/// inside it cannot re-include anything.
/// </summary>
public sealed class GitIgnoreRules
{
    private sealed class Rule
    {
        public required Matcher Kind { get; init; }
        public bool Anchored { get; init; }
        public bool DirectoryOnly { get; init; }
        public bool Negated { get; init; }
        /// <summary>Folder of the file this rule came from, relative to the repository root ("" for the root).</summary>
        public required string Base { get; init; }
        /// <summary>For regex rules: a literal run every match must contain — a cheap Contains skips most paths.</summary>
        public string? RequiredLiteral { get; set; }
        /// <summary>For regex rules whose last segment has no wildcard: the exact name the path must end in.</summary>
        public string? RequiredName { get; set; }
    }

    private abstract record Matcher
    {
        public sealed record LiteralName(string Name) : Matcher;
        public sealed record NameSuffix(string Suffix) : Matcher;
        public sealed record RegexMatch(Regex Regex) : Matcher;
    }

    /// <summary>
    /// Lookup structure over a rule list, so evaluating a path costs O(1)
    /// dictionary hits plus the few genuine globs — not a loop over every
    /// rule.
    /// </summary>
    private sealed class Index
    {
        public readonly Dictionary<string, List<int>> ByName = new(StringComparer.Ordinal);
        public readonly Dictionary<string, List<int>> ByExtension = new(StringComparer.Ordinal);
        public readonly List<int> Scanned = [];

        public Index(List<Rule> rules)
        {
            for (int i = 0; i < rules.Count; i++)
            {
                switch (rules[i].Kind)
                {
                    case Matcher.LiteralName l:
                        Add(ByName, l.Name, i); break;
                    case Matcher.NameSuffix s when s.Suffix.StartsWith('.')
                        && !s.Suffix[1..].Contains('.'):
                        Add(ByExtension, s.Suffix, i); break;
                    default:
                        Scanned.Add(i); break;
                }
            }
            static void Add(Dictionary<string, List<int>> map, string key, int i)
            {
                if (!map.TryGetValue(key, out var list)) map[key] = list = [];
                list.Add(i);
            }
        }
    }

    private readonly List<Rule> _rules = [];

    /// <summary>Parses one ignore file whose folder is <paramref name="base"/> (relative to the repo root).</summary>
    public static List<RuleRecord> Parse(string text, string baseFolder = "")
    {
        var rules = new GitIgnoreRules();
        rules.AddParsed(text, baseFolder);
        return rules._rules.Select(r => new RuleRecord(
            r.Kind is Matcher.LiteralName l ? l.Name
                : r.Kind is Matcher.NameSuffix s ? "*" + s.Suffix : "(glob)",
            r.Negated, r.Anchored, r.DirectoryOnly, r.Base)).ToList();
    }

    /// <summary>A parsed rule's test-visible shape (matcher internals stay private).</summary>
    public sealed record RuleRecord(
        string Pattern, bool Negated, bool Anchored, bool DirectoryOnly, string Base);

    private void AddParsed(string text, string baseFolder)
    {
        foreach (var rawLine in text.Split('\n'))
        {
            string line = rawLine.TrimEnd('\r');
            // Trailing spaces are ignored unless escaped.
            while (line.EndsWith(' ') && !line.EndsWith("\\ ")) line = line[..^1];
            if (line.Length == 0 || line.StartsWith('#')) continue;
            bool negated = false;
            if (line.StartsWith('!')) { negated = true; line = line[1..]; }
            else if (line.StartsWith("\\!") || line.StartsWith("\\#")) line = line[1..];
            bool directoryOnly = false;
            if (line.EndsWith('/')) { directoryOnly = true; line = line[..^1]; }
            if (line.Length == 0) continue;
            bool anchored = line.Contains('/');
            if (line.StartsWith('/')) line = line[1..];
            var matcher = MakeMatcher(line, anchored);
            if (matcher is null) continue;
            var rule = new Rule
            {
                Kind = matcher, Anchored = anchored, DirectoryOnly = directoryOnly,
                Negated = negated, Base = baseFolder,
            };
            if (matcher is Matcher.RegexMatch)
            {
                rule.RequiredLiteral = LongestLiteral(line);
                string last = line.Split('/').Last();
                if (last != "**" && last.IndexOfAny(['*', '?', '[']) < 0)
                    rule.RequiredName = last.Replace("\\", "");
            }
            _rules.Add(rule);
        }
    }

    private static Matcher? MakeMatcher(string pattern, bool anchored)
    {
        bool special = pattern.IndexOfAny(['*', '?', '[', '\\']) >= 0;
        if (!anchored && !special) return new Matcher.LiteralName(pattern);
        if (!anchored && pattern.StartsWith('*')
            && pattern[1..].IndexOfAny(['*', '?', '[', '\\']) < 0)
            return new Matcher.NameSuffix(pattern[1..]);
        try
        {
            return new Matcher.RegexMatch(new Regex(
                "^" + RegexBody(pattern) + "$", RegexOptions.CultureInvariant));
        }
        catch { return null; }
    }

    /// <summary>Longest run of literal characters in a glob (outside * ? and [...], honouring \ escapes).</summary>
    internal static string? LongestLiteral(string glob)
    {
        string best = "", current = "";
        for (int i = 0; i < glob.Length; i++)
        {
            char c = glob[i];
            if (c is '*' or '?')
            {
                if (current.Length > best.Length) best = current;
                current = "";
                // "**/" can match zero folders, so the slash after "**" is not required.
                if (c == '*' && i + 2 < glob.Length && glob[i + 1] == '*' && glob[i + 2] == '/')
                    i += 2;
            }
            else if (c == '[')
            {
                int close = glob.IndexOf(']', i + 1);
                if (close < 0) { current += c; continue; }
                if (current.Length > best.Length) best = current;
                current = "";
                i = close;
            }
            else if (c == '\\' && i + 1 < glob.Length)
            {
                current += glob[i + 1];
                i++;
            }
            else current += c;
        }
        if (current.Length > best.Length) best = current;
        return best.Length == 0 ? null : best;
    }

    /// <summary>Glob → regex, per gitignore(5).</summary>
    internal static string RegexBody(string glob)
    {
        var output = new System.Text.StringBuilder();
        for (int i = 0; i < glob.Length; i++)
        {
            char c = glob[i];
            if (c == '*')
            {
                bool doubleStar = i + 1 < glob.Length && glob[i + 1] == '*';
                if (doubleStar)
                {
                    bool atStart = i == 0;
                    bool followedBySlash = i + 2 < glob.Length && glob[i + 2] == '/';
                    bool atEnd = i + 2 == glob.Length;
                    if (atStart && followedBySlash) { output.Append("(?:.*/)?"); i += 2; continue; }
                    if (atEnd) { output.Append(".*"); i++; continue; }
                    if (followedBySlash) { output.Append("(?:.*/)?"); i += 2; continue; }
                    output.Append(".*"); i++; continue;
                }
                output.Append("[^/]*");
            }
            else if (c == '?') output.Append("[^/]");
            else if (c == '[')
            {
                int close = glob.IndexOf(']', i + 1);
                if (close < 0) { output.Append("\\["); continue; }
                string cls = glob[(i + 1)..close];
                if (cls.StartsWith('!')) cls = "^" + cls[1..];
                output.Append('[').Append(cls.Replace("\\", "\\\\")).Append(']');
                i = close;
            }
            else if (c == '\\' && i + 1 < glob.Length)
            {
                output.Append(Regex.Escape(glob[i + 1].ToString()));
                i++;
            }
            else output.Append(Regex.Escape(c.ToString()));
        }
        return output.ToString();
    }

    /// <summary>
    /// Null when no rule mentions the path; otherwise whether the last
    /// matching rule ignores it.
    /// </summary>
    public bool? Verdict(string relativePath, string name, bool isDirectory)
    {
        var index = new Index(_rules);
        return Verdict(relativePath, name, isDirectory, index, _rules.Count);
    }

    private bool? Verdict(string relativePath, string name, bool isDirectory, Index index, int limit)
    {
        int best = -1;
        void Consider(int i)
        {
            if (i < limit && i > best && Matches(_rules[i], relativePath, name, isDirectory))
                best = i;
        }
        if (index.ByName.TryGetValue(name, out var byName))
            foreach (var i in byName) Consider(i);
        int dot = name.LastIndexOf('.');
        if (dot >= 0 && index.ByExtension.TryGetValue(name[dot..], out var byExt))
            foreach (var i in byExt) Consider(i);
        foreach (var i in index.Scanned) Consider(i);
        return best >= 0 ? !_rules[best].Negated : null;
    }

    private static bool Matches(Rule rule, string relativePath, string name, bool isDirectory)
    {
        if (rule.DirectoryOnly && !isDirectory) return false;
        if (rule.Base.Length > 0 && !relativePath.StartsWith(rule.Base + "/", StringComparison.Ordinal))
            return false;
        string subject = rule.Anchored
            ? (rule.Base.Length == 0 ? relativePath : relativePath[(rule.Base.Length + 1)..])
            : name;
        return rule.Kind switch
        {
            Matcher.LiteralName l => subject == l.Name,
            Matcher.NameSuffix s => subject.EndsWith(s.Suffix, StringComparison.Ordinal),
            Matcher.RegexMatch r =>
                (rule.RequiredName is null || name == rule.RequiredName)
                && (rule.RequiredLiteral is null || subject.Contains(rule.RequiredLiteral))
                && r.Regex.IsMatch(subject),
            _ => false,
        };
    }

    /// <summary>Bytes ignored under a repository, using the scan tree for
    /// structure and sizes and reading only .gitignore files from disk.</summary>
    public readonly record struct IgnoredResult(long IgnoredBytes, int IgnoreFileCount);

    public static IgnoredResult IgnoredBytes(
        FileTree tree, int repositoryId, string repositoryPath, long[] totals)
    {
        var active = new GitIgnoreRules();
        if (GitInspector.Read(Path.Combine(repositoryPath, ".git", "info", "exclude")) is { } exclude)
            active.AddParsed(exclude, "");
        int files = 0;
        long ignored = 0;
        // Each frame records the rule count its PARENT had; popping a frame
        // truncates back to it before loading that folder's own .gitignore —
        // rules from one branch never leak into a sibling's.
        var stack = new Stack<(int Id, string Relative, int RestoreTo)>();
        stack.Push((repositoryId, "", active._rules.Count));
        var ruleIndex = new Index(active._rules);
        bool indexStale = false;
        while (stack.Count > 0)
        {
            var (frameId, relative, restoreTo) = stack.Pop();
            active._rules.RemoveRange(restoreTo, active._rules.Count - restoreTo);
            int child = tree.FirstChild[frameId];
            while (child != -1)
            {
                if (!tree.IsDirectory[child] && tree.NameOf(child) == ".gitignore")
                {
                    string folderPath = relative.Length == 0
                        ? repositoryPath : repositoryPath + "\\" + relative.Replace('/', '\\');
                    if (GitInspector.Read(folderPath + "\\.gitignore") is { } text)
                    {
                        active.AddParsed(text, relative);
                        files++;
                        indexStale = true;
                    }
                }
                child = tree.NextSibling[child];
            }
            int depthRules = active._rules.Count;
            if (indexStale) { ruleIndex = new Index(active._rules); indexStale = false; }
            child = tree.FirstChild[frameId];
            while (child != -1)
            {
                string name = tree.NameOf(child);
                bool isDir = tree.IsDirectory[child];
                string childRelative = relative.Length == 0 ? name : relative + "/" + name;
                int next = tree.NextSibling[child];
                if (name != ".git")
                {
                    if (active.Verdict(childRelative, name, isDir, ruleIndex, depthRules) == true)
                    {
                        ignored += totals[child];
                    }
                    else if (isDir)
                    {
                        // A nested repository is its own gitignore domain.
                        bool nested = false;
                        int grandchild = tree.FirstChild[child];
                        while (grandchild != -1)
                        {
                            if (tree.NameOf(grandchild) == ".git") { nested = true; break; }
                            grandchild = tree.NextSibling[grandchild];
                        }
                        if (!nested) stack.Push((child, childRelative, depthRules));
                    }
                }
                child = next;
            }
        }
        return new IgnoredResult(ignored, files);
    }
}
