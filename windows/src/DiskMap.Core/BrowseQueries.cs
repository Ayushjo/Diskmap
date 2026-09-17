namespace DiskMap.Core;

/// <summary>
/// Ranked node ids for the Top Sizes list. Index 0 (the scan root) is
/// omitted. Directories already carry subtree totals; files carry their
/// own size.
/// </summary>
public static class TopSizes
{
    public static List<int> Ranked(long[] totals, int limit = 500)
    {
        var result = new List<int>();
        if (totals.Length <= 1 || limit <= 0) return result;
        var ids = Enumerable.Range(1, totals.Length - 1).ToList();
        ids.Sort((a, b) => totals[b].CompareTo(totals[a]));
        foreach (int id in ids)
        {
            if (totals[id] <= 0) break;
            result.Add(id);
            if (result.Count == limit) break;
        }
        return result;
    }
}

public enum AgeBucket
{
    Under30,
    Days30To90,
    Days90To365,
    OneToTwoYears,
    OverTwoYears,
    Unknown,
}

public static class AgeMap
{
    public static string Title(AgeBucket bucket) => bucket switch
    {
        AgeBucket.Under30 => "Under 30 days",
        AgeBucket.Days30To90 => "30–90 days",
        AgeBucket.Days90To365 => "90 days–1 year",
        AgeBucket.OneToTwoYears => "1–2 years",
        AgeBucket.OverTwoYears => "Over 2 years",
        _ => "Unknown",
    };

    public static int Today(DateTimeOffset? date = null) =>
        (int)((date ?? DateTimeOffset.UtcNow).ToUnixTimeSeconds() / 86400);

    /// <summary>modifiedDay is days since epoch. 0 means the scan had no date.</summary>
    public static AgeBucket Bucket(int modifiedDay, int today)
    {
        if (modifiedDay <= 0) return AgeBucket.Unknown;
        int age = today - modifiedDay;
        if (age < 30) return AgeBucket.Under30;
        if (age < 90) return AgeBucket.Days30To90;
        if (age < 365) return AgeBucket.Days90To365;
        if (age < 730) return AgeBucket.OneToTwoYears;
        return AgeBucket.OverTwoYears;
    }

    /// <summary>
    /// File ids older than a year, largest first, capped. Directories
    /// and unknown dates are excluded.
    /// </summary>
    public static List<int> Untouched(FileTree tree, long[] totals, int today, int limit = 100)
    {
        var result = new List<int>();
        if (tree.Count != totals.Length || limit <= 0) return result;
        for (int id = 1; id < tree.Count; id++)
        {
            if (tree.IsDirectory[id]) continue;
            int day = tree.ModifiedDay[id];
            if (day <= 0 || today - day <= 365 || totals[id] <= 0) continue;
            result.Add(id);
        }
        result.Sort((a, b) => totals[b].CompareTo(totals[a]));
        if (result.Count > limit) result.RemoveRange(limit, result.Count - limit);
        return result;
    }

    public static Dictionary<AgeBucket, long> BucketSizes(FileTree tree, long[] totals, int today)
    {
        var sizes = new Dictionary<AgeBucket, long>();
        if (tree.Count != totals.Length) return sizes;
        for (int id = 1; id < tree.Count; id++)
        {
            if (tree.IsDirectory[id]) continue;
            var bucket = Bucket(tree.ModifiedDay[id], today);
            sizes[bucket] = sizes.GetValueOrDefault(bucket) + totals[id];
        }
        return sizes;
    }
}
