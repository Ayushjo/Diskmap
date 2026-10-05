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
    List<ChartSlice> Children,
    /// <summary>For the collapsed Other slice: how many items it hides.</summary>
    int HiddenCount = 0);

/// <summary>
/// <c>levels</c> levels of <paramref name="node"/>'s descendants (two by
/// default), each only for items large enough to draw. Anything smaller than
/// 0.5% of its parent collapses into a single Other slice.
/// </summary>
public static class ChartLayout
{
    /// <summary>Default depth: items under 0.5% of their parent collapse into Other.</summary>
    public const double OtherFraction = 0.005;

    /// <summary>
    /// <paramref name="otherFraction"/> is the depth control: smaller
    /// values draw deeper (a slice must exceed parentSize × fraction to
    /// show). The UI slider maps to this.
    /// </summary>
    public static List<ChartSlice> SlicesOf(
        int node, FileTree tree, long[] totals, double otherFraction = OtherFraction,
        int levels = 2)
    {
        if (node < 0 || node >= tree.Count || totals.Length != tree.Count || levels < 1)
            return [];
        return Collapse(tree.ChildrenOf(node, totals), totals[node], tree, totals,
            depth: levels - 1, idPrefix: node.ToString(), otherFraction);
    }

    private static List<ChartSlice> Collapse(
        List<(int Id, long Size)> items,
        long parentSize,
        FileTree tree,
        long[] totals,
        int depth,
        string idPrefix,
        double otherFraction)
    {
        double threshold = parentSize * otherFraction;
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
            if (depth > 0 && tree.IsDirectory[item.Id])
            {
                nested = Collapse(
                    tree.ChildrenOf(item.Id, totals), item.Size, tree, totals,
                    depth: depth - 1, idPrefix: $"{idPrefix}.{item.Id}", otherFraction);
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
                Children: [],
                HiddenCount: otherCount));
        }
        return slices;
    }
}
