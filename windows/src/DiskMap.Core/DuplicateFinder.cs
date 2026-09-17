using System.Security.Cryptography;

namespace DiskMap.Core;

public sealed record DuplicateGroup(
    string Hash,
    List<int> FileIDs,
    long SizeEach,
    bool SharesStorage)
{
    /// <summary>
    /// Bytes a later confirm would actually free. Content copies each
    /// occupy their own blocks. Shared extents count once, and only when
    /// every copy in the group is being deleted.
    /// </summary>
    public long ReclaimableBytes(IReadOnlySet<int> deleting)
    {
        var removing = FileIDs.Where(deleting.Contains).ToList();
        if (removing.Count == 0 || SizeEach <= 0) return 0;
        if (SharesStorage)
            return removing.Count == FileIDs.Count ? SizeEach : 0;
        return SizeEach * removing.Count;
    }

    /// <summary>Oldest modified day, then lowest id — the file that stays unchecked.</summary>
    public int? DefaultKeeperId(Func<int, int> modifiedDay) =>
        FileIDs.Count == 0 ? null
            : FileIDs.MinBy(id => (modifiedDay(id), id));
}

internal sealed record DuplicateScanResult(List<DuplicateGroup> Groups, int FullContentHashCalls);

/// <summary>
/// Three-phase duplicate detection, cheapest checks first:
///
///   1. Group by exact logical size.
///   2. Within a size group, hash only the first 64 KB.
///   3. Only for files that still collide, hash full content —
///      unless CloneDetector.AreLikelyClones says they share a full
///      extent map. A clone overwritten past the 64 KB window still
///      collides on the partial hash and must be hashed.
/// </summary>
public static class DuplicateFinder
{
    public static async Task<List<DuplicateGroup>> FindDuplicatesAsync(
        List<(int Id, string Path, long Size)> candidates)
    {
        var result = await ScanAsync(candidates);
        return result.Groups;
    }

    /// <summary>
    /// Regular files under root, skipping directories, empty files, and
    /// cloud placeholders (opening those would recall the content).
    /// </summary>
    public static List<(int Id, string Path, long Size)> Candidates(FileTree tree, string root)
    {
        var result = new List<(int, string, long)>();
        var stack = new Stack<int>();
        if (tree.Count > 0) stack.Push(0);
        while (stack.Count > 0)
        {
            int id = stack.Pop();
            if (id > 0)
            {
                bool notDownloaded = (tree.Flags[id] & NodeFlags.NotDownloaded) != 0;
                if (!tree.IsDirectory[id] && !notDownloaded && tree.LogicalSize[id] > 0)
                    result.Add((id, tree.PathOf(id, root), tree.LogicalSize[id]));
            }
            int child = tree.FirstChild[id];
            while (child != -1)
            {
                stack.Push(child);
                child = tree.NextSibling[child];
            }
        }
        return result;
    }

    internal static async Task<DuplicateScanResult> ScanAsync(
        List<(int Id, string Path, long Size)> candidates)
    {
        var bySize = new Dictionary<long, List<(int Id, string Path)>>();
        foreach (var c in candidates)
        {
            if (c.Size <= 0) continue;
            if (!bySize.TryGetValue(c.Size, out var list))
                bySize[c.Size] = list = [];
            list.Add((c.Id, c.Path));
        }

        var groups = new List<DuplicateGroup>();
        int fullContentHashCalls = 0;
        var gate = new object();

        var tasks = bySize
            .Where(kv => kv.Value.Count > 1)
            .Select(kv => Task.Run(() => HashAndGroup(kv.Value, kv.Key)))
            .ToArray();
        foreach (var partial in await Task.WhenAll(tasks))
        {
            groups.AddRange(partial.Groups);
            fullContentHashCalls += partial.FullContentHashCalls;
        }
        return new DuplicateScanResult(groups, fullContentHashCalls);
    }

    private static DuplicateScanResult HashAndGroup(List<(int Id, string Path)> files, long size)
    {
        var byPartial = new Dictionary<string, List<(int Id, string Path)>>();
        foreach (var file in files)
        {
            if (PartialHash(file.Path, 65_536) is { } partial)
            {
                if (!byPartial.TryGetValue(partial, out var list))
                    byPartial[partial] = list = [];
                list.Add(file);
            }
        }

        var groups = new List<DuplicateGroup>();
        int fullContentHashCalls = 0;
        foreach (var (_, collision) in byPartial)
        {
            if (collision.Count < 2) continue;
            var (clusters, needsFullHash) = PartitionClones(collision);
            foreach (var cluster in clusters)
            {
                groups.Add(new DuplicateGroup(
                    Hash: "shared-extents",
                    FileIDs: cluster.Select(c => c.Id).OrderBy(x => x).ToList(),
                    SizeEach: size,
                    SharesStorage: true));
            }
            var byFull = new Dictionary<string, List<int>>();
            foreach (var file in needsFullHash)
            {
                fullContentHashCalls++;
                if (FullHash(file.Path) is { } full)
                {
                    if (!byFull.TryGetValue(full, out var list))
                        byFull[full] = list = [];
                    list.Add(file.Id);
                }
            }
            foreach (var (hash, ids) in byFull)
            {
                if (ids.Count > 1)
                {
                    groups.Add(new DuplicateGroup(
                        Hash: hash,
                        FileIDs: ids.OrderBy(x => x).ToList(),
                        SizeEach: size,
                        SharesStorage: false));
                }
            }
        }
        return new DuplicateScanResult(groups, fullContentHashCalls);
    }

    /// <summary>
    /// Full extent-map matches become clone groups and never reach
    /// FullHash. Everyone else, including a clone that has been written
    /// since, is hashed.
    /// </summary>
    private static (List<List<(int Id, string Path)>> Clusters, List<(int Id, string Path)> NeedsFullHash)
        PartitionClones(List<(int Id, string Path)> files)
    {
        var remaining = new List<(int Id, string Path)>(files);
        var clusters = new List<List<(int, string)>>();
        var needsFullHash = new List<(int, string)>();
        while (remaining.Count > 0)
        {
            var seed = remaining[0];
            remaining.RemoveAt(0);
            var cluster = new List<(int, string)> { seed };
            var rest = new List<(int, string)>();
            foreach (var other in remaining)
            {
                if (CloneDetector.AreLikelyClones(seed.Path, other.Path))
                    cluster.Add(other);
                else
                    rest.Add(other);
            }
            remaining = rest;
            if (cluster.Count > 1) clusters.Add(cluster);
            else needsFullHash.Add(seed);
        }
        return (clusters.Select(c => c.ToList()).ToList(), needsFullHash);
    }

    private static string? PartialHash(string path, int bytes)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            var buffer = new byte[bytes];
            int read = stream.Read(buffer, 0, bytes);
            return Convert.ToHexString(SHA256.HashData(buffer.AsSpan(0, read)));
        }
        catch { return null; }
    }

    private static string? FullHash(string path)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            return Convert.ToHexString(SHA256.HashData(stream));
        }
        catch { return null; }
    }
}
