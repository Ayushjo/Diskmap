namespace DiskMap.Core;

public enum SnapshotChangeKind { Added, Removed, Grew, Shrunk }

/// <summary>
/// Two snapshots of the same folder, aligned by name one level at a time
/// (TASK-071 port).
///
/// The old flat diff listed every folder whose total changed, so one new
/// 5 GB file deep in Downloads appeared as ~, ~\Downloads, ~\Downloads\x …
/// each "+5 GB", and building it meant a path string for every folder of
/// both trees. Here nothing is aligned until it is looked at: the first
/// screen needs only the root's children, and every level's rows add up
/// to their parent.
/// </summary>
public sealed class SnapshotComparison
{
    public sealed record Entry(
        /// <summary>Path relative to the root, "" for the root itself.</summary>
        string Path,
        string Name,
        int? BeforeID,
        int? AfterID,
        long Before,
        long After,
        bool IsDirectory)
    {
        public long Delta => After - Before;

        /// <summary>Null when nothing changed.</summary>
        public SnapshotChangeKind? Kind =>
            BeforeID is null && AfterID is not null ? SnapshotChangeKind.Added
            : AfterID is null && BeforeID is not null ? SnapshotChangeKind.Removed
            : Delta > 0 ? SnapshotChangeKind.Grew
            : Delta < 0 ? SnapshotChangeKind.Shrunk
            : null;
    }

    public DiskSnapshot Before { get; }
    public DiskSnapshot After { get; }
    private readonly long[] _beforeTotals;
    private readonly long[] _afterTotals;

    public SnapshotComparison(DiskSnapshot before, DiskSnapshot after, SizeBasis basis)
    {
        Before = before;
        After = after;
        _beforeTotals = before.Tree.RollUpSizes(basis);
        _afterTotals = after.Tree.RollUpSizes(basis);
    }

    /// <summary>Paths only line up when both snapshots were taken of the same folder.</summary>
    public bool RootsMatch => Before.RootPath == After.RootPath;

    public Entry Root
    {
        get
        {
            bool hasBefore = Before.Tree.Count > 0 && _beforeTotals.Length == Before.Tree.Count;
            bool hasAfter = After.Tree.Count > 0 && _afterTotals.Length == After.Tree.Count;
            string name = After.RootPath.TrimEnd('\\', '/');
            name = name[(name.LastIndexOfAny(['\\', '/']) + 1)..];
            if (name.Length == 0) name = After.RootPath;
            return new Entry("", name,
                hasBefore ? 0 : null, hasAfter ? 0 : null,
                hasBefore ? _beforeTotals[0] : 0, hasAfter ? _afterTotals[0] : 0,
                IsDirectory: true);
        }
    }

    public string AbsolutePathOf(Entry entry) =>
        entry.Path.Length == 0 ? After.RootPath
            : After.RootPath.TrimEnd('\\', '/') + "\\" + entry.Path.Replace('/', '\\');

    /// <summary>
    /// Children of <paramref name="entry"/>, matched by name, largest
    /// change first (then largest size). Unchanged children are left out
    /// unless asked for.
    /// </summary>
    public List<Entry> ChildrenOf(Entry entry, bool includeUnchanged = false)
    {
        if (!entry.IsDirectory) return [];
        var beforeByName = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        if (entry.BeforeID is { } beforeId)
        {
            int child = Before.Tree.FirstChild[beforeId];
            while (child != -1)
            {
                // Same-named children (case-insensitive FS): last wins.
                beforeByName[Before.Tree.NameOf(child)] = child;
                child = Before.Tree.NextSibling[child];
            }
        }
        var result = new List<Entry>();
        string prefix = entry.Path.Length == 0 ? "" : entry.Path + "/";
        if (entry.AfterID is { } afterId)
        {
            int child = After.Tree.FirstChild[afterId];
            while (child != -1)
            {
                string name = After.Tree.NameOf(child);
                int? match = beforeByName.Remove(name, out int m) ? m : null;
                result.Add(new Entry(
                    prefix + name, name, match, child,
                    match is { } b ? _beforeTotals[b] : 0, _afterTotals[child],
                    After.Tree.IsDirectory[child]));
                child = After.Tree.NextSibling[child];
            }
        }
        foreach (var (name, id) in beforeByName)
        {
            result.Add(new Entry(prefix + name, name, id, null,
                _beforeTotals[id], 0, Before.Tree.IsDirectory[id]));
        }
        if (!includeUnchanged) result.RemoveAll(e => e.Delta == 0);
        result.Sort((a, b) =>
        {
            long aa = Math.Abs(a.Delta), bb = Math.Abs(b.Delta);
            if (aa != bb) return bb.CompareTo(aa);
            long am = Math.Max(a.Before, a.After), bm = Math.Max(b.Before, b.After);
            if (am != bm) return bm.CompareTo(am);
            return string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase);
        });
        return result;
    }

    /// <summary>
    /// Walks <paramref name="path"/> ("Users\me\Downloads") down from the
    /// root; null if either side never had it.
    /// </summary>
    public Entry? EntryAt(string path)
    {
        var current = Root;
        foreach (var component in path.Replace('\\', '/').Split('/',
                     StringSplitOptions.RemoveEmptyEntries))
        {
            var next = ChildrenOf(current, includeUnchanged: true)
                .FirstOrDefault(c => c.Name.Equals(component, StringComparison.OrdinalIgnoreCase));
            if (next is null) return null;
            current = next;
        }
        return current;
    }

    /// <summary>
    /// Sum of the growing and of the shrinking children of
    /// <paramref name="entry"/> — the two halves of its net change, one
    /// level down.
    /// </summary>
    public (long Grew, long Shrank) SplitOf(Entry entry) =>
        ChildrenOf(entry).Aggregate((0L, 0L),
            (acc, child) => child.Delta > 0
                ? (acc.Item1 + child.Delta, acc.Item2)
                : (acc.Item1, acc.Item2 + child.Delta));

    /// <summary>
    /// Where the changes actually happened. Starting at the root, descend
    /// while up to three children explain the change (≥ 80%, same
    /// direction); stop at a folder whose change is spread across many
    /// small items, at a file, or at a folder that is new or gone as a
    /// whole. Only entries that changed by at least
    /// <paramref name="minimumChange"/> are visited.
    /// </summary>
    public List<Entry> Hotspots(long minimumChange, int limit = 50)
    {
        var found = new List<Entry>();
        var stack = new Stack<Entry>();
        stack.Push(Root);
        int visited = 0;
        while (stack.TryPop(out var entry) && visited < 20_000)
        {
            visited++;
            if (Math.Abs(entry.Delta) < minimumChange) continue;
            bool wholeUnit = !entry.IsDirectory
                || entry.Kind is SnapshotChangeKind.Added or SnapshotChangeKind.Removed;
            if (wholeUnit && entry.Path.Length > 0)
            {
                found.Add(entry);
                continue;
            }
            var big = ChildrenOf(entry).Where(c => Math.Abs(c.Delta) >= minimumChange).ToList();
            if (big.Count > 0 && FewExplain(entry, big))
                foreach (var b in big) stack.Push(b);
            else if (entry.Path.Length > 0)
                found.Add(entry);
            else
                foreach (var b in big) stack.Push(b);
        }
        return found.OrderByDescending(e => Math.Abs(e.Delta)).Take(limit).ToList();
    }

    /// <summary>
    /// At most three children, moving the same way as `entry`, account
    /// for 80% of its change. When it takes more the folder itself is the
    /// story, not forty rows.
    /// </summary>
    private static bool FewExplain(Entry entry, List<Entry> big)
    {
        long target = Math.Abs(entry.Delta) * 4 / 5;
        long explained = 0;
        foreach (var child in big.Where(c => c.Delta > 0 == entry.Delta > 0).Take(3))
        {
            explained += Math.Abs(child.Delta);
            if (explained >= target) return true;
        }
        return false;
    }

    /// <summary>A sensible floor for <see cref="Hotspots"/>: 0.1% of the larger total, at least 10 MB.</summary>
    public long DefaultMinimumChange =>
        Math.Max(10_000_000, Math.Max(Root.Before, Root.After) / 1_000);
}
