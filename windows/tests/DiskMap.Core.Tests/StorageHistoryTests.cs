using DiskMap.Core;

namespace DiskMap.Core.Tests;

/// <summary>
/// WIN-028: per-root scan history — retention policy and the "what grew
/// this week" comparison semantics, on a temp-directory store.
/// </summary>
public class StorageHistoryTests
{
    private static StorageHistory.Entry E(int daysAgo, long scanned,
        Dictionary<string, long>? folders = null, int denied = 0) =>
        new(DateTimeOffset.Now.AddDays(-daysAgo), 100_000_000, 500_000_000_000,
            scanned, denied, StorageHistory.Entry.SharingModeHardLinkDedup,
            folders ?? new Dictionary<string, long>());

    [Fact]
    public void RecordPersistsOneFilePerRoot()
    {
        string dir = Path.Combine(Path.GetTempPath(), $"dm-history-{Guid.NewGuid():N}");
        try
        {
            var history = new StorageHistory(dir);
            history.Record(E(0, 1_000), @"C:\scan");
            history.Record(E(0, 2_000), @"C:\other");
            Assert.Single(history.Entries(@"C:\scan"));
            Assert.Single(history.Entries(@"C:\other"));
            Assert.Equal(2, Directory.EnumerateFiles(dir).Count());
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public void RetentionKeepsLastPerDayThenPerWeek()
    {
        var now = new DateTimeOffset(new DateTime(2026, 6, 15, 12, 0, 0, DateTimeKind.Local));
        var entries = new List<StorageHistory.Entry>();
        // Three scans today + three yesterday → one kept each, and the
        // LAST one of the day wins.
        for (int i = 0; i < 3; i++)
            entries.Add(new StorageHistory.Entry(now.AddHours(-3 - i), 0, 0, 100 + i, 0,
                StorageHistory.Entry.SharingModeHardLinkDedup, []));
        for (int i = 0; i < 3; i++)
            entries.Add(new StorageHistory.Entry(now.AddDays(-1).AddHours(-3 - i), 0, 0, 200 + i, 0,
                StorageHistory.Entry.SharingModeHardLinkDedup, []));
        // Forty days old → weekly bucket; past a year → dropped.
        entries.Add(new StorageHistory.Entry(now.AddDays(-40), 0, 0, 40, 0,
            StorageHistory.Entry.SharingModeHardLinkDedup, []));
        entries.Add(new StorageHistory.Entry(now.AddDays(-41), 0, 0, 41, 0,
            StorageHistory.Entry.SharingModeHardLinkDedup, []));
        entries.Add(new StorageHistory.Entry(now.AddDays(-400), 0, 0, 400, 0,
            StorageHistory.Entry.SharingModeHardLinkDedup, []));

        var kept = StorageHistory.Retained(entries, now);
        Assert.Equal(kept.Count, kept.Distinct().Count());
        Assert.DoesNotContain(kept, e => e.ScannedBytes == 400);
        Assert.True(kept.Count <= 5);
        // The day's LAST scan wins: the most recent of each pair.
        Assert.Contains(kept, e => e.ScannedBytes == 100);  // now-3h
        Assert.Contains(kept, e => e.ScannedBytes == 200);  // yesterday-3h
        Assert.DoesNotContain(kept, e => e.ScannedBytes is 101 or 102 or 201 or 202);
    }

    [Fact]
    public void CompareFindsGrowersAndDeduplicatesParents()
    {
        var week = new Dictionary<string, long> { ["Users"] = 10_000_000_000 };
        var now = new Dictionary<string, long>
        {
            ["Users"] = 10_500_000_000,
            ["Users/name"] = 400_000_000,   // deep: only counts when both went deep
        };
        var old = E(7, 10_000_000_000, week);
        var latest = E(0, 10_500_000_000, now);
        var comparison = StorageHistory.Compare([old], latest);
        Assert.NotNull(comparison);
        Assert.True(comparison!.IsWeek);
        Assert.Single(comparison.Growers);
        Assert.Equal("Users", comparison.Growers[0].Path);   // deep key needs matching depth in BOTH
        Assert.Equal(500_000_000, comparison.Growers[0].Delta);

        // Once BOTH scans report a child, the child wins over its parent
        // when it explains ≥80% of the growth.
        var weekDeep = new Dictionary<string, long>
        {
            ["Users"] = 10_000_000_000, ["Users/name"] = 1_000_000_000,
        };
        var nowDeep = new Dictionary<string, long>
        {
            ["Users"] = 10_600_000_000, ["Users/name"] = 1_600_000_000,
        };
        var deep = StorageHistory.Compare(
            [E(7, 10_000_000_000, weekDeep)], E(0, 10_600_000_000, nowDeep));
        Assert.NotNull(deep);
        Assert.Equal("Users/name", deep!.Growers[0].Path);
        Assert.DoesNotContain(deep.Growers, g => g.Path == "Users");
    }

    [Fact]
    public void CompareRefusesMismatchedCountingAndTooRecentBases()
    {
        var entries = new List<StorageHistory.Entry>
        {
            E(1, 1_000),                       // only 1 day old — too recent
            new StorageHistory.Entry(DateTimeOffset.Now.AddDays(-7), 0, 0, 0, 0,
                "different-mode", []),         // counted differently — never compared
        };
        Assert.Null(StorageHistory.Compare(entries, E(0, 2_000)));
    }
}
