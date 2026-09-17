using DiskMap.Core.Native;

namespace DiskMap.Core;

/// <summary>
/// The safety layer: items are staged here first; nothing leaves disk
/// until the user explicitly confirms, and even then it goes to the
/// Recycle Bin via SHFileOperation(FOF_ALLOWUNDO) — never a direct delete —
/// so any mistake is recoverable exactly like a normal Explorer delete.
///
/// Mirrors the macOS CleanupQueue actor; a lock serializes access since
/// the operations are short except Commit, which is run off the UI thread.
/// </summary>
public sealed class CleanupQueue
{
    public sealed record StagedItem(
        Guid Id,
        string Path,
        /// <summary>Size of this file, not the bytes deleting it will free.</summary>
        long Size,
        string Reason,
        /// <summary>Set when this file shares physical extents with other staged items of the same key.</summary>
        string? SharesStorageGroup,
        /// <summary>Copies in the duplicate group this item came from.</summary>
        int GroupCopyCount);

    private readonly List<StagedItem> _items = [];
    private readonly object _gate = new();

    /// <summary>
    /// Paths that must never be staged, regardless of what a scan or
    /// heuristic suggests. Second, independent safety net on top of
    /// ACL/TrustedInstaller protections failing the delete — belt and
    /// suspenders, since a permission failure is a worse UX than never
    /// offering the item at all. Case-insensitive: Windows paths are.
    /// </summary>
    private static readonly string[] ExcludedPrefixes = BuildExcludedPrefixes();

    private static string[] BuildExcludedPrefixes()
    {
        string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        string programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        string programFilesX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        string programData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string systemDrive = Path.GetPathRoot(windows) ?? @"C:\";
        return
        [
            windows,                                                // C:\Windows
            programFiles,                                           // C:\Program Files
            programFilesX86,                                        // C:\Program Files (x86)
            Path.Combine(programData, "Microsoft"),                 // C:\ProgramData\Microsoft
            Path.Combine(localAppData, "Microsoft", "Windows"),     // per-user OS state
            Path.Combine(systemDrive, "$Recycle.Bin"),              // the bin itself
            Path.Combine(systemDrive, "System Volume Information"), // restore points / USN journal
            Path.Combine(systemDrive, "Recovery"),
        ];
    }

    public bool Stage(
        string path,
        long size,
        string reason,
        string? sharesStorageGroup = null,
        int groupCopyCount = 1)
    {
        string normalized = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar);
        lock (_gate)
        {
            foreach (var prefix in ExcludedPrefixes)
            {
                if (normalized.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
                    && (normalized.Length == prefix.Length || normalized[prefix.Length] is '\\' or '/'))
                {
                    return false;
                }
            }
            if (_items.Any(i => string.Equals(i.Path, normalized, StringComparison.OrdinalIgnoreCase)))
                return false;
            _items.Add(new StagedItem(
                Guid.NewGuid(), normalized, size, reason, sharesStorageGroup, Math.Max(groupCopyCount, 1)));
            return true;
        }
    }

    public void Unstage(Guid id)
    {
        lock (_gate) _items.RemoveAll(i => i.Id == id);
    }

    public IReadOnlyList<StagedItem> AllItems()
    {
        lock (_gate) return _items.ToArray();
    }

    /// <summary>
    /// Bytes a confirm would free. An ordinary file contributes its size.
    /// A shared-extent group contributes size once, and only when every
    /// copy from that group is still staged. Deleting one clone frees 0.
    /// </summary>
    public long TotalSize()
    {
        lock (_gate)
        {
            long plain = 0;
            var groups = new Dictionary<string, (int Staged, int CopyCount, long FileSize)>();
            foreach (var item in _items)
            {
                if (item.SharesStorageGroup is { } key)
                {
                    groups.TryGetValue(key, out var entry);
                    entry.Staged++;
                    entry.CopyCount = Math.Max(entry.CopyCount, item.GroupCopyCount);
                    entry.FileSize = item.Size;
                    groups[key] = entry;
                }
                else
                {
                    plain += item.Size;
                }
            }
            long shared = 0;
            foreach (var (_, entry) in groups)
                if (entry.Staged >= entry.CopyCount && entry.CopyCount > 0)
                    shared += entry.FileSize;
            return plain + shared;
        }
    }

    /// <summary>
    /// Executes the staged cleanup: moves every item to the Recycle Bin.
    /// Returns per-item results so the UI can report partial failures
    /// (e.g. an ACL-protected path) without losing track of what succeeded.
    /// Items that failed stay staged for retry.
    /// </summary>
    public List<(StagedItem Item, Exception? Error)> Commit()
    {
        StagedItem[] snapshot;
        lock (_gate) snapshot = _items.ToArray();

        var results = new List<(StagedItem, Exception?)>();
        foreach (var item in snapshot)
        {
            var error = Shell32.RecycleItem(item.Path);
            results.Add((item, error));
        }

        lock (_gate)
        {
            var failedIds = results.Where(r => r.Item2 is not null).Select(r => r.Item1.Id).ToHashSet();
            _items.RemoveAll(i => !failedIds.Contains(i.Id));
        }
        return results;
    }
}
