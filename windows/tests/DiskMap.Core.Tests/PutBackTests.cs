using DiskMap.Core;
using DiskMap.Core.Native;

namespace DiskMap.Core.Tests;

/// <summary>
/// WIN-012: Put Back — exercises the real Recycle Bin on a temp file.
/// Skips cleanly on machines where the bin is disabled for the volume.
/// </summary>
public class PutBackTests
{
    [Fact]
    public void CommitThenPutBackRestoresAFile()
    {
        string dir = Path.Combine(Path.GetTempPath(), $"dm-putback-{Guid.NewGuid():N}");
        Directory.CreateDirectory(dir);
        string file = Path.Combine(dir, "keep-me.txt");
        File.WriteAllText(file, "restore me");
        try
        {
            var error = Shell32.RecycleItem(file);
            if (error is not null) return;   // bin disabled / unavailable on this volume — nothing to verify
            Assert.False(File.Exists(file));

            var entry = RecycleBinStore.Resolve(file);
            if (entry is null) return;       // e.g. redirected or network temp — nothing to verify
            Assert.True(File.Exists(entry.DataPath));
            Assert.Equal(file, entry.OriginalPath, StringComparer.OrdinalIgnoreCase);

            var record = new CleanupRecord(DateTimeOffset.Now,
                [new CleanupRecord.Item(file, entry.DataPath, 10)]);
            var report = DiskMap.Core.PutBack.Run(record);
            Assert.Single(report.Restored);
            Assert.Empty(report.Skipped);
            Assert.True(File.Exists(file));
            Assert.Equal("restore me", File.ReadAllText(file));

            // A second run reports the item gone rather than re-moving.
            var again = DiskMap.Core.PutBack.Run(record);
            Assert.Single(again.Skipped);
        }
        finally
        {
            if (File.Exists(file)) File.Delete(file);
            Directory.Delete(dir, true);
        }
    }

    [Fact]
    public void PutBackNeverReplacesAnOccupiedPath()
    {
        string dir = Path.Combine(Path.GetTempPath(), $"dm-putback-{Guid.NewGuid():N}");
        Directory.CreateDirectory(dir);
        string file = Path.Combine(dir, "occupied.txt");
        File.WriteAllText(file, "old");
        try
        {
            if (Shell32.RecycleItem(file) is not null) return;
            var entry = RecycleBinStore.Resolve(file);
            if (entry is null) return;
            File.WriteAllText(file, "new");
            var record = new CleanupRecord(DateTimeOffset.Now,
                [new CleanupRecord.Item(file, entry.DataPath, 3)]);
            var report = DiskMap.Core.PutBack.Run(record);
            Assert.Empty(report.Restored);
            Assert.Single(report.Skipped);
            Assert.Equal("new", File.ReadAllText(file));   // untouched
        }
        finally
        {
            // If the file is still sitting at `file` the Delete removes the
            // stand-in; the binned copy stays in the bin (tests can't empty it).
            if (File.Exists(file)) File.Delete(file);
            Directory.Delete(dir, true);
        }
    }
}
