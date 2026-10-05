using System.Security.Principal;
using DiskMap.Core;

namespace DiskMap.Core.Tests;

/// <summary>
/// WIN-031: USN-journal incremental rescan. Needs elevation + an NTFS
/// system drive; unelevated it verifies the graceful fall-through to a
/// full walk instead.
/// </summary>
public class IncrementalScanTests : IDisposable
{
    private readonly string _dir;
    private readonly ScanEngine _engine = new();

    public IncrementalScanTests()
    {
        _dir = Path.Combine(Path.GetTempPath(), "diskmap-usn-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(_dir);
    }

    [Fact]
    public async Task RescanAppliesCreatesAndDeletesFromTheJournal()
    {
        File.WriteAllText(Path.Combine(_dir, "keep.txt"), new string('k', 4096));
        File.WriteAllText(Path.Combine(_dir, "doomed.txt"), new string('d', 4096));
        Directory.CreateDirectory(Path.Combine(_dir, "sub", "deep"));
        File.WriteAllText(Path.Combine(_dir, "sub", "deep", "old.txt"), "o");
        var first = await _engine.ScanAsync(_dir, (IProgress<int>?)null);

        bool elevated = new WindowsPrincipal(WindowsIdentity.GetCurrent())
            .IsInRole(WindowsBuiltInRole.Administrator);
        bool ntfs = new DriveInfo(Path.GetPathRoot(_dir)!).DriveFormat == "NTFS";
        bool journalUsable = elevated && ntfs;

        if (ScanCache.Load(_dir) is null)
        {
            // No baseline ⇒ not elevated / not NTFS: the rescan must then
            // simply not engage — every scan is a walk.
            Assert.False(journalUsable,
                "elevated + NTFS should have produced a baseline cache");
            var again = await _engine.ScanAsync(_dir, (IProgress<int>?)null);
            Assert.Equal("win32", again.Backend);
            return;
        }

        // Touch the disk, let the journal settle, rescan.
        File.WriteAllText(Path.Combine(_dir, "new.bin"), new string('n', 8192));
        File.Delete(Path.Combine(_dir, "doomed.txt"));
        File.WriteAllText(Path.Combine(_dir, "keep.txt"), new string('k', 16384));  // modified in place
        File.WriteAllText(Path.Combine(_dir, "sub", "deep", "added.txt"), "a");        // deep create
        await Task.Delay(750);

        var second = await _engine.ScanAsync(_dir, (IProgress<int>?)null);
        Assert.Equal("usn", second.Backend);
        var names = Enumerable.Range(0, second.Tree.Count)
            .Select(second.Tree.NameOf).ToHashSet();
        // All three changes sit directly under the scan root, whose node
        // carries no file id — the replay must still place them.
        Assert.Contains("new.bin", names);
        Assert.Contains("keep.txt", names);
        Assert.DoesNotContain("doomed.txt", names);
        int keep = Enumerable.Range(0, second.Tree.Count).Single(i => second.Tree.NameOf(i) == "keep.txt");
        Assert.Equal(16384, second.Tree.LogicalSize[keep]);
        Assert.Contains("added.txt", names);
        Assert.Contains("old.txt", names);   // unchanged sibling copied from the baseline
    }

    [Fact]
    public void CacheRoundTripsTreeAndMarker()
    {
        var tree = new FileTree();
        int root = tree.AddNode("tmp", -1, true, 0, 0, 0);
        tree.AddNode("a.txt", root, false, 100, 100, 1, fileId: 42);
        ScanCache.Save(_dir, tree, new UsnJournal.Marker(12345, 6789));

        var baseline = ScanCache.Load(_dir);
        Assert.NotNull(baseline);
        Assert.Equal(12345, baseline!.Marker.JournalId);
        Assert.Equal(6789, baseline.Marker.NextUsn);
        Assert.Equal(2, baseline.Snapshot.Tree.Count);
        Assert.Equal(42, baseline.Snapshot.Tree.FileId[1]);

        // A marker for a different root must not load under this key.
        Assert.Null(ScanCache.Load(_dir + "-other"));
    }

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch { }
    }
}
