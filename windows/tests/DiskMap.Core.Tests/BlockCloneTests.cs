using DiskMap.Core;

namespace DiskMap.Core.Tests;

/// <summary>
/// WIN-066: block-clone (shared-extent) accounting — the ReFS counterpart
/// of the macOS APFS tests. The sweep/family math runs on synthetic
/// extent maps; the FSCTL path needs a real ReFS volume and is covered
/// by the same "verified on a real fixture" rule as the MFT tests (none
/// of the CI machines have one, so it is not exercised here).
/// </summary>
public class BlockCloneTests
{
    private static FileTree.SharingTable Table(
        int[] nodes, long[] clones, long[] privates, int[] refcounts) =>
        new() { Node = nodes, CloneId = clones, PrivateBytes = privates, RefCount = refcounts };

    private static FileTree TwoFileTree(
        out int fileA, out int fileB,
        long fileIdA = 100, long fileIdB = 200,
        long allocA = 8192, long allocB = 8192)
    {
        var tree = new FileTree();
        int root = tree.AddNode("root", -1, true, 0, 0, 0);
        int folderA = tree.AddNode("folderA", root, true, 0, 0, 0);
        int folderB = tree.AddNode("folderB", root, true, 0, 0, 0);
        fileA = tree.AddNode("a.bin", folderA, false, allocA, allocA, 0, 0, 0, fileIdA);
        fileB = tree.AddNode("b.bin", folderB, false, allocB, allocB, 0, 0, 0, fileIdB);
        tree.AddFlags(fileA, NodeFlags.FileClone);
        tree.AddFlags(fileB, NodeFlags.FileClone);
        return tree;
    }

    [Fact]
    public void CloneFamilyChargedOnceAcrossFolders()
    {
        var tree = TwoFileTree(out int a, out int b);
        // Pure clones: no private bytes anywhere. Lowest inode (a) elected.
        Assert.True(tree.ReplaceSharing(
            Table([a, b], [7, 7], [0, 0], [2, 2]), FileTree.CloneSharingMode.Full));

        var totals = tree.RollUpSizes(SizeBasis.Allocated);

        Assert.Equal(8192, totals[a]);   // elected: carries the shared blocks
        Assert.Equal(0, totals[b]);      // non-elected: private bytes only
        Assert.Equal(8192, totals[0]);   // counted once at the root

        var correction = tree.GetSharingCorrection();
        Assert.Equal(1, correction.FamilyCount);
        Assert.Equal(1, correction.CloneCount);
        Assert.Equal(8192, correction.Bytes);
        Assert.False(correction.IsEmpty);
    }

    [Fact]
    public void EditedCloneKeepsItsPrivateBytes()
    {
        // A edited 4 KB of a 12 KB clone: 8 KB shared, 4 KB private.
        // B is the untouched clone and wins the election (lower file id).
        var tree = TwoFileTree(out int a, out int b,
            fileIdA: 200, fileIdB: 100, allocA: 12_288, allocB: 8192);
        Assert.True(tree.ReplaceSharing(
            Table([a, b], [9, 9], [4096, 0], [2, 2]), FileTree.CloneSharingMode.Full));

        var totals = tree.RollUpSizes(SizeBasis.Allocated);

        Assert.Equal(8192, totals[b]);   // elected: whole clone
        Assert.Equal(4096, totals[a]);   // private extents only
        Assert.Equal(12_288, totals[0]); // true physical footprint

        var correction = tree.GetSharingCorrection();
        Assert.Equal(8192, correction.Bytes);
    }

    [Fact]
    public void HardLinkedNameOfACloneMemberCountsOnce()
    {
        // Inode 100 has two names; inode 200 is its clone. refcounts count
        // inodes (2), not names (3).
        var tree = new FileTree();
        int root = tree.AddNode("root", -1, true, 0, 0, 0);
        int folderA = tree.AddNode("folderA", root, true, 0, 0, 0);
        int folderB = tree.AddNode("folderB", root, true, 0, 0, 0);
        int n1 = tree.AddNode("n1.bin", folderA, false, 8192, 8192, 0, NodeFlags.HardLink, 0, 100);
        int n2 = tree.AddNode("n2.bin", folderB, false, 8192, 8192, 0, NodeFlags.HardLink, 0, 100);
        int clone = tree.AddNode("c.bin", folderB, false, 8192, 8192, 0, 0, 0, 200);
        Assert.True(tree.ReplaceSharing(
            Table([n1, n2, clone], [5, 5, 5], [0, 0, 0], [2, 2, 2]),
            FileTree.CloneSharingMode.Full));

        var totals = tree.RollUpSizes(SizeBasis.Allocated);

        // Inode 100 is elected (lowest). Its surviving name — the lowest
        // path — carries the 8 KB; the other name and the clone carry 0.
        Assert.Equal(8192, totals[n1]);
        Assert.Equal(0, totals[n2]);
        Assert.Equal(0, totals[clone]);
        Assert.Equal(8192, totals[0]);
    }

    [Fact]
    public void LogicalBasisIgnoresSharing()
    {
        var tree = TwoFileTree(out int a, out int b);
        Assert.True(tree.ReplaceSharing(
            Table([a, b], [7, 7], [0, 0], [2, 2]), FileTree.CloneSharingMode.Full));

        var logical = tree.RollUpSizes(SizeBasis.Logical);

        Assert.Equal(16_384, logical[0]); // per copy — the accounting is on-disk only
    }

    [Fact]
    public void SharingInfoOfReportsSharedBytesAndCopies()
    {
        var tree = TwoFileTree(out int a, out int b, allocA: 12_288, allocB: 8192);
        Assert.True(tree.ReplaceSharing(
            Table([a, b], [7, 7], [4096, 0], [2, 2]), FileTree.CloneSharingMode.Full));

        var info = tree.SharingInfoOf(a);
        Assert.NotNull(info);
        Assert.Equal(8192, info.Value.SharedBytes);
        Assert.Equal(1, info.Value.OtherCopies);
    }

    [Fact]
    public void PartialRowIsReportedNotChargedDown()
    {
        // A file sharing blocks with a copy outside the scan (refcount 1 —
        // the macOS codec can write these): kept at full size, surfaced as
        // partial so the UI can say "shares with copies we can't name".
        var tree = TwoFileTree(out int a, out int _);
        Assert.True(tree.ReplaceSharing(
            Table([a], [3], [2048], [1]), FileTree.CloneSharingMode.Full));

        var totals = tree.RollUpSizes(SizeBasis.Allocated);
        Assert.Equal(8192, totals[a]);

        var correction = tree.GetSharingCorrection();
        Assert.Equal(0, correction.CloneCount);
        Assert.Equal(1, correction.PartialCount);
        Assert.Equal(6144, correction.PartialSharedBytes);
    }

    [Fact]
    public void ReplaceSharingRejectsUnsortedOrOutOfRangeRows()
    {
        var tree = TwoFileTree(out int a, out int b);
        Assert.False(tree.ReplaceSharing(
            Table([b, a], [1, 1], [0, 0], [2, 2]), FileTree.CloneSharingMode.Full));
        Assert.False(tree.ReplaceSharing(
            Table([a, 99], [1, 1], [0, 0], [2, 2]), FileTree.CloneSharingMode.Full));
        Assert.False(tree.HasSharingInfo);
    }

    [Fact]
    public void CodecRoundTripsSharingRows()
    {
        var tree = TwoFileTree(out int a, out int b);
        Assert.True(tree.ReplaceSharing(
            Table([a, b], [7, 7], [0, 0], [2, 2]), FileTree.CloneSharingMode.Full));
        var before = tree.RollUpSizes(SizeBasis.Allocated);

        var snapshot = new DiskSnapshot("C:\\root", DateTimeOffset.Now, tree);
        var decoded = SnapshotCodec.Decode(SnapshotCodec.Encode(snapshot));

        Assert.Equal(FileTree.CloneSharingMode.Full, decoded.Tree.SharingMode);
        Assert.Equal(2, decoded.Tree.Sharing.Count);
        var after = decoded.Tree.RollUpSizes(SizeBasis.Allocated);
        Assert.Equal(before[0], after[0]);
        Assert.Equal(before[a], after[a]);
        Assert.Equal(before[b], after[b]);
    }

    // ---- BuildTable: the sweep math on synthetic extent maps ----

    private static BlockClones.InodeEntry Entry(
        ulong inode, int node, long allocated, params (long Off, long Len)[] extents) =>
        new(inode, [node], allocated,
            [.. extents.Select(e => new CloneDetector.Extent(0, e.Off, e.Len))]);

    [Fact]
    public void BuildTableGroupsFilesSharingAnyRange()
    {
        // A=[0,300) and B=[100,400) share the middle 200 bytes; C is independent.
        var entries = new[]
        {
            Entry(100, 1, 300, (0, 300)),
            Entry(200, 2, 300, (100, 300)),
            Entry(300, 3, 100, (500, 100)),
        };
        var table = BlockClones.BuildTable(entries, out int families, out int copies, out long bytes);

        Assert.Equal(1, families);
        Assert.Equal(1, copies);
        // The non-elected member keeps 100 private bytes; its remaining
        // 200 of allocated is the deduplicated shared storage.
        Assert.Equal(200, bytes);
        Assert.Equal(2, table.Count);     // rows only for the two members
        Assert.All(table.RefCount, r => Assert.Equal(2, r));
    }

    [Fact]
    public void BuildTableChainsThroughSharedRanges()
    {
        // A↔B share [0,100), B↔C share [200,300) — one family of three
        // via union-find, even though A and C share nothing.
        var entries = new[]
        {
            Entry(100, 1, 300, (0, 100), (200, 100)),   // A shares both ranges
            Entry(200, 2, 300, (0, 100), (200, 100)),
            Entry(300, 3, 100, (200, 100)),
        };
        var table = BlockClones.BuildTable(entries, out int families, out int copies, out _);

        Assert.Equal(1, families);
        Assert.Equal(2, copies);
        Assert.Equal(3, table.Count);
        Assert.All(table.RefCount, r => Assert.Equal(3, r));
        // Lowest inode (100) elected → its row's clone id is 100.
        Assert.All(table.CloneId, c => Assert.Equal(100, c));
    }

    [Fact]
    public void BuildTableComputesPrivateBytesPerMember()
    {
        // B shares [0,100) with A but owns [300,350) alone.
        var entries = new[]
        {
            Entry(100, 1, 100, (0, 100)),
            Entry(200, 2, 150, (0, 100), (300, 50)),
        };
        var table = BlockClones.BuildTable(entries, out _, out _, out _);

        int rowB = table.RowOf(2);
        Assert.True(rowB >= 0);
        Assert.Equal(50, table.PrivateBytes[rowB]);
        // Elected (inode 100) has the family's shared bytes as "shared":
        // private 0 → it carries its full allocation in the rollup.
        Assert.Equal(0, table.PrivateBytes[table.RowOf(1)]);
    }

    [Fact]
    public void SparseRunsNeverFormFamilies()
    {
        // DeviceOffset -1 = unallocated hole — two files' holes are not
        // shared storage (their real extents stay disjoint here).
        var entries = new[]
        {
            new BlockClones.InodeEntry(100, [1], 4096,
                [new CloneDetector.Extent(0, -1, 8192), new CloneDetector.Extent(8192, 1000, 4096)]),
            new BlockClones.InodeEntry(200, [2], 4096,
                [new CloneDetector.Extent(0, -1, 8192), new CloneDetector.Extent(8192, 9000, 4096)]),
        };
        var table = BlockClones.BuildTable(entries, out int families, out int copies, out _);

        Assert.Equal(0, families);
        Assert.Equal(0, copies);
        Assert.True(table.IsEmpty);
    }

    [Fact]
    public void SharingSurvivesSnapshotLoadForUiBadges()
    {
        // The flag lets the inspector say "shares X with N other copies"
        // after a codec round-trip — flags ride the v3+ arrays.
        var tree = TwoFileTree(out int a, out _);
        Assert.True(tree.ReplaceSharing(
            Table([a], [7], [0], [1]), FileTree.CloneSharingMode.Full));
        var decoded = SnapshotCodec.Decode(SnapshotCodec.Encode(
            new DiskSnapshot("C:\\root", DateTimeOffset.Now, tree)));

        Assert.True((decoded.Tree.Flags[a] & NodeFlags.FileClone) != 0);
        Assert.NotNull(decoded.Tree.SharingInfoOf(a));
    }
}
