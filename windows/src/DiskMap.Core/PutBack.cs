using System.Buffers.Binary;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace DiskMap.Core;

/// <summary>
/// What the last cleanup moved to the Recycle Bin and where it went, kept
/// so it can be put back — after a relaunch too (TASK-080 port).
///
/// The Windows Recycle Bin has no API that returns where a file landed:
/// recycling writes a <c>$R&lt;id&gt;</c> data file plus a <c>$I&lt;id&gt;</c>
/// metadata file under <c>&lt;drive&gt;:\$Recycle.Bin\&lt;user-SID&gt;</c>.
/// The $I file carries the original path, so a commit resolves each item's
/// real bin path after the fact and records it here.
/// </summary>
public sealed record CleanupRecord(
    DateTimeOffset Date,
    List<CleanupRecord.Item> Items)
{
    public sealed record Item(string OriginalPath, string TrashedPath, long Bytes);

    public static string DefaultPath() =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "DiskMap", "last-cleanup.json");

    public static CleanupRecord? Load(string? path = null)
    {
        try
        {
            path ??= DefaultPath();
            if (!File.Exists(path)) return null;
            return JsonSerializer.Deserialize<CleanupRecord>(File.ReadAllText(path),
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
        }
        catch { return null; }
    }

    /// <summary>Written whole and atomically; an empty record replaces a used one.</summary>
    public void Save(string? path = null)
    {
        path ??= DefaultPath();
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string tmp = path + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(this));
        File.Move(tmp, path, overwrite: true);
    }
}

/// <summary>Outcome of a Put Back run.</summary>
public sealed record PutBackReport(
    List<CleanupRecord.Item> Restored,
    List<(CleanupRecord.Item Item, string Reason)> Skipped);

/// <summary>
/// Reads the Recycle Bin's per-user store: parse <c>$I*</c> files (the
/// metadata record for each recycled item — original path, size, deletion
/// time) and map them to their <c>$R*</c> payloads.
/// </summary>
public static class RecycleBinStore
{
    public sealed record Entry(string OriginalPath, string DataPath, string InfoPath,
        long OriginalBytes, long DeletedFileTimeUtc);

    /// <summary>
    /// Entries currently sitting in the bin on the volume that holds
    /// <paramref name="pathOnVolume"/> for the current user.
    /// </summary>
    public static IEnumerable<Entry> Entries(string pathOnVolume)
    {
        string? root = Path.GetPathRoot(Path.GetFullPath(pathOnVolume));
        if (root is null) yield break;
        string sid = System.Security.Principal.WindowsIdentity.GetCurrent().User?.Value ?? "";
        if (sid.Length == 0) yield break;
        string store = Path.Combine(root, "$Recycle.Bin", sid);
        if (!Directory.Exists(store)) yield break;

        IEnumerable<string> infoFiles;
        try { infoFiles = Directory.EnumerateFiles(store, "$I*"); }
        catch { yield break; }

        foreach (var infoFile in infoFiles)
        {
            Entry? entry = ReadInfoFile(infoFile);
            if (entry is not null) yield return entry;
        }
    }

    /// <summary>
    /// The newest bin entry whose recorded original path equals
    /// <paramref name="originalPath"/> — or null (emptied, or moved by
    /// another user/process).
    /// </summary>
    public static Entry? Resolve(string originalPath)
    {
        string normalized = Path.GetFullPath(originalPath).TrimEnd('\\');
        return Entries(originalPath)
            .Where(e => e.OriginalPath.Equals(normalized, StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(e => e.DeletedFileTimeUtc)
            .FirstOrDefault();
    }

    /// <summary>
    /// $I v1 (Win7/8): version(8)=1, size(8), deletedTime(8), name = 260
    /// UTF-16 chars fixed. v2 (Win10+): version(8)=2, size(8), time(8),
    /// nameLen(4 incl. null), name UTF-16 variable. Anything else: null.
    /// </summary>
    internal static Entry? ReadInfoFile(string infoPath)
    {
        byte[] data;
        try { data = File.ReadAllBytes(infoPath); }
        catch { return null; }
        if (data.Length < 24) return null;
        long version = BinaryPrimitives.ReadInt64LittleEndian(data.AsSpan(0));
        long size = BinaryPrimitives.ReadInt64LittleEndian(data.AsSpan(8));
        long deleted = BinaryPrimitives.ReadInt64LittleEndian(data.AsSpan(16));
        string original;
        if (version == 2)
        {
            if (data.Length < 28) return null;
            int chars = BinaryPrimitives.ReadInt32LittleEndian(data.AsSpan(24));
            int byteCount = Math.Min(chars * 2, data.Length - 28);
            if (byteCount <= 0) return null;
            original = System.Text.Encoding.Unicode.GetString(data.AsSpan(28, byteCount));
        }
        else if (version == 1)
        {
            int byteCount = Math.Min(260 * 2, data.Length - 24);
            if (byteCount <= 0) return null;
            original = System.Text.Encoding.Unicode.GetString(data.AsSpan(24, byteCount));
        }
        else return null;

        original = original.TrimEnd('\0');
        if (original.Length == 0) return null;
        string dataPath = Path.Combine(
            Path.GetDirectoryName(infoPath)!,
            "$R" + Path.GetFileName(infoPath)[2..]);
        if (!File.Exists(dataPath) && !Directory.Exists(dataPath)) return null;
        return new Entry(original, dataPath, infoPath, size, deleted);
    }
}

public static class PutBack
{
    /// <summary>
    /// Moves the last cleanup's items from the Recycle Bin back where they
    /// were. Never a removal: an item is skipped, with the reason, when
    /// it is no longer in the bin or when something new already sits at
    /// its old path (nothing is replaced). A missing parent folder is
    /// recreated. Only File.Move / Directory.Move — restoring a file.
    /// </summary>
    public static PutBackReport Run(CleanupRecord record)
    {
        var restored = new List<CleanupRecord.Item>();
        var skipped = new List<(CleanupRecord.Item, string)>();
        foreach (var item in record.Items)
        {
            string original = Path.GetFullPath(item.OriginalPath).TrimEnd('\\');
            string trashed = item.TrashedPath;
            bool inBin = File.Exists(trashed) || Directory.Exists(trashed);
            if (!inBin)
            {
                // The recorded bin path is stale — try resolving anew in
                // case the bin renamed it on a subsequent collision.
                var resolved = RecycleBinStore.Resolve(original);
                if (resolved is null)
                {
                    skipped.Add((item, "No longer in the Recycle Bin"));
                    continue;
                }
                trashed = resolved.DataPath;
            }
            if (File.Exists(original) || Directory.Exists(original))
            {
                skipped.Add((item, $"Something new is at {original}"));
                continue;
            }
            try
            {
                string? parent = Path.GetDirectoryName(original);
                if (parent is not null) Directory.CreateDirectory(parent);
                if (Directory.Exists(trashed)) Directory.Move(trashed, original);
                else File.Move(trashed, original);
                // The $I metadata record goes too — otherwise the bin
                // keeps listing a ghost entry. This deletes a metadata
                // sidecar inside $Recycle.Bin itself, never user data.
                string infoSibling = Path.Combine(
                    Path.GetDirectoryName(trashed)!,
                    "$I" + Path.GetFileName(trashed)[2..]);
                if (File.Exists(infoSibling)) File.Delete(infoSibling);
                restored.Add(item);
            }
            catch (Exception ex)
            {
                skipped.Add((item, ex.Message));
            }
        }
        return new PutBackReport(restored, skipped);
    }
}
