using System.Runtime.InteropServices;
using DiskMap.Core;

namespace DiskMap.Core.Tests;

public class ScanDecisionTests
{
    [Fact]
    public void ReparsePointIsSkippedAndNotDescended()
    {
        var decision = ScanEngine.Decide(
            isDirectory: false, isReparsePoint: true, isCloudPlaceholder: false,
            logicalSize: 10, allocatedSize: 4096);
        Assert.False(decision.Include);
        Assert.True(decision.SkipDescendants);
    }

    [Fact]
    public void CloudPlaceholderKeepsLogicalSizeAndZeroAllocated()
    {
        // OneDrive-evicted file: listed, not downloaded. Mirrors the macOS
        // evicted-ubiquitous-item fixture replay.
        var decision = ScanEngine.Decide(
            isDirectory: false, isReparsePoint: true, isCloudPlaceholder: true,
            logicalSize: 135_699, allocatedSize: 0);
        Assert.True(decision.Include);
        Assert.True(decision.NotDownloaded);
        Assert.Equal(135_699, decision.LogicalSize);
        Assert.Equal(0, decision.AllocatedSize);
        Assert.False(decision.SkipDescendants);
    }

    [Fact]
    public void CloudDirectoryIsRecordedButNotDescended()
    {
        var decision = ScanEngine.Decide(
            isDirectory: true, isReparsePoint: true, isCloudPlaceholder: true,
            logicalSize: 0, allocatedSize: 0);
        Assert.True(decision.Include);
        Assert.True(decision.NotDownloaded);
        Assert.True(decision.SkipDescendants);
    }

    [Fact]
    public void OrdinaryFileIsNotFlagged()
    {
        var decision = ScanEngine.Decide(
            isDirectory: false, isReparsePoint: false, isCloudPlaceholder: false,
            logicalSize: 100, allocatedSize: 4096);
        Assert.False(decision.NotDownloaded);
        Assert.Equal(4096, decision.AllocatedSize);
        Assert.False(decision.SkipDescendants);
    }
}

public class ScanEngineFixtureTests
{
    [Fact]
    public async Task FixtureCoversSymlinkAndOrdinaryFiles()
    {
        var fixture = new ScanFixture();
        try
        {
            var engine = new ScanEngine();
            var result = await engine.ScanAsync(fixture.Root);
            var tree = result.Tree;

            Assert.True(result.ItemCount > 0);
            Assert.NotNull(result.ResidentBytesAfterWalk);
            Assert.True(result.ElapsedSeconds >= 0);

            var nested = FindNode(tree, "nested.txt", "inner");
            Assert.NotNull(nested);
            var inner = FindNode(tree, "inner", "outer");
            Assert.Equal(inner, tree.Parent[nested.Value]);

            var sibling = FindNode(tree, "sibling.txt", "outer");
            Assert.NotNull(sibling);

            // Symlinks are not recorded (skipped like macOS).
            Assert.Null(FindNode(tree, "points-at-nested", "inner"));
            Assert.Null(FindNode(tree, "broken-link", null));

            var visible = FindNode(tree, "visible.txt", Path.GetFileName(fixture.Root.TrimEnd('\\')));
            Assert.NotNull(visible);
            var fi = new FileInfo(Path.Combine(fixture.Root, "visible.txt"));
            Assert.Equal(fi.Length, tree.LogicalSize[visible.Value]);
        }
        finally
        {
            fixture.Dispose();
        }
    }

    private static int? FindNode(FileTree tree, string name, string? parentName)
    {
        for (int id = 0; id < tree.Count; id++)
        {
            if (tree.NameOf(id) != name) continue;
            if (parentName is null) return id;
            int parent = tree.Parent[id];
            if (parent >= 0 && tree.NameOf(parent) == parentName) return id;
        }
        return null;
    }

    [Fact]
    public void WalkGivesUpWhenItsHeadStartRunsOut()
    {
        var fixture = new ScanFixture();
        try
        {
            Assert.Null(Win32Scanner.Walk(fixture.Root, null, TimeSpan.Zero));
            Assert.NotNull(Win32Scanner.Walk(fixture.Root, null, TimeSpan.FromMinutes(1)));
        }
        finally
        {
            fixture.Dispose();
        }
    }

    private sealed class ScanFixture : IDisposable
    {
        public readonly string Root;

        public ScanFixture()
        {
            Root = Path.Combine(Path.GetTempPath(), $"DiskMap-scan-{Guid.NewGuid()}");
            Directory.CreateDirectory(Root);
            string outer = Path.Combine(Root, "outer");
            string inner = Path.Combine(outer, "inner");
            Directory.CreateDirectory(inner);
            File.WriteAllText(Path.Combine(inner, "nested.txt"), "nested");
            try
            {
                // Symbolic links need Developer Mode or admin on Windows;
                // skip silently if the fixture can't create them — the tree
                // assertions for links check absence either way.
                File.CreateSymbolicLink(
                    Path.Combine(inner, "points-at-nested"),
                    Path.Combine(inner, "nested.txt"));
                File.CreateSymbolicLink(
                    Path.Combine(Root, "broken-link"),
                    Path.Combine(Root, "does-not-exist"));
            }
            catch (Exception) { /* no privilege — links just won't exist */ }
            File.WriteAllText(Path.Combine(inner, "after-link.txt"), "after");
            File.WriteAllText(Path.Combine(outer, "sibling.txt"), "sib");
            File.WriteAllText(Path.Combine(Root, "visible.txt"), "seen");
        }

        public void Dispose()
        {
            try { Directory.Delete(Root, recursive: true); } catch { }
        }
    }
}

public class DuplicateFinderTests
{
    [Fact]
    public async Task HardLinkedPairSharesExtentsAndSkipsHash()
    {
        var fixture = new DuplicateFixture();
        try
        {
            // Hardlinks share one file record → identical extent maps.
            // This exercises the shared-storage path on plain NTFS.
            var result = await DuplicateFinder.ScanAsync(
            [
                (0, fixture.Original, fixture.ByteCount),
                (1, fixture.HardLink, fixture.ByteCount),
            ]);
            Assert.Equal(0, result.FullContentHashCalls);
            Assert.Single(result.Groups);
            Assert.True(result.Groups[0].SharesStorage);
            Assert.Equal([0, 1], result.Groups[0].FileIDs);
            Assert.Equal(0, result.Groups[0].ReclaimableBytes(new HashSet<int> { 0 }));
            Assert.Equal(fixture.ByteCount, result.Groups[0].ReclaimableBytes(new HashSet<int> { 0, 1 }));
        }
        finally { fixture.Dispose(); }
    }

    [Fact]
    public async Task IdenticalContentCopiesAreHashedAndGrouped()
    {
        var fixture = new DuplicateFixture();
        try
        {
            var result = await DuplicateFinder.ScanAsync(
            [
                (2, fixture.Original, fixture.ByteCount),
                (3, fixture.IdenticalCopy, fixture.ByteCount),
            ]);
            Assert.Equal(2, result.FullContentHashCalls);
            Assert.Single(result.Groups);
            Assert.False(result.Groups[0].SharesStorage);
            Assert.Equal(fixture.ByteCount, result.Groups[0].ReclaimableBytes(new HashSet<int> { 3 }));
        }
        finally { fixture.Dispose(); }
    }

    [Fact]
    public void KeeperIsTheOldestFile()
    {
        var group = new DuplicateGroup("h", [3, 1, 2], 10, false);
        var days = new Dictionary<int, int> { [3] = 100, [1] = 40, [2] = 40 };
        Assert.Equal(1, group.DefaultKeeperId(id => days.GetValueOrDefault(id)));
    }

    [Fact]
    public void CandidatesSkipDirectoriesAndNotDownloaded()
    {
        var tree = new FileTree();
        int root = tree.AddNode("root", -1, true, 0, 0, 0);
        int keep = tree.AddNode("keep.txt", root, false, 8, 8, 1);
        tree.AddNode("cloud.txt", root, false, 8, 0, 1, NodeFlags.NotDownloaded);
        tree.AddNode("empty.txt", root, false, 0, 0, 1);
        tree.AddNode("dir", root, true, 0, 0, 1);

        var found = DuplicateFinder.Candidates(tree, @"C:\tmp\diskmap-candidates");
        Assert.Equal([keep], found.Select(f => f.Id).ToList());
    }

    [Fact]
    public void SizeCollidingCandidatesKeepOnlySharedSizes()
    {
        var tree = new FileTree();
        int root = tree.AddNode("root", -1, true, 0, 0, 0);
        int a = tree.AddNode("a.bin", root, false, 8, 8, 1);
        int b = tree.AddNode("b.bin", root, false, 8, 8, 1);
        tree.AddNode("unique.bin", root, false, 5, 5, 1);

        var found = DuplicateFinder.SizeCollidingCandidates(tree, @"C:\tmp\diskmap-candidates");
        Assert.Equal([a, b], found.Select(f => f.Id).Order().ToList());
        Assert.Equal(3, DuplicateFinder.Candidates(tree, @"C:\tmp\diskmap-candidates").Count);
    }

    private sealed class DuplicateFixture : IDisposable
    {
        public readonly string Directory_;
        public readonly string Original;
        public readonly string HardLink;
        public readonly string IdenticalCopy;
        public readonly long ByteCount = 8_388_608;

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool CreateHardLinkW(string lpFileName, string lpExistingFileName, IntPtr lpSecurityAttributes);

        public DuplicateFixture()
        {
            Directory_ = Path.Combine(Path.GetTempPath(), $"DiskMap-dup-{Guid.NewGuid()}");
            Directory.CreateDirectory(Directory_);
            Original = Path.Combine(Directory_, "original.bin");
            HardLink = Path.Combine(Directory_, "hardlink.bin");
            IdenticalCopy = Path.Combine(Directory_, "copy.bin");
            var bytes = new byte[ByteCount];
            Array.Fill(bytes, (byte)0xAB);
            File.WriteAllBytes(Original, bytes);
            File.WriteAllBytes(IdenticalCopy, bytes);
            if (!CreateHardLinkW(HardLink, Original, IntPtr.Zero))
                throw new IOException($"CreateHardLinkW failed: {Marshal.GetLastWin32Error()}");
        }

        public void Dispose()
        {
            try { Directory.Delete(Directory_, recursive: true); } catch { }
        }
    }
}

public class CleanupQueueTests
{
    [Fact]
    public async Task OneCloneFreesNothingUntilTheLastCopyIsStaged()
    {
        var queue = new CleanupQueue();
        Assert.True(queue.Stage(@"C:\tmp\diskmap-clone-a", 800, "shared clone", "g", 2));
        Assert.True(queue.Stage(@"C:\tmp\diskmap-real-copy", 100, "duplicate"));
        Assert.True(queue.Stage(@"C:\tmp\diskmap-clone-b", 800, "shared clone", "g", 2));
        await queue.WaitForMeasurements();

        // Unmeasurable paths fall back to the shared-group hint: the group
        // counts once, and only once every copy is staged.
        var estimate = queue.Estimate();
        Assert.Equal(900, estimate.Bytes);          // 100 + one 800 for the pair
        Assert.True(estimate.IsLowerBound);          // never claimed exact
    }

    [Fact]
    public async Task HardLinkedNamesFreeOnceOnlyWhenAllStaged()
    {
        string dir = Path.Combine(Path.GetTempPath(), $"DiskMap-cq-{Guid.NewGuid()}");
        Directory.CreateDirectory(dir);
        try
        {
            string a = Path.Combine(dir, "a.bin"), b = Path.Combine(dir, "b.bin");
            File.WriteAllBytes(a, new byte[50_000]);
            Assert.True(CreateHardLinkW(b, a, IntPtr.Zero));
            var queue = new CleanupQueue();

            Assert.True(queue.Stage(a, 50_000, "dup"));
            await queue.WaitForMeasurements();
            // Link count is 2 but only one name is staged — the bytes stay.
            Assert.Equal(0, queue.Estimate().Bytes);
            Assert.True(queue.Estimate().HeldByUnqueuedCopies > 0);

            Assert.True(queue.Stage(b, 50_000, "dup"));
            await queue.WaitForMeasurements();
            var estimate = queue.Estimate();
            // Both names staged: the one shared allocation frees, once.
            long onDisk = StorageSharing.ProfileAt(a)!.AllocatedBytes;
            Assert.Equal(onDisk, estimate.Bytes);
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }

    [Fact]
    public async Task StagedFolderCoversStagedChildren()
    {
        string dir = Path.Combine(Path.GetTempPath(), $"DiskMap-cq-{Guid.NewGuid()}");
        try
        {
            string inner = Path.Combine(dir, "inner");
            Directory.CreateDirectory(inner);
            string inside = Path.Combine(inner, "child.txt");
            File.WriteAllText(inside, "x");
            var queue = new CleanupQueue();
            Assert.True(queue.Stage(inside, 1, "dup"));
            Assert.True(queue.Stage(inner, 4096, "folder"));
            await queue.WaitForMeasurements();
            // The child's own row contributes nothing — its folder carries it.
            var estimate = queue.Estimate();
            var childRow = queue.AllItems().Single(i => i.Path == inside);
            Assert.Equal(0, estimate.PerItem[childRow.Id]);
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }

    [Fact]
    public async Task CommitRecyclesFoldersBeforeTheirStagedChildren()
    {
        string dir = Path.Combine(Path.GetTempPath(), $"DiskMap-cq-{Guid.NewGuid()}");
        string folder = Path.Combine(dir, "doomed");
        Directory.CreateDirectory(folder);
        string child = Path.Combine(folder, "inside.txt");
        File.WriteAllText(child, "x");
        try
        {
            var queue = new CleanupQueue();
            // Stage the child BEFORE its folder — commit must still succeed.
            Assert.True(queue.Stage(child, 1, "dup"));
            Assert.True(queue.Stage(folder, 4096, "folder"));
            var report = queue.Commit();
            var childEntry = report.Entries.Single(e => e.Item.Path == child);
            var folderEntry = report.Entries.Single(e => e.Item.Path == folder);
            Assert.Null(childEntry.Error);
            Assert.True(childEntry.MovedWithFolder);
            Assert.Null(folderEntry.Error);
            Assert.Empty(queue.AllItems());
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }

    [Fact]
    public async Task CommitReceiptCountsOnlyWhatActuallyMoved()
    {
        string dir = Path.Combine(Path.GetTempPath(), $"DiskMap-cq-{Guid.NewGuid()}");
        Directory.CreateDirectory(dir);
        string gone = Path.Combine(dir, "gone.txt");
        File.WriteAllText(gone, "x");
        string kept = Path.Combine(dir, "kept.txt");
        File.WriteAllText(kept, "kept");
        try
        {
            var queue = new CleanupQueue();
            Assert.True(queue.Stage(gone, 1, "dup"));
            Assert.True(queue.Stage(kept, 4096, "dup"));
            File.Delete(gone);  // vanished before commit — must fail cleanly
            var report = queue.Commit();
            Assert.Single(report.Entries, e => e.Error is not null);
            var keptEntry = report.Entries.Single(e => e.Item.Path == kept);
            Assert.True(keptEntry.FreedBytes > 0);
            Assert.Equal(keptEntry.FreedBytes, report.FreedWhenEmptied);
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }

    [Fact]
    public void CommitBatchesManyItemsAndRecordsEachForPutBack()
    {
        string dir = Path.Combine(Path.GetTempPath(), $"DiskMap-cq-{Guid.NewGuid()}");
        Directory.CreateDirectory(dir);
        var files = Enumerable.Range(0, 200).Select(i => Path.Combine(dir, $"f{i}.txt")).ToList();
        foreach (var f in files) File.WriteAllText(f, "x");
        try
        {
            var queue = new CleanupQueue();
            foreach (var f in files) Assert.True(queue.Stage(f, 1, "dup"));
            var sw = System.Diagnostics.Stopwatch.StartNew();
            var report = queue.Commit();
            sw.Stop();
            Assert.All(report.Entries, e => Assert.Null(e.Error));
            Assert.All(files, f => Assert.False(File.Exists(f)));
            Assert.Equal(200, CleanupRecord.Load()!.Items.Count);
            // One shell call, not 200 — per-item calls took many seconds here.
            Assert.True(sw.Elapsed < TimeSpan.FromSeconds(10), $"commit took {sw.Elapsed}");
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }

    [Fact]
    public void ExcludedPrefixStillCannotBeStaged()
    {
        var queue = new CleanupQueue();
        string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        Assert.False(queue.Stage(Path.Combine(windows, "System32", "ntoskrnl.exe"), 1, "duplicate"));
        Assert.Empty(queue.AllItems());
    }

    [Fact]
    public void ExcludedListCoversAuditedPaths()
    {
        // WIN-069: WindowsApps aliases, memory files, WinSxS via C:\Windows.
        string system = Path.GetPathRoot(Environment.SystemDirectory)!;
        string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        Assert.True(CleanupQueue.IsExcludedPath(
            Path.Combine(local, "Microsoft", "WindowsApps", "wt.exe")));
        Assert.True(CleanupQueue.IsExcludedPath(system + @"pagefile.sys"));
        Assert.True(CleanupQueue.IsExcludedPath(system + @"hiberfil.sys"));
        Assert.True(CleanupQueue.IsExcludedPath(system + @"swapfile.sys"));
        Assert.True(CleanupQueue.IsExcludedPath(
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "WinSxS", "x")));
        Assert.False(CleanupQueue.IsExcludedPath(
            Path.Combine(local, "MyProject", "node_modules")));
    }

    [Fact]
    public async Task CommitMovesItemsToRecycleBin()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"DiskMap-cleanup-{Guid.NewGuid()}");
        Directory.CreateDirectory(dir);
        string file = Path.Combine(dir, "delete-me.txt");
        File.WriteAllText(file, "gone");

        var queue = new CleanupQueue();
        Assert.True(queue.Stage(file, 4, "test"));
        var report = queue.Commit();

        Assert.Single(report.Entries);
        Assert.Null(report.Entries[0].Error);
        Assert.False(File.Exists(file), "file should have been recycled");
        Assert.True(report.FreedWhenEmptied > 0);
        Assert.Empty(queue.AllItems());

        try { Directory.Delete(dir, recursive: true); } catch { }
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateHardLinkW(string lpFileName, string lpExistingFileName, IntPtr lpSecurityAttributes);
}

public class QuickWinsTests
{
    [Fact]
    public void BundledPatternsIncludeTheTicketList()
    {
        var patterns = QuickWins.BundledPatterns();
        Assert.Contains("node_modules", patterns.DirectoryNames);
        Assert.Contains(patterns.PathSuffixes, s => s.Contains("Temp"));
    }

    [Fact]
    public void MatchSwallowsDescendantsAndStillFindsASibling()
    {
        var tree = new FileTree();
        int root = tree.AddNode("proj", -1, true, 0, 0, 0);
        int modules = tree.AddNode("node_modules", root, true, 0, 0, 0);
        tree.AddNode("dist", modules, true, 0, 0, 0);
        int ownDist = tree.AddNode("dist", root, true, 0, 0, 0);
        tree.AddNode("src", root, true, 0, 0, 0);

        var hits = QuickWins.Find(tree, @"C:\tmp\proj",
            new QuickWins.Patterns(["node_modules", "dist"], []));
        Assert.Equal(new HashSet<int> { modules, ownDist }, hits.Select(h => h.Id).ToHashSet());
    }

    [Fact]
    public void CategoriesResolveFromTheMapAndDefault()
    {
        var tree = new FileTree();
        int root = tree.AddNode("proj", -1, true, 0, 0, 0);
        int modules = tree.AddNode("node_modules", root, true, 0, 0, 0);
        int dist = tree.AddNode("dist", root, true, 0, 0, 0);

        var patterns = new QuickWins.Patterns(
            ["node_modules", "dist"], [],
            new Dictionary<string, string> { ["node_modules"] = "Development dependencies" });
        var hits = QuickWins.Find(tree, @"C:\tmp\proj", patterns);
        Assert.Equal("Development dependencies", hits.First(h => h.Id == modules).Category);
        Assert.Equal(QuickWins.DefaultCategory, hits.First(h => h.Id == dist).Category);
    }

    [Fact]
    public void PathSuffixMatchesUnderAScanRoot()
    {
        var tree = new FileTree();
        int root = tree.AddNode("home", -1, true, 0, 0, 0);
        int appData = tree.AddNode("AppData", root, true, 0, 0, 0);
        int local = tree.AddNode("Local", appData, true, 0, 0, 0);
        int temp = tree.AddNode("Temp", local, true, 0, 0, 0);

        var hits = QuickWins.Find(tree, @"C:\Users\example",
            new QuickWins.Patterns([], [@"AppData\Local\Temp"]));
        Assert.Equal([temp], hits.Select(h => h.Id).ToList());
    }
}

public class SnapshotTests
{
    [Fact]
    public void RoundTripAndDiffReportsOneSidedFolders()
    {
        var beforeTree = new FileTree();
        int beforeRoot = beforeTree.AddNode("root", -1, true, 0, 0, 0);
        int keepBefore = beforeTree.AddNode("keep", beforeRoot, true, 0, 0, 1);
        beforeTree.AddNode("file", keepBefore, false, 100, 100, 1);
        int gone = beforeTree.AddNode("gone", beforeRoot, true, 0, 0, 1);
        beforeTree.AddNode("file", gone, false, 40, 40, 1);
        var before = new DiskSnapshot(@"C:\tmp\diskmap-snap",
            DateTimeOffset.FromUnixTimeSeconds(1_700_000_000), beforeTree);

        var afterTree = new FileTree();
        int afterRoot = afterTree.AddNode("root", -1, true, 0, 0, 0);
        int keepAfter = afterTree.AddNode("keep", afterRoot, true, 0, 0, 1);
        afterTree.AddNode("file", keepAfter, false, 250, 250, 1);
        int added = afterTree.AddNode("new", afterRoot, true, 0, 0, 1);
        afterTree.AddNode("file", added, false, 15, 15, 1);
        var after = new DiskSnapshot(@"C:\tmp\diskmap-snap",
            DateTimeOffset.FromUnixTimeSeconds(1_700_000_100), afterTree);

        string dir = Path.Combine(Path.GetTempPath(), $"DiskMap-snapshots-{Guid.NewGuid()}");
        try
        {
            string url = SnapshotStore.Save(before, dir);
            var header = SnapshotStore.ReadHeader(url);
            Assert.Equal(before.RootPath, header.RootPath);
            Assert.Equal(before.CapturedAt, header.CapturedAt);
            var loaded = SnapshotStore.Load(url);
            Assert.Equal(before.RootPath, loaded.RootPath);
            Assert.Equal(before.Tree.Count, loaded.Tree.Count);
            Assert.Equal("keep", loaded.Tree.NameOf(1));

            var changes = SnapshotDiff.Changes(before, after, SizeBasis.Allocated);
            var byName = changes.ToDictionary(c => Path.GetFileName(c.Path), c => c);
            Assert.Equal(150, byName["keep"].Delta);
            Assert.Equal(40, byName["gone"].Before);
            Assert.Equal(0, byName["gone"].After);
            Assert.Equal(0, byName["new"].Before);
            Assert.Equal(15, byName["new"].After);
        }
        finally
        {
            try { Directory.Delete(dir, recursive: true); } catch { }
        }
    }
}

public class AppLeftoverFinderTests
{
    [Fact]
    public void InstalledApplicationsReadsRegistryWithoutThrowing()
    {
        // Smoke test on a real machine — every Windows box has at least a
        // few Uninstall entries.
        var apps = AppLeftoverFinder.InstalledApplications();
        Assert.NotNull(apps);
    }
}
