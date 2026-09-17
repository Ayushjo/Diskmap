using DiskMap.Core;

namespace DiskMap.Core.Tests;

public class FileTreeTests
{
    private static int AddRoot(FileTree tree) =>
        tree.AddNode("root", -1, true, 0, 0, 0);

    [Fact]
    public void RollUpSizesSumsCorrectly()
    {
        var tree = new FileTree();
        int root = AddRoot(tree);
        int sub = tree.AddNode("sub", root, true, 0, 0, 0);
        tree.AddNode("a.txt", root, false, 100, 100, 0);
        tree.AddNode("b.txt", sub, false, 200, 200, 0);
        tree.AddNode("c.txt", sub, false, 50, 50, 0);

        var totals = tree.RollUpSizes();

        Assert.Equal(250, totals[sub]);   // b.txt + c.txt
        Assert.Equal(350, totals[root]);  // a.txt + sub's subtree
    }

    [Fact]
    public void LogicalRollupKeepsCloudSizeWhenAllocatedIsZero()
    {
        var tree = new FileTree();
        int root = AddRoot(tree);
        int folder = tree.AddNode("Cloud", root, true, 0, 0, 0);
        int evicted = tree.AddNode("note", folder, false, 135_699, 0, 0, NodeFlags.NotDownloaded);
        tree.AddNode("local.txt", folder, false, 100, 4096, 0);

        var logical = tree.RollUpSizes(SizeBasis.Logical);
        var allocated = tree.RollUpSizes(SizeBasis.Allocated);

        Assert.Equal(135_699, logical[evicted]);
        Assert.Equal(0, allocated[evicted]);
        Assert.Equal(135_799, logical[folder]);
        Assert.Equal(4096, allocated[folder]);
        Assert.Equal(logical[folder], logical[root]);
        Assert.Equal(allocated[folder], allocated[root]);
    }

    [Fact]
    public void EvictedDirectoryContributesItsOwnSizeWhenNotDescended()
    {
        var tree = new FileTree();
        int root = AddRoot(tree);
        int evictedDir = tree.AddNode("Offloaded", root, true, 8_000, 0, 0, NodeFlags.NotDownloaded);

        Assert.Equal(8_000, tree.RollUpSizes(SizeBasis.Logical)[evictedDir]);
        Assert.Equal(0, tree.RollUpSizes(SizeBasis.Allocated)[evictedDir]);
        Assert.Equal(8_000, tree.RollUpSizes(SizeBasis.Logical)[root]);
    }

    [Fact]
    public void NameInterningDeduplicatesRepeatedNames()
    {
        var tree = new FileTree();
        int root = AddRoot(tree);
        tree.AddNode("node_modules".AsSpan(), root, true, 0, 0, 0);
        tree.AddNode("node_modules".AsSpan(), root, true, 0, 0, 0);

        // Both nodes point at the SAME interned string entry.
        Assert.Equal(1, tree.NameTable.Count(n => n == "node_modules"));
    }

    [Fact]
    public void AncestorChainIsRootFirstAndStopsAtRoot()
    {
        var tree = new FileTree();
        int root = AddRoot(tree);
        int mid = tree.AddNode("mid", root, true, 0, 0, 0);
        int leaf = tree.AddNode("leaf", mid, false, 1, 1, 0);

        Assert.Equal([root, mid, leaf], tree.AncestorIds(leaf));
        Assert.Equal([root], tree.AncestorIds(root));
    }

    [Fact]
    public void CompactDropsSpareCapacityWithoutLosingLinks()
    {
        var tree = new FileTree();
        int root = AddRoot(tree);
        for (int i = 0; i < 1000; i++)
            tree.AddNode($"f{i % 17}", root, false, i, i, 0);
        var before = tree.GetStorageFootprint();
        Assert.True(before.PackedNodeBytesReserved > before.PackedNodeBytesExact);

        tree.Compact();
        var after = tree.GetStorageFootprint();
        long slackBefore = before.PackedNodeBytesReserved - before.PackedNodeBytesExact;
        long slackAfter = after.PackedNodeBytesReserved - after.PackedNodeBytesExact;
        Assert.True(slackAfter < slackBefore);
        Assert.True(slackAfter * 8 < slackBefore, "compact should drop doubling slack");
        Assert.Equal(before.NodeCount, after.NodeCount);
        Assert.Equal(root, tree.Parent[1]);
        Assert.Equal("f0", tree.NameOf(1));
        Assert.Equal(499, tree.LogicalSize[500]);
    }
}

public class SquarifiedTreemapTests
{
    private static List<(int Id, long Size)> Items(params long[] sizes) =>
        sizes.Select((s, i) => ((int)i, s)).ToList();

    [Fact]
    public void LayoutCoversFullAreaWithoutOverlap()
    {
        var items = Items(6, 6, 4, 3, 2, 2, 1);
        var bounds = new DmRect(0, 0, 6, 4);
        var rects = SquarifiedTreemap.Layout(items, bounds);

        Assert.Null(TilingError(rects, items.Count, bounds));
    }

    /// <summary>
    /// Paper section 3.1 / Figure 3: sizes [6, 6, 4, 3, 2, 2, 1] in a 6×4
    /// rect. Row membership is the paper's ([6, 6], [4, 3], [2], [2], [1]).
    /// </summary>
    [Fact]
    public void PaperReferenceLayout()
    {
        var items = new List<(int Id, long Size)> { (6, 1), (0, 6), (4, 2), (1, 6), (2, 4), (3, 3), (5, 2) };
        var rects = SquarifiedTreemap.Layout(items, new DmRect(0, 0, 6, 4));
        var byId = rects.ToDictionary(r => r.Id, r => r.Rect);

        var expected = new Dictionary<int, DmRect>
        {
            [0] = new(0, 0, 3, 2),
            [1] = new(0, 2, 3, 2),
            [2] = new(3, 0, 12.0 / 7.0, 7.0 / 3.0),
            [3] = new(3 + 12.0 / 7.0, 0, 9.0 / 7.0, 7.0 / 3.0),
            [4] = new(3, 7.0 / 3.0, 6.0 / 5.0, 5.0 / 3.0),
            [5] = new(3 + 6.0 / 5.0, 7.0 / 3.0, 6.0 / 5.0, 5.0 / 3.0),
            [6] = new(3 + 12.0 / 5.0, 7.0 / 3.0, 3.0 / 5.0, 5.0 / 3.0),
        };

        Assert.Equal(expected.Count, byId.Count);
        foreach (var (id, want) in expected)
        {
            Assert.True(byId.ContainsKey(id), $"missing rect for id {id}");
            Assert.True(RectsMatch(byId[id], want), $"id {id}: got {byId[id]} want {want}");
        }
    }

    /// <summary>Short side is the width — first row is a horizontal strip.</summary>
    [Fact]
    public void TallRectangleLaysFirstRowHorizontally()
    {
        var items = Items(6, 6, 4, 3, 2, 2, 1);
        var bounds = new DmRect(10, 20, 4, 6);
        var rects = SquarifiedTreemap.Layout(items, bounds);
        var byId = rects.ToDictionary(r => r.Id, r => r.Rect);

        Assert.True(RectsMatch(byId[0], new DmRect(10, 20, 2, 3)));
        Assert.True(RectsMatch(byId[1], new DmRect(12, 20, 2, 3)));
        Assert.Null(TilingError(rects, items.Count, bounds));
    }

    [Fact]
    public void SingleItemFillsWholeRect()
    {
        var rects = SquarifiedTreemap.Layout([(0, 100L)], new DmRect(2, 3, 50, 20));
        Assert.Single(rects);
        Assert.Equal(new DmRect(2, 3, 50, 20), rects[0].Rect);
    }

    [Fact]
    public void EmptyItemsProducesNoRects()
    {
        Assert.Empty(SquarifiedTreemap.Layout([], new DmRect(0, 0, 50, 20)));
    }

    [Fact]
    public void HitTestReturnsTheRectangleContainingThePoint()
    {
        var items = new List<(int Id, long Size)> { (10, 6), (11, 6), (12, 4) };
        var rects = SquarifiedTreemap.Layout(items, new DmRect(0, 0, 6, 4));
        var interior = rects[0].Rect;
        Assert.Equal(rects[0].Id, SquarifiedTreemap.HitTest(rects, new DmPoint(interior.MinX + 0.1, interior.MinY + 0.1)));
        Assert.Null(SquarifiedTreemap.HitTest(rects, new DmPoint(-1, -1)));
    }

    [Fact]
    public void NonPositiveSizesAreDropped()
    {
        var rects = SquarifiedTreemap.Layout(
            [(0, 0L), (1, 4L), (2, -3L)],
            new DmRect(0, 0, 8, 2));
        Assert.Single(rects);
        Assert.Equal(1, rects[0].Id);
        Assert.Equal(new DmRect(0, 0, 8, 2), rects[0].Rect);
    }

    private static string? TilingError(List<TreemapRect> rects, int itemCount, DmRect bounds)
    {
        if (rects.Count != itemCount)
            return $"expected {itemCount} rects, got {rects.Count}";

        const double accuracy = 1e-6;
        double totalArea = 0;
        foreach (var rect in rects)
        {
            var r = rect.Rect;
            if (r.Width <= 0 || r.Height <= 0)
                return $"id {rect.Id} has non-positive size {r}";
            if (r.MinX < bounds.MinX - accuracy || r.MinY < bounds.MinY - accuracy
                || r.MaxX > bounds.MaxX + accuracy || r.MaxY > bounds.MaxY + accuracy)
                return $"id {rect.Id} escapes bounds: {r}";
            totalArea += r.Width * r.Height;
        }

        for (int i = 0; i < rects.Count; i++)
        {
            for (int j = i + 1; j < rects.Count; j++)
            {
                var overlap = rects[i].Rect.Intersection(rects[j].Rect);
                double area = overlap.Width * overlap.Height;
                if (area > accuracy)
                    return $"ids {rects[i].Id} and {rects[j].Id} overlap by {area}";
            }
        }

        double expectedArea = bounds.Width * bounds.Height;
        if (Math.Abs(totalArea - expectedArea) > accuracy)
            return $"area {totalArea} != bounds {expectedArea}";
        return null;
    }

    private static bool RectsMatch(DmRect got, DmRect want, double accuracy = 1e-6) =>
        Math.Abs(got.MinX - want.MinX) <= accuracy
        && Math.Abs(got.MinY - want.MinY) <= accuracy
        && Math.Abs(got.Width - want.Width) <= accuracy
        && Math.Abs(got.Height - want.Height) <= accuracy;
}

public class ChartLayoutTests
{
    [Fact]
    public void SmallSiblingsCollapseIntoOther()
    {
        var tree = new FileTree();
        int root = tree.AddNode("root", -1, true, 0, 0, 0);
        int big = tree.AddNode("big", root, true, 0, 0, 0);
        tree.AddNode("payload", big, false, 10_000, 10_000, 0);
        tree.AddNode("dust", root, false, 1, 1, 0);
        var totals = tree.RollUpSizes();
        var slices = ChartLayout.SlicesOf(root, tree, totals);
        Assert.Contains(slices, s => s.Label == "big" && s.Drillable);
        Assert.Contains(slices, s => s.NodeID is null && !s.Drillable && s.Label.Contains("Other"));
    }
}

public class CirclePackTests
{
    [Fact]
    public void PackedCirclesDoNotOverlap()
    {
        var slices = Enumerable.Range(0, 6)
            .Select(i => new ChartSlice($"{i}", i, (i + 1) * 100, $"{i}", false, []))
            .ToList();
        var circles = CirclePack.Pack(slices);
        Assert.Equal(6, circles.Count);
        for (int i = 0; i < circles.Count; i++)
        {
            for (int j = i + 1; j < circles.Count; j++)
            {
                double dx = circles[i].X - circles[j].X;
                double dy = circles[i].Y - circles[j].Y;
                double gap = circles[i].Radius + circles[j].Radius - 1e-4;
                Assert.True(dx * dx + dy * dy >= gap * gap, $"circles {i},{j} overlap");
            }
        }
    }
}

public class ProcessMemoryTests
{
    [Fact]
    public void CurrentReturnsResidentAndPeak()
    {
        var snapshot = ProcessMemory.Current();
        Assert.NotNull(snapshot);
        Assert.True(snapshot.Value.ResidentBytes > 0);
        Assert.True(snapshot.Value.PeakResidentBytes >= snapshot.Value.ResidentBytes);
        // PrivateUsage (commit charge) can legitimately be below the working
        // set on Windows — shared pages count toward WS but not private.
        Assert.True(snapshot.Value.VirtualBytes > 0);
    }
}
