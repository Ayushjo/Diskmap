using DiskMap.Core;

namespace DiskMap.Core.Tests;

/// <summary>
/// The Find query language — parse, describe, run. Mirrors the macOS
/// FileQueryTests: half-typed tokens produce problems, not empty results;
/// a folder inside a matched folder counts its bytes once.
/// </summary>
public class FileQueryTests
{
    private static FileQuery.Parsed Parse(string text, string root = @"C:\scan") =>
        FileQuery.Parse(text, home: @"C:\Users\u", root: root);

    [Fact]
    public void ParsesStructuredTokens()
    {
        var (q, problems) = Parse("ext:mp4,mov size>500MB age>1y in:downloads is:hardlink name:*.log -tmp");
        Assert.Empty(problems);
        Assert.Equal(["mp4", "mov"], q.Extensions);
        Assert.Equal(500L * 1_000_000, q.SizeBounds[0].Value);
        Assert.Equal(FileQuery.Comparison.Greater, q.SizeBounds[0].Comparison);
        Assert.Equal(365, q.AgeBounds[0].Value);
        Assert.Equal([FileQuery.Place.Downloads], q.Places);
        Assert.Equal([FileQuery.Flag.HardLink], q.Flags);
        Assert.Equal(["*.log"], q.NamePatterns);
        Assert.Equal(["tmp"], q.ExcludedWords);
        Assert.Equal(FileQuery.NodeType.Files, q.EffectiveType); // describing files implies files
        Assert.True(q.IsStructured);
    }

    [Fact]
    public void HalfTypedTokensBecomeProblemsNotEmptyResults()
    {
        var (q, problems) = Parse("size> kind:zzz in:mars report");
        Assert.Equal(3, problems.Count);
        // The surviving pieces still apply — "report" is a word filter.
        Assert.Equal(["report"], q.Words);
        Assert.Empty(q.SizeBounds);
    }

    [Fact]
    public void BareWordsAndTypePrefix()
    {
        var (q, _) = Parse("holiday photos type:folders");
        Assert.Equal(FileQuery.NodeType.Folders, q.EffectiveType);
        Assert.Equal(["holiday", "photos"], q.Words);
        // A word that merely starts with a key is not a key.
        var (q2, problems2) = Parse("sizeable ageing");
        Assert.Empty(problems2);
        Assert.Equal(["sizeable", "ageing"], q2.Words);
    }

    [Fact]
    public void PathValuesAnchorUnderTheScanRoot()
    {
        var (q, _) = Parse(@"path:src\deep path:""C:\abs\with space"" path:~\Docs");
        Assert.Equal(@"C:\scan\src\deep", q.Paths[0]);
        Assert.Equal(@"C:\abs\with space", q.Paths[1]);
        Assert.Equal(@"C:\Users\u\Docs", q.Paths[2]);
    }

    [Fact]
    public void HumanUnitsParseTheCliContract()
    {
        Assert.Equal(50L * 1_000_000_000, HumanUnits.Bytes("50GB"));
        Assert.Equal(2L * 1_073_741_824, HumanUnits.Bytes("2GiB"));
        Assert.Equal(1500, HumanUnits.Bytes("1.5KB"));
        Assert.Equal(123, HumanUnits.Bytes("123"));
        Assert.Null(HumanUnits.Bytes("large"));
        Assert.Equal(30, HumanUnits.Days("30d"));
        Assert.Equal(14, HumanUnits.Days("2w"));
        Assert.Equal(180, HumanUnits.Days("6m"));
        Assert.Equal(365, HumanUnits.Days("1y"));
        Assert.Null(HumanUnits.Days("1x"));
    }

    [Fact]
    public void GlobMatching()
    {
        Assert.True(FileQuery.GlobMatch("*.log", "x.log"));
        Assert.False(FileQuery.GlobMatch("*.log", "x.log.bak"));
        Assert.True(FileQuery.GlobMatch("data-?.txt", "data-9.txt"));
        Assert.False(FileQuery.GlobMatch("data-?.txt", "data-10.txt"));
        Assert.True(FileQuery.GlobMatch("photo-[0-9][0-9].jpg", "photo-42.jpg"));
        Assert.True(FileQuery.GlobMatch("[!a-z]*", "9lives"));
        Assert.False(FileQuery.GlobMatch("[!a-z]*", "lives"));
        Assert.True(FileQuery.GlobMatch("*core*", "the.core.dump"));
        Assert.False(FileQuery.GlobMatch("[abc", "abc"));   // unclosed set never crashes
    }

    private static FileTree SmallTree()
    {
        var tree = new FileTree();
        int root = tree.AddNode("scan", -1, true, 0, 0, 0);
        int downloads = tree.AddNode("Downloads", root, true, 0, 0, 0);
        int bigVid = tree.AddNode("movie.mp4", downloads, false, 2_000_000_000, 2_000_000_000,
            AgeMap.Today() - 500);
        int docs = tree.AddNode("Documents", root, true, 0, 0, 0);
        int bigLog = tree.AddNode("server.log", docs, false, 800_000_000, 800_000_000,
            AgeMap.Today() - 40);
        int oldZip = tree.AddNode("backup.zip", docs, false, 300_000_000, 300_000_000,
            AgeMap.Today() - 900);
        tree.AddNode("readme.md", root, false, 1_000, 1_000, AgeMap.Today());
        tree.AddFlags(bigVid, NodeFlags.HardLink);
        tree.AddFlags(oldZip, NodeFlags.NotDownloaded);
        return tree;
    }

    [Fact]
    public void RunFiltersAndRanks()
    {
        var tree = SmallTree();
        var totals = tree.RollUpSizes(SizeBasis.Allocated);
        var q = Parse("size>100MB", @"C:\scan").Query;
        var result = q.Run(tree, @"C:\scan", totals, new FileQuery.Context());
        // Only files — folder totals nest and must not double-match.
        Assert.Equal(3, result.MatchCount);
        Assert.All(result.Ids, id => Assert.False(tree.IsDirectory[id]));
        Assert.Equal(totals[0] - 1_000, result.MatchedBytes);
        // Largest first.
        Assert.Equal("movie.mp4", tree.NameOf(result.Ids[0]));
    }

    [Fact]
    public void InPlaceFiltersBySubtree()
    {
        var tree = SmallTree();
        var totals = tree.RollUpSizes(SizeBasis.Allocated);
        // in:downloads is home-relative (C:\Users\u\Downloads), which is
        // outside this scan — the note says so, and path: covers the rest.
        var (q, problems) = Parse(@"in:downloads path:C:\scan\Documents", @"C:\scan");
        Assert.Empty(problems);
        var result = q.Run(tree, @"C:\scan", totals, new FileQuery.Context());
        Assert.Contains(result.Notes, n => n.Contains("outside"));
        Assert.Equal(3, result.MatchCount);   // Documents + server.log + backup.zip
        Assert.DoesNotContain(result.Ids, id => tree.NameOf(id) == "readme.md");
    }

    [Fact]
    public void PathOutsideTheScanProducesANote()
    {
        var tree = SmallTree();
        var totals = tree.RollUpSizes(SizeBasis.Allocated);
        var (q, _) = Parse(@"path:D:\elsewhere size>0", @"C:\scan");
        var result = q.Run(tree, @"C:\scan", totals, new FileQuery.Context());
        Assert.Contains(result.Notes, n => n.Contains("outside"));
        Assert.Equal(0, result.MatchCount);
    }

    [Fact]
    public void MatchedBytesDontDoubleCountNestedFolders()
    {
        var tree = SmallTree();
        var totals = tree.RollUpSizes(SizeBasis.Allocated);
        var q = Parse("type:folders", @"C:\scan").Query;
        var result = q.Run(tree, @"C:\scan", totals, new FileQuery.Context());
        // Downloads and Documents match; readme doesn't. Both folders'
        // bytes are inside no other match, so the sum is their own totals.
        Assert.Equal(2, result.MatchCount);
        Assert.Equal(totals[result.Ids[0]] + totals[result.Ids[1]], result.MatchedBytes);
    }

    [Fact]
    public void FlagsUseRealNodeFlags()
    {
        var tree = SmallTree();
        var totals = tree.RollUpSizes(SizeBasis.Allocated);
        var hardlinked = Parse("is:hardlink", @"C:\scan").Query
            .Run(tree, @"C:\scan", totals, new FileQuery.Context());
        Assert.Equal(1, hardlinked.MatchCount);
        Assert.Equal("movie.mp4", tree.NameOf(hardlinked.Ids[0]));

        var cloud = Parse("is:cloud", @"C:\scan").Query
            .Run(tree, @"C:\scan", totals, new FileQuery.Context());
        Assert.Equal("backup.zip", tree.NameOf(cloud.Ids[0]));

        // Duplicate asks for a set the scan may not have run yet — note, not empty-crash.
        var dup = Parse("is:duplicate", @"C:\scan").Query
            .Run(tree, @"C:\scan", totals, new FileQuery.Context());
        Assert.Contains(dup.Notes, n => n.Contains("Duplicate"));
    }

    [Fact]
    public void ChipsToggleTokens()
    {
        string text = "holiday size>100MB";
        Assert.Equal("holiday size>100MB is:duplicate", FileQuery.Toggling("is:duplicate", text));
        Assert.Equal("holiday", FileQuery.Toggling("size>100MB", text));
        Assert.True(FileQuery.ContainsToken("size>100MB", text));
        Assert.False(FileQuery.ContainsToken("size>1TB", text));
    }
}
