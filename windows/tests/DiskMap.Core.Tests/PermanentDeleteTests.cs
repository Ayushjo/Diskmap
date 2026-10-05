using DiskMap.Core;

namespace DiskMap.Core.Tests;

/// <summary>
/// The one permanent-delete path (bin refusals, regenerable only) and the
/// policy that keeps it the only one.
/// </summary>
public class PermanentDeleteTests
{
    /// <summary>A fixture outside %TEMP% — under Temp everything classifies as a cache.</summary>
    private static string FixtureRoot()
    {
        string dir = Path.Combine(AppContext.BaseDirectory, "perm-fixture", Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(dir);
        return dir;
    }

    [Fact]
    public async Task DeletesRegenerableFolderButNeverFollowsAJunctionOut()
    {
        string root = FixtureRoot();
        string outside = Path.Combine(root, "outside");
        Directory.CreateDirectory(outside);
        string precious = Path.Combine(outside, "precious.txt");
        File.WriteAllText(precious, "keep me");

        string nm = Path.Combine(root, "proj", "node_modules");
        Directory.CreateDirectory(Path.Combine(nm, "dep"));
        string ro = Path.Combine(nm, "dep", "index.js");
        File.WriteAllText(ro, "x");
        File.SetAttributes(ro, FileAttributes.ReadOnly);
        // pnpm-style link inside node_modules pointing outside it.
        var mklink = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(
            "cmd", $"/c mklink /J \"{Path.Combine(nm, "linked")}\" \"{outside}\"")
            { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true })!;
        mklink.WaitForExit();
        try
        {
            Assert.True(Directory.Exists(Path.Combine(nm, "linked")), "fixture junction");
            Assert.True(CleanupQueue.IsRegenerable(nm));
            var queue = new CleanupQueue();
            Assert.True(queue.Stage(nm, 1, "developer storage"));
            await queue.WaitForMeasurements();
            var item = queue.AllItems().Single();

            var report = queue.DeletePermanently([item.Id]);

            Assert.Null(report.Entries.Single().Error);
            Assert.False(Directory.Exists(nm));
            Assert.True(File.Exists(precious), "a junction's target must never be deleted");
            Assert.Empty(queue.AllItems());
        }
        finally { try { Directory.Delete(root, true); } catch { } }
    }

    [Fact]
    public async Task RefusesAnythingThatIsNotRegenerable()
    {
        string root = FixtureRoot();
        string docs = Path.Combine(root, "my-notes");
        Directory.CreateDirectory(docs);
        File.WriteAllText(Path.Combine(docs, "a.txt"), "x");
        try
        {
            Assert.False(CleanupQueue.IsRegenerable(docs));
            var queue = new CleanupQueue();
            Assert.True(queue.Stage(docs, 1, "test"));
            await queue.WaitForMeasurements();

            var report = queue.DeletePermanently([queue.AllItems().Single().Id]);

            Assert.NotNull(report.Entries.Single().Error);
            Assert.True(File.Exists(Path.Combine(docs, "a.txt")));
            Assert.Single(queue.AllItems());   // stays staged
        }
        finally { try { Directory.Delete(root, true); } catch { } }
    }

    [Fact]
    public void PermanentDeletionLivesOnlyInCleanupQueue()
    {
        // Rule #1's single exception: Directory.Delete appears in Core only
        // inside CleanupQueue.DeletePermanently. (File.Delete is also allowed
        // for the app's own cache files and the bin's $I sidecar.)
        string core = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "src", "DiskMap.Core"));
        var offenders = Directory.EnumerateFiles(core, "*.cs", SearchOption.AllDirectories)
            .Where(f => !f.Contains(Path.DirectorySeparatorChar + "obj" + Path.DirectorySeparatorChar))
            .Where(f => File.ReadAllText(f).Contains("Directory.Delete(", StringComparison.Ordinal))
            .Select(Path.GetFileName)
            .ToList();
        Assert.Equal(["CleanupQueue.cs"], offenders);
    }
}
