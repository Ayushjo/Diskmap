namespace DiskMap.Core;

public enum StoryKind { Capacity, QuickWin, Forgotten, Category, Developer, Biggest }

public sealed record StorageStory(
    string Id, string Title, string Detail, long Bytes, StoryKind Kind);

public enum StoryConfidence { High, Medium, Low }
public enum StorySafety { Safe, Review, Protected }

public sealed record StorageRecommendation(
    string Id, string Title, string Detail, long Bytes,
    StoryConfidence Confidence, StorySafety Safety)
{
    /// <summary>Higher is better. Deterministic ranking helper.</summary>
    public double Score =>
        Math.Log(1.0 + Math.Max(0, Bytes))
        * (Confidence switch { StoryConfidence.High => 1.0, StoryConfidence.Medium => 0.55, _ => 0.25 })
        * (Safety switch { StorySafety.Safe => 1.0, StorySafety.Review => 0.45, _ => 0.0 });
}

/// <summary>
/// Rules layer: turns AnalysisSnapshot facts into a few high-value
/// stories + recommendations (WIN-027). Deterministic — same snapshot,
/// same sentences.
/// </summary>
public static class StorageNarrator
{
    public static List<StorageStory> Stories(AnalysisSnapshot snap, int limit = 5)
    {
        var stories = new List<StorageStory>();
        if (snap.Volume is { } vol && snap.Health is StorageHealth.Low
            or StorageHealth.Critical or StorageHealth.Tight)
        {
            stories.Add(new StorageStory("capacity",
                $"Disk is {snap.Health.ToString().ToLowerInvariant()}",
                $"{HumanUnits.Format(vol.FreeBytes)} free of {HumanUnits.Format(vol.TotalBytes)}. " +
                "Focus on high-confidence cleanup first.",
                vol.UsedBytes, StoryKind.Capacity));
        }
        if (snap.QuickWinBytes > 0)
        {
            stories.Add(new StorageStory("quickwins", "Known regenerable data",
                $"About {HumanUnits.Format(snap.QuickWinBytes)} sits in caches and build artifacts DiskMap recognizes.",
                snap.QuickWinBytes, StoryKind.QuickWin));
        }
        if (snap.ForgottenBytes > 0)
        {
            stories.Add(new StorageStory("forgotten", "Forgotten files",
                $"{HumanUnits.Format(snap.ForgottenBytes)} in files not modified in over a year.",
                snap.ForgottenBytes, StoryKind.Forgotten));
        }
        // The biggest named category — "Other" leading says nothing useful.
        var top = snap.Categories.Where(c => c.Key != "other")
            .OrderByDescending(c => c.Bytes).FirstOrDefault();
        if (top is { Bytes: > 0 })
        {
            if (snap.Mode is CategoryMode.Folder)
            {
                long total = Math.Max(1, snap.Categories.Sum(c => c.Bytes));
                int share = (int)Math.Round((double)top.Bytes / total * 100);
                stories.Add(new StorageStory($"cat-{top.Key}",
                    $"{top.Title} is {share}% of this folder",
                    $"{HumanUnits.Format(top.Bytes)} — open Find to list every {top.Title.ToLowerInvariant()} file here.",
                    top.Bytes, StoryKind.Category));
            }
            else
            {
                stories.Add(new StorageStory($"cat-{top.Key}", $"{top.Title} leads this scan",
                    $"{HumanUnits.Format(top.Bytes)} — open Find or Visualize to investigate the largest items.",
                    top.Bytes, StoryKind.Category));
            }
        }
        if (snap.Mode is not CategoryMode.Folder
            && snap.Categories.FirstOrDefault(c => c.Key == "developer") is { } dev
            && dev.Bytes > 8_000_000)
        {
            stories.Add(new StorageStory("developer", "Developer tool data is large",
                $"{HumanUnits.Format(dev.Bytes)} in known developer locations (NuGet, npm, caches, and similar).",
                dev.Bytes, StoryKind.Developer));
        }
        if (snap.TopFiles.FirstOrDefault() is { } big)
        {
            stories.Add(new StorageStory($"biggest-{big.NodeId}", $"Largest file: {big.Name}",
                $"{HumanUnits.Format(big.Bytes)} at {big.RelativePath}.",
                big.Bytes, StoryKind.Biggest));
        }
        return stories.Take(limit).ToList();
    }

    public static List<StorageRecommendation> Recommendations(AnalysisSnapshot snap, int limit = 5)
    {
        var list = new List<StorageRecommendation>();
        if (snap.QuickWinBytes > 0)
        {
            list.Add(new StorageRecommendation("rec-quickwins", "Review regenerable caches",
                "High confidence — known package/build caches DiskMap can explain.",
                snap.QuickWinBytes, StoryConfidence.High, StorySafety.Safe));
        }
        if (snap.Categories.FirstOrDefault(c => c.Key == "downloads") is { Bytes: > 0 } downloads)
        {
            list.Add(new StorageRecommendation("rec-downloads", "Review Downloads",
                "Mixed personal files and installers — inspect before staging.",
                downloads.Bytes, StoryConfidence.Medium, StorySafety.Review));
        }
        if (snap.ForgottenBytes > 0)
        {
            list.Add(new StorageRecommendation("rec-forgotten", "Review forgotten files",
                "Old by last-modified date only — confirm you still need them.",
                snap.ForgottenBytes, StoryConfidence.Medium, StorySafety.Review));
        }
        if (snap.Categories.FirstOrDefault(c => c.Key == "caches") is { Bytes: > 0 } caches)
        {
            list.Add(new StorageRecommendation("rec-caches", "Clear application caches",
                "Usually regenerable; apps may re-download assets.",
                caches.Bytes, StoryConfidence.High, StorySafety.Safe));
        }
        if (snap.TopFiles.FirstOrDefault(f =>
            f.Name.EndsWith(".mkv", StringComparison.OrdinalIgnoreCase)
            || f.Name.EndsWith(".mp4", StringComparison.OrdinalIgnoreCase)
            || f.Name.EndsWith(".mov", StringComparison.OrdinalIgnoreCase)
            || f.Name.EndsWith(".iso", StringComparison.OrdinalIgnoreCase)
            || f.Name.EndsWith(".vhdx", StringComparison.OrdinalIgnoreCase)) is { } media)
        {
            list.Add(new StorageRecommendation($"rec-media-{media.NodeId}", $"Large media: {media.Name}",
                "Confirm you have another copy before removing.",
                media.Bytes, StoryConfidence.Low, StorySafety.Review));
        }
        return list.OrderByDescending(r => r.Score).Take(limit).ToList();
    }
}
