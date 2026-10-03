using DiskMap.Core;

namespace DiskMap.Core.Tests;

/// <summary>
/// WIN-044: lazy name-aligned snapshot compare — rows sum to their
/// folder; hotspots stop where the change happened.
/// </summary>
public class SnapshotComparisonTests
{
    /// <summary>
    ///     root
    ///     ├── app/       (manifest + src that grew)
    ///     └── downloads/ (a file removed)
    /// </summary>
    private static (DiskSnapshot Before, DiskSnapshot After) Pair()
    {
        var before = new FileTree();
        int root = before.AddNode("scan", -1, true, 0, 0, 0);
        int app = before.AddNode("app", root, true, 0, 0, 0);
        before.AddNode("main.cs", app, false, 5_000, 5_000, 1);
        int dl = before.AddNode("downloads", root, true, 0, 0, 0);
        before.AddNode("old.iso", dl, false, 400_000_000, 400_000_000, 1);
        before.AddNode("keep.txt", dl, false, 100, 100, 1);

        var after = new FileTree();
        root = after.AddNode("scan", -1, true, 0, 0, 0);
        app = after.AddNode("app", root, true, 0, 0, 0);
        after.AddNode("main.cs", app, false, 5_000, 5_000, 1);
        after.AddNode("new.obj", app, false, 80_000_000, 80_000_000, 2);
        dl = after.AddNode("downloads", root, true, 0, 0, 0);
        after.AddNode("keep.txt", dl, false, 100, 100, 1);

        return (new DiskSnapshot(@"C:\scan", DateTimeOffset.Now.AddDays(-7), before),
                new DiskSnapshot(@"C:\scan", DateTimeOffset.Now, after));
    }

    [Fact]
    public void ChildrenAlignByNameAndSumToParent()
    {
        var (before, after) = Pair();
        var cmp = new SnapshotComparison(before, after, SizeBasis.Allocated);
        var root = cmp.Root;
        Assert.Equal(80_000_000 - 400_000_000, root.Delta);   // net

        var rows = cmp.ChildrenOf(root);
        Assert.Equal(2, rows.Count);                          // keep.txt skipped (unchanged)
        var app = rows.Single(r => r.Name == "app");
        var downloads = rows.Single(r => r.Name == "downloads");
        Assert.Equal(80_000_000, app.Delta);
        Assert.Equal(SnapshotChangeKind.Grew, app.Kind);
        Assert.Equal(-400_000_000, downloads.Delta);
        Assert.Equal(root.Delta, rows.Sum(r => r.Delta));     // rows sum to the folder
    }

    [Fact]
    public void DrillingDescendsToWhereChangeHappened()
    {
        var (before, after) = Pair();
        var cmp = new SnapshotComparison(before, after, SizeBasis.Allocated);
        var app = cmp.EntryAt("app");
        Assert.NotNull(app);
        var appRows = cmp.ChildrenOf(app!);
        Assert.Single(appRows);
        Assert.Equal("new.obj", appRows[0].Name);
        Assert.Equal(SnapshotChangeKind.Added, appRows[0].Kind);

        var dl = cmp.EntryAt("downloads");
        var dlRows = cmp.ChildrenOf(dl!);
        Assert.Single(dlRows);
        Assert.Equal("old.iso", dlRows[0].Name);
        Assert.Equal(SnapshotChangeKind.Removed, dlRows[0].Kind);
    }

    [Fact]
    public void HotspotsNameTheLeafChangesNotTheirAncestors()
    {
        var (before, after) = Pair();
        var cmp = new SnapshotComparison(before, after, SizeBasis.Allocated);
        var spots = cmp.Hotspots(10_000_000);
        // The story is the leaf-level changes, not "root ±320 MB".
        Assert.Contains(spots, e => e.Path == "downloads/old.iso" || e.Path == "downloads");
        Assert.Contains(spots, e => e.Path == "app/new.obj" || e.Path == "app");
        Assert.DoesNotContain(spots, e => e.Path == "");
    }
}
