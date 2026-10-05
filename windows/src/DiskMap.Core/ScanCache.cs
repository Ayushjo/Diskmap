using System.Text.Json;
using System.Text.Json.Serialization;

namespace DiskMap.Core;

/// <summary>
/// The rescan baseline (WIN-031): the last scan's tree, plus the journal
/// cursor captured BEFORE that scan ran, persisted so a rescan replays
/// only what changed — same contract as the macOS FSEvents baseline.
/// Files live under `%LOCALAPPDATA%\DiskMap\ScanCache\<fnv-of-root>`:
/// `.dmap` (snapshot codec — shared binary format) + `.marker.json`.
/// </summary>
public static class ScanCache
{
    public sealed record Baseline(
        DiskSnapshot Snapshot,
        UsnJournal.Marker Marker,
        string Backend);

    private sealed class MarkerFile
    {
        [JsonPropertyName("rootPath")] public string RootPath { get; set; } = "";
        [JsonPropertyName("backend")] public string Backend { get; set; } = "";
        [JsonPropertyName("journalId")] public long JournalId { get; set; }
        [JsonPropertyName("usn")] public long Usn { get; set; }
        [JsonPropertyName("savedUtc")] public long SavedUtc { get; set; }
    }

    public static string DirectoryPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "DiskMap", "ScanCache");

    private static string Key(string rootPath) => StorageHistory.Hash(rootPath);
    private static string TreePath(string rootPath) =>
        Path.Combine(DirectoryPath, Key(rootPath) + ".dmap");
    private static string MarkerPath(string rootPath) =>
        Path.Combine(DirectoryPath, Key(rootPath) + ".marker.json");

    // Saves run in the background, one after another: the 500 MB encode +
    // write of a full-volume tree cost ~2 s on every scan's critical path.
    // Load and Remove wait for them, so a rescan reads the newest baseline
    // and a forced full rescan (Remove) can't be undone by a late save.
    private static readonly object PendingGate = new();
    private static Task _pending = Task.CompletedTask;

    /// <summary>
    /// Queues <see cref="Save"/> off the caller's thread. The tree must not
    /// be mutated afterwards — ScanEngine hands it over only once final.
    /// </summary>
    public static void SaveInBackground(string rootPath, FileTree tree, UsnJournal.Marker marker)
    {
        lock (PendingGate)
            _pending = _pending.ContinueWith(_ => Save(rootPath, tree, marker), TaskScheduler.Default);
    }

    /// <summary>Blocks until every queued background save has landed.</summary>
    public static void WaitForPendingSaves()
    {
        Task pending;
        lock (PendingGate) pending = _pending;
        pending.Wait();
    }

    public static Baseline? Load(string rootPath)
    {
        WaitForPendingSaves();
        try
        {
            var marker = JsonSerializer.Deserialize<MarkerFile>(
                File.ReadAllText(MarkerPath(rootPath)),
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            // Any scan backend's baseline works — what matters is that the
            // tree carries file ids (a non-NTFS walk's marker simply won't
            // exist, since the journal query fails there first).
            if (marker is null || marker.RootPath != rootPath)
                return null;
            var snapshot = SnapshotStore.Load(TreePath(rootPath));
            // A tree with no file ids can't map journal FRNs — treat as absent.
            if (snapshot.Tree.Count == 0 || snapshot.Tree.FileId.All(id => id == 0))
                return null;
            return new Baseline(snapshot, new UsnJournal.Marker(marker.JournalId, marker.Usn), marker.Backend);
        }
        catch { return null; }
    }

    /// <summary>
    /// Written whole and atomically: tree first, marker second — a crash
    /// between them leaves the OLD marker replaying changes the new tree
    /// already contains, which the FRN re-read absorbs idempotently.
    /// </summary>
    public static void Save(string rootPath, FileTree tree, UsnJournal.Marker marker, string backend = "mft")
    {
        try
        {
            Directory.CreateDirectory(DirectoryPath);
            string treePath = TreePath(rootPath);
            string tmp = treePath + ".tmp";
            File.WriteAllBytes(tmp, SnapshotCodec.Encode(
                new DiskSnapshot(rootPath, DateTimeOffset.Now, tree)));
            File.Move(tmp, treePath, overwrite: true);
            var file = new MarkerFile
            {
                RootPath = rootPath,
                Backend = backend,
                JournalId = marker.JournalId,
                Usn = marker.NextUsn,
                SavedUtc = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
            };
            string markerPath = MarkerPath(rootPath);
            string markerTmp = markerPath + ".tmp";
            File.WriteAllText(markerTmp, JsonSerializer.Serialize(file));
            File.Move(markerTmp, markerPath, overwrite: true);
        }
        catch { /* a cache write failure only costs the next scan's speed */ }
    }

    /// <summary>Drops the baseline — the "full rescan" guarantee (Ctrl+Shift+R).</summary>
    public static void Remove(string rootPath)
    {
        WaitForPendingSaves();
        try
        {
            File.Delete(TreePath(rootPath));
            File.Delete(MarkerPath(rootPath));
        }
        catch { }
    }
}
