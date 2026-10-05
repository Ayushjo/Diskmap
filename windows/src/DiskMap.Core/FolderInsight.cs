namespace DiskMap.Core;

public sealed record FolderLargestFile(int Id, string Name, long Bytes);

public enum FolderSafety { Protected, Safe, Review }

/// <summary>
/// Deterministic folder summary for the Biggest Folders inspector
/// (WIN-026 port). Composition comes from the file-type catalog; the
/// reviewable figure stays honest — old-file bytes, or the whole folder
/// only when the path is known-safe.
/// </summary>
public sealed record FolderInsight(
    int NodeID,
    string Name,
    string AbsolutePath,
    string DisplayPath,
    long Bytes,
    int FileCount,
    int FolderCount,
    List<(string Kind, string Label, long Bytes)> Composition,
    FolderSafety Safety,
    long ReviewableBytes,
    string WhyLarge,
    List<FolderLargestFile> LargestFiles)
{
    public int ItemCount => FileCount + FolderCount;

    /// <summary>
    /// <paramref name="quickWinIds"/>: node ids a QuickWins scan flagged —
    /// the Windows stand-in for the macOS safety classifier's `safe` level
    /// (known-regenerable data). Protected = the cleanup queue's never-
    /// stage prefixes.
    /// </summary>
    public static FolderInsight? Build(
        int nodeID,
        FileTree tree,
        string rootPath,
        long[] totals,
        int[] fileCounts,
        int[] folderCounts,
        HashSet<int>? quickWinIds = null,
        int today = 0)
    {
        if (nodeID < 0 || nodeID >= tree.Count || totals.Length != tree.Count
            || !tree.IsDirectory[nodeID]) return null;
        if (today == 0) today = AgeMap.Today();
        string abs = tree.PathOf(nodeID, rootPath);
        string name = tree.NameOf(nodeID);
        var safety = CleanupQueue.IsExcludedPath(abs) ? FolderSafety.Protected
            : quickWinIds is not null && quickWinIds.Contains(nodeID) ? FolderSafety.Safe
            : FolderSafety.Review;

        // Composition + largest file rows under this folder.
        var breakdown = FileTypes.TypeBreakdown(tree, totals, nodeID);
        var composition = breakdown
            .Where(kv => kv.Value > 0 && kv.Key != FileTypes.OtherId)
            .OrderByDescending(kv => kv.Value)
            .Select(kv => (kv.Key, FileTypes.LabelOf(kv.Key), kv.Value))
            .ToList();
        if (breakdown.GetValueOrDefault(FileTypes.OtherId) is { } rest && rest > 0)
            composition.Add((FileTypes.OtherId, "Other", rest));

        var largest = TopSizes.Largest(nodeID, tree.Count, 5,
            id => totals[id],
            id => !tree.IsDirectory[id] && totals[id] > 0
                && IsUnder(tree, id, nodeID))
            .Select(id => new FolderLargestFile(id, tree.NameOf(id), totals[id]))
            .ToList();

        return new FolderInsight(
            nodeID, name, abs, abs, totals[nodeID],
            fileCounts.Length > nodeID ? fileCounts[nodeID] : 0,
            folderCounts.Length > nodeID ? folderCounts[nodeID] : 0,
            composition, safety,
            ReviewableUnder(tree, totals, nodeID, today, safety),
            WhyLargeCopy(name, composition, totals[nodeID], safety),
            largest);
    }

    private static bool IsUnder(FileTree tree, int id, int ancestor)
    {
        for (int p = tree.Parent[id]; p >= 0; p = tree.Parent[p])
            if (p == ancestor) return true;
        return false;
    }

    /// <summary>
    /// Honest estimate: old files (>1y) under this folder, or full size
    /// for known-safe targets. Never claims the whole folder is
    /// reclaimable unless safety is Safe.
    /// </summary>
    private static long ReviewableUnder(
        FileTree tree, long[] totals, int nodeID, int today, FolderSafety safety)
    {
        if (safety == FolderSafety.Protected) return 0;
        if (safety == FolderSafety.Safe) return totals[nodeID];
        long sum = 0;
        var stack = new Stack<int>([nodeID]);
        while (stack.TryPop(out int id))
        {
            if (!tree.IsDirectory[id])
            {
                int day = tree.ModifiedDay[id];
                if (day > 0 && today - day > 365 && totals[id] > 0) sum += totals[id];
            }
            else
            {
                int child = tree.FirstChild[id];
                while (child != -1)
                {
                    stack.Push(child);
                    child = tree.NextSibling[child];
                }
            }
        }
        return sum;
    }

    private static string WhyLargeCopy(
        string name, List<(string Kind, string Label, long Bytes)> composition,
        long bytes, FolderSafety safety)
    {
        if (safety == FolderSafety.Protected)
            return "This space is used by Windows and system components. DiskMap does not recommend cleaning it from here.";
        if (composition.Count == 0)
            return $"This folder holds {HumanUnits.Format(bytes)} across its contents. Open it to inspect what is inside.";
        var top = composition.Take(3).Select(c => $"{c.Label.ToLowerInvariant()} ({HumanUnits.Format(c.Bytes)})").ToList();
        return top.Count switch
        {
            1 => $"Mostly {top[0]}.",
            2 => $"Mostly {top[0]} and {top[1]}.",
            _ => $"Mostly {top[0]}, {top[1]}, and {top[2]}.",
        };
    }
}
