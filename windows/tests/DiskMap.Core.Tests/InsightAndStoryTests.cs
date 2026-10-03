using DiskMap.Core;

namespace DiskMap.Core.Tests;

/// <summary>
/// WIN-026/027: folder insight summaries and the narrator rules over
/// AnalysisSnapshot.
/// </summary>
public class InsightAndStoryTests
{
    private static FileTree InsightTree()
    {
        var tree = new FileTree();
        int root = tree.AddNode("scan", -1, true, 0, 0, 0);
        int docs = tree.AddNode("Docs", root, true, 0, 0, 0);
        // mostly old videos + one recent file
        tree.AddNode("holiday.mp4", docs, false, 500_000_000, 500_000_000, 1);
        tree.AddNode("old.zip", docs, false, 50_000_000, 50_000_000, 1);
        tree.AddNode("readme.txt", docs, false, 1_000, 1_000, AgeMap.Today());
        return tree;
    }

    [Fact]
    public void InsightReportsCompositionAndHonestReviewable()
    {
        var tree = InsightTree();
        var totals = tree.RollUpSizes(SizeBasis.Allocated);
        var (files, folders) = tree.RollUpCounts();
        int docs = 1;
        var insight = FolderInsight.Build(docs, tree, @"C:\scan", totals, files, folders);
        Assert.NotNull(insight);
        Assert.Equal(3, insight!.FileCount);
        Assert.Equal(totals[docs], insight.Bytes);
        // Mostly video.
        Assert.Contains("video", insight.WhyLarge, StringComparison.OrdinalIgnoreCase);
        // Only files untouched >1y count as reviewable (mp4+zip, day=1);
        // the fresh readme doesn't.
        Assert.Equal(550_000_000, insight.ReviewableBytes);
        Assert.Equal(FolderSafety.Review, insight.Safety);
        Assert.Equal("holiday.mp4", insight.LargestFiles[0].Name);
    }

    [Fact]
    public void ProtectedFoldersNeverClaimReviewableBytes()
    {
        var tree = new FileTree();
        int root = tree.AddNode("C:", -1, true, 0, 0, 0);
        int win = tree.AddNode("Windows", root, true, 0, 0, 0);
        tree.AddNode("sys32.dll", win, false, 5_000_000, 5_000_000, 1);
        var totals = tree.RollUpSizes(SizeBasis.Allocated);
        var (files, folders) = tree.RollUpCounts();
        // Scan root = C:\ → Windows dir resolves under the real drive
        // letter C:\Windows — excluded by the queue's prefix list.
        var insight = FolderInsight.Build(win, tree, "C:\\", totals, files, folders);
        Assert.NotNull(insight);
        Assert.Equal(FolderSafety.Protected, insight!.Safety);
        Assert.Equal(0, insight.ReviewableBytes);
    }

    [Fact]
    public void StoriesRankTheHeadlinesDeterministically()
    {
        var snap = new AnalysisSnapshot
        {
            ScanRootPath = "C:\\",
            Volume = new VolumeInfo { DriveLabel = "C:", TotalBytes = 500_000_000_000L, FreeBytes = 15_000_000_000L },
            ScannedBytes = 400_000_000_000L,
            QuickWinBytes = 20_000_000_000L,
            ForgottenBytes = 60_000_000_000L,
            Categories =
            [
                new StorageCategory("documents", "Personal", 200_000_000_000L, "documents"),
                new StorageCategory("downloads", "Downloads", 80_000_000_000L, "downloads"),
                new StorageCategory("caches", "Caches & Temp", 40_000_000_000L, "caches"),
            ],
            Mode = CategoryMode.WholeDisk,
            TopFiles = [new StorageFileHit(5, "vm.vhdx", 30_000_000_000L, @"C:\vms\vm.vhdx", 1)],
            Health = StorageHealth.Critical,
        };

        var stories = StorageNarrator.Stories(snap);
        Assert.Contains(stories, s => s.Id == "capacity");       // 3% free → critical leads
        Assert.Contains(stories, s => s.Id == "quickwins");
        Assert.Contains(stories, s => s.Id == "forgotten");
        Assert.Contains(stories, s => s.Kind == StoryKind.Category);

        var recs = StorageNarrator.Recommendations(snap);
        Assert.True(recs.Count >= 2);
        // High-confidence safe recommendations rank above review ones.
        Assert.Equal(StoryConfidence.High, recs[0].Confidence);
        // Scores strictly ordered.
        Assert.True(recs.Zip(recs.Skip(1)).All(p => p.First.Score >= p.Second.Score));
    }

    [Fact]
    public void StoriesSayNothingOnAnEmptySnapshot()
    {
        var snap = new AnalysisSnapshot { ScannedBytes = 0 };
        Assert.Empty(StorageNarrator.Stories(snap));
        Assert.Empty(StorageNarrator.Recommendations(snap));
    }
}
