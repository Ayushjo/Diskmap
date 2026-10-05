using System.Security.Principal;
using DiskMap.Core;

namespace DiskMap.Core.Tests;

public class MftScannerTests
{
    /// <summary>
    /// The MFT path needs a volume handle (admin). Non-elevated it must
    /// return null so ScanEngine falls back — this test passes either way:
    /// it asserts graceful null when unelevated, and a sane tree when the
    /// suite happens to run elevated.
    /// </summary>
    [Fact]
    public void WalkReturnsNullWithoutElevationOrSaneTreeWithIt()
    {
        string systemDrive = Path.GetPathRoot(Environment.GetFolderPath(Environment.SpecialFolder.System))!;
        var result = MftScanner.Walk(systemDrive, null, CancellationToken.None, out _);

        bool elevated = new WindowsPrincipal(WindowsIdentity.GetCurrent())
            .IsInRole(WindowsBuiltInRole.Administrator);

        if (result is null)
        {
            // Expected when not elevated (or non-NTFS boot volume).
            Assert.False(elevated && IsNtfs(systemDrive),
                "elevated + NTFS should have produced a tree");
            return;
        }

        // Elevated + NTFS: the tree should contain real Windows dirs.
        var tree = result.Tree;
        Assert.True(tree.Count > 100, "a drive-root MFT scan should find many nodes");
        Assert.Equal("mft", result.Backend);
        var names = Enumerable.Range(0, Math.Min(tree.Count, 5000))
            .Select(tree.NameOf).ToHashSet();
        Assert.Contains(names, n => n.Equals("Windows", StringComparison.OrdinalIgnoreCase)
            || n.Equals("Users", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void DecodeRunsFollowsSignedDeltasAndSkipsSparseRuns()
    {
        var attr = new byte[96];
        attr[8] = 1;                                   // non-resident
        BitConverter.GetBytes((ushort)64).CopyTo(attr, 32); // run list offset
        byte[] runs =
        [
            0x31, 0x10, 0x00, 0x00, 0x0C,              // 16 clusters at LCN 0x0C0000
            0x21, 0x08, 0x00, 0xFF,                    // 8 clusters, delta -256
            0x01, 0x04,                                // 4 sparse clusters: no extent
            0x81, 0x02, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // 2 clusters, 8-byte delta -1
            0x00,
        ];
        runs.CopyTo(attr, 64);

        var extents = new List<MftScanner.Extent>();
        Assert.True(MftScanner.DecodeRuns(attr, extents));
        Assert.Equal(
            [new(0, 0x0C0000, 16), new(16, 0x0C0000 - 256, 8), new(28, 0x0C0000 - 257, 2)],
            extents);
    }

    [Fact]
    public void PrepareRecordRestoresStrideEndsAndRejectsTornRecords()
    {
        var rec = new byte[1024];
        "FILE"u8.CopyTo(rec);
        BitConverter.GetBytes((ushort)48).CopyTo(rec, 4); // update sequence offset
        BitConverter.GetBytes((ushort)3).CopyTo(rec, 6);  // sequence + one entry per 512-byte stride
        byte[] usa = [0x34, 0x12, 0xAA, 0xBB, 0xCC, 0xDD];
        usa.CopyTo(rec, 48);
        rec[510] = 0x34; rec[511] = 0x12;
        rec[1022] = 0x34; rec[1023] = 0x12;

        var torn = (byte[])rec.Clone();
        torn[1022] = 0x99;

        Assert.True(MftScanner.PrepareRecord(rec));
        Assert.Equal([0xAA, 0xBB, 0xCC, 0xDD], new[] { rec[510], rec[511], rec[1022], rec[1023] });
        Assert.False(MftScanner.PrepareRecord(torn));
    }

    private static bool IsNtfs(string root)
    {
        // Cheap check: GetVolumeInformation would say NTFS; approximate via
        // the drive being local and the FS name. Keep it simple — if this
        // ever runs on exFAT elevated the assert is informational only.
        return new DriveInfo(root.TrimEnd('\\')).DriveFormat
            .Equals("NTFS", StringComparison.OrdinalIgnoreCase);
    }
}
