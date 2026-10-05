using System.Diagnostics;

namespace DiskMap.Core;

/// <summary>
/// The opt-in block-clone profile (WIN-066): maps every candidate file's
/// physical extents with FSCTL_GET_RETRIEVAL_POINTERS, finds ranges two or
/// more files share — ReFS block clones (what `copy` produces on a Dev
/// Drive volume) — and installs a sharing table on the tree so the
/// allocated rollup charges each family's shared blocks once instead of
/// once per copy.
///
/// Same accounting rule as the macOS APFS pass (TASK-077): each family's
/// lowest-inode member carries the shared blocks in full, the other
/// members are charged only their private (unshared) bytes. Lowest inode
/// because it is stable between scans — node ids and sibling order are
/// not, and an unstable election would make snapshot diffs show bytes
/// moving between folders when nothing changed.
///
/// What this pass cannot see: a file sharing extents with a copy OUTSIDE
/// the scanned root still reports private = whole, so its shared blocks
/// count once in this scan's totals — the same answer hard links give for
/// names outside the root. NTFS never reaches here (the engine gates on
/// ReFS); on NTFS this pass would only re-find the hard links the rollup
/// already dedupes.
/// </summary>
public static class BlockClones
{
    /// <summary>What one profile pass found — the scan result's audit line.</summary>
    public sealed record Report(
        int FilesProfiled,
        int MapsFailed,
        int FamilyCount,
        int SharedCopies,
        long SharedBytes,
        double Seconds);

    /// <summary>One inode's inputs to the pure grouping math — testable without ioctls.</summary>
    internal readonly record struct InodeEntry(
        ulong Inode,
        int[] NameNodes,
        long Allocated,
        List<CloneDetector.Extent>? Extents);

    /// <summary>
    /// Maps every file with allocated bytes and installs the sharing table.
    /// Returns null when there is nothing worth mapping (a scan of an
    /// empty folder still counts as "profiled" — mode Full, zero rows).
    /// </summary>
    public static Report Profile(
        FileTree tree,
        string rootPath,
        IProgress<ScanEngine.ScanProgress>? progress,
        CancellationToken cancellationToken)
    {
        var started = Stopwatch.StartNew();

        // One extent map per inode: hard-linked names share the file, so
        // they share one map — and count as one family member.
        var byInode = new Dictionary<ulong, List<int>>();
        for (int id = 0; id < tree.Count; id++)
        {
            if (tree.IsDirectory[id] || tree.AllocatedSize[id] <= 0) continue;
            if ((tree.Flags[id] & NodeFlags.NotDownloaded) != 0) continue;
            ulong inode = tree.FileId[id] != 0
                ? (ulong)tree.FileId[id]
                : (ulong)(uint)id | (1UL << 63);
            if (!byInode.TryGetValue(inode, out var list))
                byInode[inode] = list = [];
            list.Add(id);
        }

        var entries = new InodeEntry[byInode.Count];
        int slot = 0;
        foreach (var (inode, nodes) in byInode)
            entries[slot++] = new InodeEntry(inode, [.. nodes], tree.AllocatedSize[nodes[0]], null);

        // The map pass is the expensive part: one open + ioctl per inode.
        // Paths are needed for the opens — the only pass that builds a path
        // per file, which is why this stays opt-in.
        int done = 0, failed = 0;
        Parallel.For(0, entries.Length,
            new ParallelOptions { MaxDegreeOfParallelism = 8, CancellationToken = cancellationToken },
            i =>
            {
                string path = tree.PathOf(entries[i].NameNodes[0], rootPath);
                entries[i] = entries[i] with { Extents = CloneDetector.ExtentMapOf(path) };
                int mapped = Interlocked.Increment(ref done);
                if (entries[i].Extents is null) Interlocked.Increment(ref failed);
                if (mapped % 2000 == 0)
                {
                    progress?.Report(new ScanEngine.ScanProgress(
                        mapped, 0, 0, "Mapping shared extents…", []));
                }
            });
        cancellationToken.ThrowIfCancellationRequested();

        var table = BuildTable(entries, out int familyCount, out int sharedCopies, out long sharedBytes);
        foreach (int node in table.Node)
            tree.AddFlags(node, NodeFlags.FileClone);
        tree.SetSharing(table, FileTree.CloneSharingMode.Full);
        started.Stop();
        return new Report(entries.Length, failed, familyCount, sharedCopies,
            sharedBytes, started.Elapsed.TotalSeconds);
    }

    /// <summary>
    /// Extent maps → the sharing table. Families are maximal groups of
    /// inodes linked by shared physical ranges; each family's lowest-inode
    /// member is elected to carry the family's blocks (the same stability
    /// argument as the hard-link election).
    /// </summary>
    internal static FileTree.SharingTable BuildTable(
        InodeEntry[] entries,
        out int familyCount,
        out int sharedCopies,
        out long sharedBytes)
    {
        var table = new FileTree.SharingTable();
        familyCount = 0;
        sharedCopies = 0;
        sharedBytes = 0;

        // Flatten every mapped extent — sparse runs (DeviceOffset -1) are
        // holes, not shared blocks, and stay out.
        var flat = new List<(long Start, long End, int Inode)>();
        var totalBytes = new long[entries.Length];
        for (int i = 0; i < entries.Length; i++)
        {
            if (entries[i].Extents is not { } extents) continue;
            foreach (var e in extents)
            {
                if (e.DeviceOffset < 0 || e.LengthBytes <= 0) continue;
                flat.Add((e.DeviceOffset, e.DeviceOffset + e.LengthBytes, i));
                totalBytes[i] += e.LengthBytes;
            }
        }
        if (flat.Count == 0) return table;
        flat.Sort((a, b) => a.Start != b.Start ? a.Start.CompareTo(b.Start) : a.End.CompareTo(b.End));

        var shared = new long[entries.Length];
        var uf = new int[entries.Length];
        for (int i = 0; i < uf.Length; i++) uf[i] = i;
        int Find(int x) { while (uf[x] != x) { uf[x] = uf[uf[x]]; x = uf[x]; } return x; }
        void Union(int a, int b) { a = Find(a); b = Find(b); if (a != b) uf[b] = a; }

        // Sweep clumps of transitively overlapping extents. Within a clump,
        // resolve elementary segments: a segment covered by ≥2 inodes is
        // shared — counted once per covering inode — and joins its inodes
        // into one family.
        int n = flat.Count, cursor = 0;
        while (cursor < n)
        {
            long clumpEnd = flat[cursor].End;
            int j = cursor + 1;
            while (j < n && flat[j].Start < clumpEnd)
            {
                clumpEnd = Math.Max(clumpEnd, flat[j].End);
                j++;
            }
            bool multi = false;
            for (int k = cursor + 1; k < j && !multi; k++)
                if (flat[k].Inode != flat[cursor].Inode) multi = true;
            if (multi)
            {
                var bounds = new List<long>((j - cursor) * 2);
                for (int k = cursor; k < j; k++)
                {
                    bounds.Add(flat[k].Start);
                    bounds.Add(flat[k].End);
                }
                bounds.Sort();
                for (int p = 0; p + 1 < bounds.Count; p++)
                {
                    long a = bounds[p], b = bounds[p + 1];
                    if (a == b) continue;
                    // One entry per covering inode — a file's own extents
                    // never overlap each other, so it appears at most once.
                    var covering = new List<int>(4);
                    for (int k = cursor; k < j; k++)
                    {
                        if (flat[k].Start <= a && flat[k].End >= b
                            && !covering.Contains(flat[k].Inode))
                        {
                            covering.Add(flat[k].Inode);
                        }
                    }
                    if (covering.Count < 2) continue;
                    foreach (int idx in covering) shared[idx] += b - a;
                    for (int k = 1; k < covering.Count; k++) Union(covering[0], covering[k]);
                }
            }
            cursor = j;
        }

        // Union-find components. Only mapped inodes ever joined a union,
        // so singletons here are simply files sharing nothing in-scan.
        var families = new Dictionary<int, List<int>>();
        for (int i = 0; i < entries.Length; i++)
        {
            if (entries[i].Extents is null) continue;
            int root = Find(i);
            if (!families.TryGetValue(root, out var list)) families[root] = list = [];
            list.Add(i);
        }

        var privateBytes = new long[entries.Length];
        for (int i = 0; i < entries.Length; i++)
            privateBytes[i] = Math.Clamp(totalBytes[i] - shared[i], 0, entries[i].Allocated);

        var nodeRows = new List<(int Node, long CloneId, long Private, int RefCount)>();
        foreach (var (_, members) in families)
        {
            if (members.Count < 2) continue;
            ulong elected = members.Min(m => entries[m].Inode);
            long cloneId = unchecked((long)elected);
            familyCount++;
            foreach (int m in members)
            {
                bool isElected = entries[m].Inode == elected;
                if (!isElected)
                {
                    sharedCopies++;
                    sharedBytes += entries[m].Allocated - privateBytes[m];
                }
                foreach (int node in entries[m].NameNodes)
                    nodeRows.Add((node, cloneId, privateBytes[m], members.Count));
            }
        }
        nodeRows.Sort((a, b) => a.Node.CompareTo(b.Node));
        table.Node = new int[nodeRows.Count];
        table.CloneId = new long[nodeRows.Count];
        table.PrivateBytes = new long[nodeRows.Count];
        table.RefCount = new int[nodeRows.Count];
        for (int i = 0; i < nodeRows.Count; i++)
        {
            table.Node[i] = nodeRows[i].Node;
            table.CloneId[i] = nodeRows[i].CloneId;
            table.PrivateBytes[i] = nodeRows[i].Private;
            table.RefCount[i] = nodeRows[i].RefCount;
        }
        return table;
    }
}
