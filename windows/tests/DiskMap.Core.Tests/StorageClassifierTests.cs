using DiskMap.Core;

namespace DiskMap.Core.Tests;

/// <summary>The preconfigured laptop categories and their cleanup advice.</summary>
public class StorageClassifierTests
{
    [Theory]
    [InlineData(@"C:\Users\me\AppData\Local\wsl\{d1650d97-06cf}\ext4.vhdx", "vms", CleanupAdvice.Warn)]
    [InlineData(@"C:\Users\me\AppData\Local\Packages\CanonicalGroupLimited.Ubuntu22.04LTS_79rhkp1fndgsc\LocalState\ext4.vhdx", "vms", CleanupAdvice.Warn)]
    [InlineData(@"C:\Users\me\AppData\Local\Docker\wsl\disk\docker_data.vhdx", "vms", CleanupAdvice.Warn)]
    [InlineData(@"C:\Users\me\.android\avd\Pixel_4a.avd\userdata-qemu.img.qcow2", "vms", CleanupAdvice.Warn)]
    [InlineData(@"C:\Users\me\AppData\Local\Android\Sdk\system-images\android-34\system.img", "devtools", CleanupAdvice.Review)]
    [InlineData(@"C:\pagefile.sys", "system", CleanupAdvice.Never)]
    [InlineData(@"C:\hiberfil.sys", "system", CleanupAdvice.Never)]
    [InlineData(@"C:\Windows\System32\ntoskrnl.exe", "system", CleanupAdvice.Never)]
    [InlineData(@"C:\Users\me\Documents\models\vibe\model-00001-of-00003.safetensors", "ai", CleanupAdvice.Review)]
    [InlineData(@"C:\Users\me\.cache\huggingface\hub\x\blob", "ai", CleanupAdvice.Review)]
    [InlineData(@"C:\Users\me\Downloads\Sonoma 14\Sonoma 14.iso", "installers", CleanupAdvice.Fine)]
    [InlineData(@"C:\Users\me\AppData\Local\Google\Chrome\User Data\optimization_guide\weights.bin", "browsers", CleanupAdvice.Warn)]
    [InlineData(@"C:\Users\me\Documents\codes\minorproject\.git\objects\pack\pack-9fac.pack", "projects", CleanupAdvice.Warn)]
    [InlineData(@"C:\Users\me\Documents\codes\Farming\fg-01.bin", "projects", CleanupAdvice.Fine)]
    [InlineData(@"C:\Users\me\AppData\Local\npm-cache\_cacache\index", "pkgcache", CleanupAdvice.Fine)]
    [InlineData(@"C:\Program Files\App\app.exe", "apps", CleanupAdvice.Warn)]
    [InlineData(@"C:\Users\me\Pictures\trip.jpg", "media", CleanupAdvice.Fine)]
    [InlineData(@"C:\Users\me\something.dat", "other", CleanupAdvice.Fine)]
    public void ClassifiesFilesFromARealLaptop(string path, string classId, CleanupAdvice advice)
    {
        var verdict = StorageClassifier.Classify(path, isDirectory: false);
        Assert.Equal(classId, verdict.Class.Id);
        Assert.Equal(advice, verdict.Advice);
    }

    [Fact]
    public void DependenciesInsideAProjectFolderStayDependencies()
    {
        var v = StorageClassifier.Classify(@"C:\Users\me\Documents\codes\web\node_modules", isDirectory: true);
        Assert.Equal("deps", v.Class.Id);
        var next = StorageClassifier.Classify(@"C:\Users\me\Documents\codes\web\.next", isDirectory: true);
        Assert.Equal("deps", next.Class.Id);
    }

    [Fact]
    public void RecycleBinAndRestorePointsAreNeverFindings()
    {
        Assert.True(StorageClassifier.IsSystemHolding(@"C:\$Recycle.Bin\S-1-5-21\$RABC123\node_modules"));
        Assert.True(StorageClassifier.IsSystemHolding(@"C:\System Volume Information\x"));
        Assert.False(StorageClassifier.IsSystemHolding(@"C:\Users\me\Documents\codes\app\node_modules"));
    }

    [Fact]
    public void WarnVerdictsSayWhatToDoInstead()
    {
        var wsl = StorageClassifier.Classify(@"C:\Users\me\AppData\Local\wsl\{x}\ext4.vhdx", false);
        Assert.Contains("Linux", wsl.Note);
        Assert.Contains("wsl --unregister", wsl.Instead);
    }

    [Fact]
    public void RollupIsExclusiveAndSumsToTheRoot()
    {
        // C:\ ─ Windows\kernel(10) · pagefile.sys(5) · Users\me\
        //        Documents\codes\app\{main.cs(3), node_modules\x(7)} ·
        //        AppData\Local\wsl\d\ext4.vhdx(40) · Downloads\a.iso(4) · notes.txt(1)
        var tree = new FileTree();
        int root = tree.AddNode("C:", -1, true, 0, 0, 0);
        int win = tree.AddNode("Windows", root, true, 0, 0, 0);
        tree.AddNode("kernel", win, false, 10, 10, 0);
        tree.AddNode("pagefile.sys", root, false, 5, 5, 0);
        int users = tree.AddNode("Users", root, true, 0, 0, 0);
        int me = tree.AddNode("me", users, true, 0, 0, 0);
        int docs = tree.AddNode("Documents", me, true, 0, 0, 0);
        int codes = tree.AddNode("codes", docs, true, 0, 0, 0);
        int app = tree.AddNode("app", codes, true, 0, 0, 0);
        tree.AddNode("main.cs", app, false, 3, 3, 0);
        int nm = tree.AddNode("node_modules", app, true, 0, 0, 0);
        tree.AddNode("x", nm, false, 7, 7, 0);
        int appData = tree.AddNode("AppData", me, true, 0, 0, 0);
        int local = tree.AddNode("Local", appData, true, 0, 0, 0);
        int wsl = tree.AddNode("wsl", local, true, 0, 0, 0);
        int distro = tree.AddNode("d", wsl, true, 0, 0, 0);
        tree.AddNode("ext4.vhdx", distro, false, 40, 40, 0);
        int dl = tree.AddNode("Downloads", me, true, 0, 0, 0);
        tree.AddNode("a.iso", dl, false, 4, 4, 0);
        tree.AddNode("notes.txt", me, false, 1, 1, 0);
        var totals = tree.RollUpSizes(SizeBasis.Logical);

        var rollup = StorageClassifier.Rollup(tree, @"C:\", totals);
        long Bytes(string id) => rollup.FirstOrDefault(r => r.Class.Id == id)?.Bytes ?? 0;
        Assert.Equal(15, Bytes("system"));      // Windows + pagefile
        Assert.Equal(3, Bytes("projects"));
        Assert.Equal(7, Bytes("deps"));
        Assert.Equal(40, Bytes("vms"));
        Assert.Equal(4, Bytes("installers"));
        Assert.Equal(1, Bytes("other"));
        Assert.Equal(totals[root], rollup.Sum(r => r.Bytes));
        Assert.Equal("other", rollup[^1].Class.Id);   // Other always last
    }
}
