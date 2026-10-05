using DiskMap.Core;

namespace DiskMap.Core.Tests;

/// <summary>
/// Developer Catalog v2 (WIN-022..025): rules file decode, manifest
/// project attribution, lockfile → rebuild cost, git state, gitignore.
/// </summary>
public class DeveloperCatalogTests
{
    [Fact]
    public void BundledRulesDecodeCompletely()
    {
        Assert.True(DeveloperCatalog.LoadedRuleCount >= 20,
            $"expected the full rules file, got {DeveloperCatalog.LoadedRuleCount}");
    }

    /// <summary>
    /// scan/
    /// └── app/                 package.json + package-lock.json + .git
    ///     ├── src/app.js
    ///     └── node_modules/dep/index.js
    /// └── bare/                no manifest
    ///     └── node_modules/x/y.js
    /// </summary>
    private static FileTree DevTree()
    {
        var tree = new FileTree();
        int root = tree.AddNode("scan", -1, true, 0, 0, 0);
        int app = tree.AddNode("app", root, true, 0, 0, 0);
        tree.AddNode("package.json", app, false, 400, 400, 10);
        tree.AddNode("package-lock.json", app, false, 200_000, 200_000, 10);
        int git = tree.AddNode(".git", app, true, 0, 0, 0);
        tree.AddNode("config", git, false, 100, 100, 10);
        int src = tree.AddNode("src", app, true, 0, 0, 0);
        tree.AddNode("app.js", src, false, 5_000, 5_000, 30);
        int nm = tree.AddNode("node_modules", app, true, 0, 0, 0);
        int dep = tree.AddNode("dep", nm, true, 0, 0, 0);
        tree.AddNode("index.js", dep, false, 60_000_000, 60_000_000, 10);
        int bare = tree.AddNode("bare", root, true, 0, 0, 0);
        int bnm = tree.AddNode("node_modules", bare, true, 0, 0, 0);
        tree.AddNode("y.js", tree.AddNode("x", bnm, true, 0, 0, 0), false, 10_000_000, 10_000_000, 10);
        return tree;
    }

    [Fact]
    public void ManifestsAndLockfilesShapeTheCatalog()
    {
        var tree = DevTree();
        var totals = tree.RollUpSizes(SizeBasis.Allocated);
        var result = DeveloperCatalog.Build(tree, @"C:\scan", totals);

        Assert.Equal(2, result.Items.Count);
        var pinned = result.Items.First(i => i.AbsolutePath.Contains("app"));
        Assert.Equal("app", pinned.ProjectName);
        Assert.Equal("package.json", pinned.ProjectManifest);
        Assert.Equal("package-lock.json", pinned.Lockfile);
        Assert.Equal(RebuildCost.Networked, pinned.RebuildCost);

        var bare = result.Items.First(i => !i.AbsolutePath.Contains("app\\"));
        Assert.Equal("bare", bare.ProjectName);      // falls back to parent
        Assert.Null(bare.Lockfile);
        Assert.Equal(RebuildCost.NetworkedUnpinned, bare.RebuildCost);
        Assert.True(result.Summary.UnpinnedBytes >= bare.Bytes);
    }

    [Fact]
    public void ParentHoldingOnlyItsMatchedChildCountsOnce()
    {
        // AppData\Local\Android holds only Sdk: both match, same bytes —
        // the tie must keep the outer folder, not list 19 GB twice.
        var tree = new FileTree();
        int root = tree.AddNode("me", -1, true, 0, 0, 0);
        int appData = tree.AddNode("AppData", root, true, 0, 0, 0);
        int local = tree.AddNode("Local", appData, true, 0, 0, 0);
        int android = tree.AddNode("Android", local, true, 0, 0, 0);
        int sdk = tree.AddNode("Sdk", android, true, 0, 0, 0);
        tree.AddNode("system.img", sdk, false, 50_000_000, 50_000_000, 10);
        // Many same-size hits, as on a real drive: the sort is then truly
        // unstable and only the tie-break keeps Android before Sdk.
        int code = tree.AddNode("code", root, true, 0, 0, 0);
        for (int p = 0; p < 40; p++)
        {
            int project = tree.AddNode($"p{p}", code, true, 0, 0, 0);
            int nm = tree.AddNode("node_modules", project, true, 0, 0, 0);
            tree.AddNode("dep.js", nm, false, 50_000_000, 50_000_000, 10);
        }
        var totals = tree.RollUpSizes(SizeBasis.Allocated);

        var result = DeveloperCatalog.Build(tree, @"C:\Users\me", totals);
        var androidItems = result.Items
            .Where(i => i.AbsolutePath.Contains(@"\Android", StringComparison.OrdinalIgnoreCase)).ToList();
        Assert.Single(androidItems);
        Assert.Equal(41 * 50_000_000L, result.Summary.TotalBytes);
    }

    [Fact]
    public void HitsInsideKeptHitsCollapse()
    {
        var tree = new FileTree();
        int root = tree.AddNode("scan", -1, true, 0, 0, 0);
        int app = tree.AddNode("app", root, true, 0, 0, 0);
        tree.AddNode("Cargo.toml", app, false, 200, 200, 10);
        int target = tree.AddNode("target", app, true, 0, 0, 0);
        tree.AddNode("a.o", target, false, 30_000_000, 30_000_000, 10);
        // A nested build dir under target — swallowed by the outer hit.
        int nested = tree.AddNode("build", target, true, 0, 0, 0);
        tree.AddNode("out.bin", nested, false, 1_000_000, 1_000_000, 10);

        var totals = tree.RollUpSizes(SizeBasis.Allocated);
        var result = DeveloperCatalog.Build(tree, @"C:\scan", totals);
        Assert.Single(result.Items);
        Assert.Equal("target", result.Items[0].DisplayName);
        Assert.Equal(DeveloperEcosystem.Rust, result.Items[0].Ecosystem);
        // "app" is the project via Cargo.toml; ignoring lockfile check (no lockEcosystem on target).
        Assert.Single(result.Projects);
        Assert.Equal("Cargo.toml", result.Projects[0].Manifest);
    }

    [Fact]
    public void GitStateReadsRealDotGit()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"dm-git-{Guid.NewGuid():N}");
        try
        {
            string git = Path.Combine(dir, ".git");
            Directory.CreateDirectory(Path.Combine(git, "refs", "heads"));
            Directory.CreateDirectory(Path.Combine(git, "refs", "remotes", "origin"));
            File.WriteAllText(Path.Combine(git, "config"),
                "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = https://x/y.git\n");
            string sha = new string('a', 40) + "\n";
            File.WriteAllText(Path.Combine(git, "refs", "heads", "main"), sha);
            File.WriteAllText(Path.Combine(git, "refs", "remotes", "origin", "main"), sha);

            Assert.IsType<GitState.InSync>(GitInspector.Inspect(dir));

            // A local-only branch differs from the remote.
            File.WriteAllText(Path.Combine(git, "refs", "heads", "wip"), new string('b', 40) + "\n");
            var state = GitInspector.Inspect(dir);
            var differs = Assert.IsType<GitState.Differs>(state);
            Assert.Equal(["wip"], differs.Branches);

            // No remote → this folder may be the only copy.
            File.WriteAllText(Path.Combine(git, "config"), "[core]\n\tbare = false\n");
            Assert.IsType<GitState.NoRemote>(GitInspector.Inspect(dir));

            // No .git at all.
            var plain = Path.Combine(Path.GetTempPath(), $"dm-plain-{Guid.NewGuid():N}");
            Directory.CreateDirectory(plain);
            Assert.IsType<GitState.NotARepository>(GitInspector.Inspect(plain));
            Directory.Delete(plain);
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public void GitIgnoreMarksDisposableBytes()
    {
        var tree = new FileTree();
        int root = tree.AddNode("repo", -1, true, 0, 0, 0);
        int git = tree.AddNode(".git", root, true, 0, 0, 0);
        tree.AddNode("info", git, true, 0, 0, 0);
        tree.AddNode(".gitignore", root, false, 50, 50, 1);   // in the scan
        int src = tree.AddNode("src", root, true, 0, 0, 0);
        tree.AddNode("main.cs", src, false, 5_000, 5_000, 1);
        int bin = tree.AddNode("bin", root, true, 0, 0, 0);
        tree.AddNode("app.dll", bin, false, 900_000, 900_000, 1);
        tree.AddNode("keep.tmp", root, false, 2_000, 2_000, 1);
        tree.AddNode("debug.log", root, false, 3_000, 3_000, 1);

        var dir = Path.Combine(Path.GetTempPath(), $"dm-repo-{Guid.NewGuid():N}");
        try
        {
            Directory.CreateDirectory(Path.Combine(dir, ".git", "info"));
            File.WriteAllText(Path.Combine(dir, ".gitignore"), "bin/\n*.log\n!keep.tmp\n");

            var totals = tree.RollUpSizes(SizeBasis.Allocated);
            var result = GitIgnoreRules.IgnoredBytes(tree, 0, dir, totals);
            // bin (900_000, whole subtree) + debug.log (3_000); keep.tmp re-included.
            Assert.Equal(903_000, result.IgnoredBytes);
            Assert.Equal(1, result.IgnoreFileCount);
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public void RecipesMatchWindowsPaths()
    {
        var npm = CleanupRecipes.RecipeFor(@"C:\Users\u\AppData\Roaming\npm-cache");
        Assert.NotNull(npm);
        Assert.Equal("npm cache clean --force", npm!.Command);

        var docker = CleanupRecipes.RecipeFor(@"C:\Users\u\AppData\Local\Docker\wsl\data");
        // ".docker"/pathSuffix — the Local\Docker tree matches its suffix recipe.
        Assert.NotNull(docker);
        Assert.True(docker!.TrashIsUnsafe);

        Assert.Null(CleanupRecipes.RecipeFor(@"C:\Users\u\Pictures\holiday"));
    }

    [Fact]
    public void ProtectedPathsAreNeverOpportunities()
    {
        var tree = new FileTree();
        int root = tree.AddNode("scan", -1, true, 0, 0, 0);
        // A "build" dir under an installed app's path — must be skipped entirely.
        int pf = tree.AddNode("Program Files", root, true, 0, 0, 0);
        int appDir = tree.AddNode("SomeApp", pf, true, 0, 0, 0);
        int bin = tree.AddNode("bin", appDir, true, 0, 0, 0);
        tree.AddNode("app.exe", bin, false, 50_000_000, 50_000_000, 10);

        var totals = tree.RollUpSizes(SizeBasis.Allocated);
        var result = DeveloperCatalog.Build(tree, @"C:\", totals);
        // "bin" under Program Files is app content — never a dev hit.
        Assert.DoesNotContain(result.Items, i => i.DisplayName == "bin");
    }
}
