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
        var result = MftScanner.Walk(systemDrive, null);

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

    private static bool IsNtfs(string root)
    {
        // Cheap check: GetVolumeInformation would say NTFS; approximate via
        // the drive being local and the FS name. Keep it simple — if this
        // ever runs on exFAT elevated the assert is informational only.
        return new DriveInfo(root.TrimEnd('\\')).DriveFormat
            .Equals("NTFS", StringComparison.OrdinalIgnoreCase);
    }
}
