namespace DiskMap.Core;

/// <summary>
/// One drawable slice of a chart. <see cref="NodeID"/> is null for the
/// collapsed remainder. That remainder is never drillable.
/// </summary>
public sealed record ChartSlice(
    string Id,
    int? NodeID,
    long Size,
    string Label,
    bool Drillable,
    List<ChartSlice> Children);

/// <summary>
/// One level of <paramref name="node"/>'s children, plus at most one more
/// level for the children that are large enough to draw. Anything smaller
/// than 0.5% of its parent collapses into a single Other slice so a home
/// scan cannot draw every descendant.
/// </summary>
public static class ChartLayout
{
    public const double OtherFraction = 0.005;

    public static List<ChartSlice> SlicesOf(int node, FileTree tree, long[] totals)
    {
        if (node < 0 || node >= tree.Count || totals.Length != tree.Count)
            return [];
        return Collapse(tree.ChildrenOf(node, totals), totals[node], tree, totals, includeChildren: true, idPrefix: node.ToString());
    }

    private static List<ChartSlice> Collapse(
        List<(int Id, long Size)> items,
        long parentSize,
        FileTree tree,
        long[] totals,
        bool includeChildren,
        string idPrefix)
    {
        double threshold = parentSize * OtherFraction;
        var visible = new List<(int Id, long Size)>();
        long otherSize = 0;
        int otherCount = 0;
        foreach (var item in items)
        {
            if (item.Size <= 0) continue;
            if (item.Size < threshold) { otherSize += item.Size; otherCount++; }
            else visible.Add(item);
        }
        visible.Sort((a, b) => b.Size.CompareTo(a.Size));

        var slices = visible.Select(item =>
        {
            List<ChartSlice> nested = [];
            if (includeChildren && tree.IsDirectory[item.Id])
            {
                nested = Collapse(
                    tree.ChildrenOf(item.Id, totals), item.Size, tree, totals,
                    includeChildren: false, idPrefix: $"{idPrefix}.{item.Id}");
            }
            return new ChartSlice(
                Id: $"{idPrefix}.{item.Id}",
                NodeID: item.Id,
                Size: item.Size,
                Label: tree.NameOf(item.Id),
                Drillable: tree.IsDirectory[item.Id],
                Children: nested);
        }).ToList();

        if (otherCount > 0)
        {
            slices.Add(new ChartSlice(
                Id: $"{idPrefix}.other",
                NodeID: null,
                Size: otherSize,
                Label: $"Other ({otherCount})",
                Drillable: false,
                Children: []));
        }
        return slices;
    }
}
