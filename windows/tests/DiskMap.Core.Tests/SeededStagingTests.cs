using DiskMap.Core;

namespace DiskMap.Core.Tests;

/// <summary>
/// WIN-013: staging a folder measures from the scan tree when the journal
/// proves the subtree unchanged. The journal read is seam-replaced
/// (JournalChangesForTest) — the volume ioctl needs admin; the seeded
/// math itself runs unelevated.
/// </summary>
public class SeededStagingTests : IDisposable
{
    private readonly string _dir;

    public SeededStagingTests()
    {
        _dir = Path.Combine(Path.GetTempPath(), "diskmap-seed-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(Path.Combine(_dir, "sub"));
        File.WriteAllBytes(Path.Combine(_dir, "sub", "a.bin"), new byte[8192]);
        File.WriteAllBytes(Path.Combine(_dir, "sub", "b.bin"), new byte[4096]);
        File.WriteAllBytes(Path.Combine(_dir, "other.bin"), new byte[2048]);
    }

    private FileTree Scan() =>
        Win32Scanner.Walk(_dir, null, null, CancellationToken.None)!.Tree;

    private int NodeOf(FileTree tree, string name) =>
        Enumerable.Range(0, tree.Count).First(i => tree.NameOf(i) == name);

    [Fact]
    public void UnchangedSubtreeMeasuresFromTheTree()
    {
        var tree = Scan();
        var queue = new CleanupQueue();
        queue.SetScanContext(tree, _dir, new UsnJournal.Marker(1, 1), []);
        queue.JournalChangesForTest = _ => [];   // journal says: nothing changed

        var profile = queue.TrySeededProfile(Path.Combine(_dir, "sub"));
        Assert.NotNull(profile);
        Assert.True(profile!.IsComplete);
        // The tree's numbers, not a guess: the two files' real allocation.
        Assert.Equal(8192 + 4096, profile.AllocatedBytes);
        Assert.Equal(8192 + 4096, profile.OwnedBytes);
        Assert.Equal(2, profile.FileCount);
    }

    [Fact]
    public void ChangedSubtreeFallsBackToTheWalk()
    {
        var tree = Scan();
        var queue = new CleanupQueue();
        queue.SetScanContext(tree, _dir, new UsnJournal.Marker(1, 1), []);
        // Journal reports the dir's own frn changed — the seeded path
        // must refuse.
        long subFrn = tree.FileId[NodeOf(tree, "sub")];
        queue.JournalChangesForTest = _ => [subFrn];

        Assert.Null(queue.TrySeededProfile(Path.Combine(_dir, "sub")));
    }

    [Fact]
    public void NoJournalAnswerIsHonestFallback()
    {
        var tree = Scan();
        var queue = new CleanupQueue();
        queue.SetScanContext(tree, _dir, new UsnJournal.Marker(1, 1), []);
        queue.JournalChangesForTest = _ => null;   // journal unreadable
        Assert.Null(queue.TrySeededProfile(Path.Combine(_dir, "sub")));
    }

    [Fact]
    public void OutsideTheScanRootNeverSeeds()
    {
        var tree = Scan();
        var queue = new CleanupQueue();
        queue.SetScanContext(tree, _dir, new UsnJournal.Marker(1, 1), []);
        queue.JournalChangesForTest = _ => [];
        Assert.Null(queue.TrySeededProfile(Path.GetTempPath()));   // parent of the scan root
    }

    [Fact]
    public async Task NoContextStillStagesViaTheWalk()
    {
        var queue = new CleanupQueue();
        Assert.True(queue.Stage(Path.Combine(_dir, "sub"), 0, "test"));
        await queue.WaitForMeasurements();
        var item = queue.AllItems().Single();
        Assert.False(item.IsMeasuring);
        Assert.NotNull(item.Sharing);
        Assert.Equal(8192 + 4096, item.Sharing!.AllocatedBytes);
    }

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch { }
    }
}
