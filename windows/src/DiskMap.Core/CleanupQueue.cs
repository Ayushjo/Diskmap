using DiskMap.Core.Native;

namespace DiskMap.Core;

/// <summary>
/// The safety layer: items are staged here first; nothing leaves disk
/// until the user explicitly confirms, and even then it goes to the
/// Recycle Bin via SHFileOperation(FOF_ALLOWUNDO) — never a direct delete —
/// so any mistake is recoverable exactly like a normal Explorer delete.
///
/// Mirrors the macOS CleanupQueue actor (TASK-038). The queue measures
/// each staged path itself (StorageSharing.ProfileAt, background) so
/// every staging surface gets correct reclaim math — a hard-linked file
/// frees its bytes only when every name of the inode is queued; a staged
/// folder's children staged separately count once.
///
/// Windows honesty rule (see StorageSharing): there is no clone-refcount
/// API, so extent sharing is never treated as reclaimable — only
/// hard-link groups, whose member count the filesystem reports exactly.
/// </summary>
public sealed class CleanupQueue
{
    public sealed class StagedItem
    {
        public Guid Id { get; } = Guid.NewGuid();
        public required string Path { get; init; }
        /// <summary>Size of this file, not the bytes deleting it will free.</summary>
        public required long Size { get; init; }
        public required string Reason { get; init; }
        /// <summary>Caller hint: shares extents with other staged items of the same key (used only when the path couldn't be examined).</summary>
        public string? SharesStorageGroup { get; init; }
        /// <summary>Copies in the duplicate group this item came from.</summary>
        public int GroupCopyCount { get; init; } = 1;
        /// <summary>What the filesystem says this path shares — measured by the queue itself. Null while measuring or on failure.</summary>
        public StorageSharing.Profile? Sharing { get; internal set; }
        /// <summary>True until the background measurement finishes.</summary>
        public bool IsMeasuring { get; internal set; }
    }

    /// <summary>What confirming would free, and why the rest would not.</summary>
    public sealed class ReclaimEstimate
    {
        /// <summary>Bytes freed once the Recycle Bin is emptied — recycling alone frees nothing.</summary>
        public long Bytes { get; init; }
        /// <summary>Hard-linked data that stays in use because some of its names are not queued.</summary>
        public long HeldByUnqueuedCopies { get; init; }
        /// <summary>Blocks shared with something unidentifiable. Not counted.</summary>
        public long SharedUnattributed { get; init; }
        /// <summary>True when the real figure may be higher than <see cref="Bytes"/>.</summary>
        public bool IsLowerBound { get; init; }
        /// <summary>Bytes attributed per item — items inside a queued folder get 0 (the folder carries them).</summary>
        public IReadOnlyDictionary<Guid, long> PerItem { get; init; } =
            new Dictionary<Guid, long>();
        /// <summary>
        /// True while any item is still being measured — the UI must not
        /// offer the destructive action on a provisional figure.
        /// </summary>
        public bool IsCalculating { get; init; }
        public static readonly ReclaimEstimate Empty = new();
    }

    /// <summary>One row of a commit's outcome.</summary>
    public sealed record CommitEntry(
        StagedItem Item,
        Exception? Error,
        /// <summary>True when this item sat inside a folder that was recycled in the same commit, so it went with its folder.</summary>
        bool MovedWithFolder,
        /// <summary>This item's share of <see cref="CommitReport.FreedWhenEmptied"/>.</summary>
        long FreedBytes);

    public sealed record CommitReport(
        IReadOnlyList<CommitEntry> Entries,
        /// <summary>Recomputed over what actually moved, so a partial failure never reports space from an item still on disk.</summary>
        long FreedWhenEmptied,
        bool IsLowerBound);

    private readonly List<StagedItem> _items = [];
    private readonly object _gate = new();
    private readonly List<TaskCompletionSource> _measurementWaiters = [];

    /// <summary>Fired when a background measurement lands — the staged figures changed.</summary>
    public event EventHandler? Measured;

    // ---- Seeded staging (WIN-013) ----
    // After a scan, staging a folder inside the scan root can measure from
    // the tree instead of re-walking the disk — but only when the journal
    // proves nothing under it changed since the scan's marker.
    private FileTree? _scanTree;
    private string? _scanRoot;
    private UsnJournal.Marker? _scanMarker;
    private HashSet<int>? _scanDenied;

    /// <summary>
    /// The scan's context for instant staging measurement. Called by the
    /// model after each scan completes; a walk-backend tree without file
    /// ids or a missing marker simply means every stage walks, like today.
    /// </summary>
    public void SetScanContext(
        FileTree tree, string rootPath, UsnJournal.Marker? marker,
        IReadOnlyCollection<int> deniedDirectoryIds)
    {
        lock (_gate)
        {
            _scanTree = tree;
            _scanRoot = rootPath.TrimEnd('\\', '/');
            _scanMarker = marker;
            _scanDenied = deniedDirectoryIds.Count > 0 ? new HashSet<int>(deniedDirectoryIds) : null;
        }
    }

    /// <summary>Test seam: replaces the journal read (returns the changed-FRN set).</summary>
    internal Func<UsnJournal.Marker, HashSet<long>?>? JournalChangesForTest;

    /// <summary>
    /// Staging measurement straight from the scan tree (TASK-082 port):
    /// the journal confirms nothing under the path changed since the
    /// scan's marker, so the tree's own rows are the measurement. Null
    /// unless every check passes — the caller then walks the real path.
    /// </summary>
    internal StorageSharing.Profile? TrySeededProfile(string path)
    {
        FileTree tree; UsnJournal.Marker marker; HashSet<int>? denied;
        string root;
        lock (_gate)
        {
            if (_scanTree is null || _scanRoot is null || _scanMarker is null) return null;
            tree = _scanTree; marker = _scanMarker.Value;
            denied = _scanDenied; root = _scanRoot;
        }
        string normalized = Path.GetFullPath(path).TrimEnd('\\', '/');
        if (!normalized.StartsWith(root + '\\', StringComparison.OrdinalIgnoreCase)) return null;

        // Path → node: descend the tree by name.
        int node = 0;
        foreach (var part in normalized[(root.Length + 1)..].Split('\\'))
        {
            int child = tree.FirstChild[node];
            int found = -1;
            while (child != -1)
            {
                if (tree.NameOf(child).Equals(part, StringComparison.OrdinalIgnoreCase)) { found = child; break; }
                child = tree.NextSibling[child];
            }
            if (found < 0) return null;
            node = found;
        }

        // Change check: every file id under the staged dir must be absent
        // from the journal's delta since the scan's marker.
        var subtreeFrns = new HashSet<long>();
        var stack = new Stack<int>([node]);
        while (stack.TryPop(out int id))
        {
            long frn = tree.FileId[id];
            if (frn != 0) subtreeFrns.Add(frn);
            int c = tree.FirstChild[id];
            while (c != -1) { stack.Push(c); c = tree.NextSibling[c]; }
        }
        HashSet<long>? changed = JournalChangesForTest is { } probe
            ? probe(marker)
            : JournalChangesSince(marker, normalized);
        if (changed is null) return null;      // can't verify → walk
        if (subtreeFrns.Overlaps(changed)) return null;

        // Build the profile from the tree; hard-linked files still get a
        // real link count (the tree flags the fact but not the number).
        var namesByFrn = new Dictionary<long, List<int>>();
        for (int i = 0; i < tree.Count; i++)
        {
            long frn = tree.FileId[i];
            if (frn == 0) continue;
            (namesByFrn.TryGetValue(frn, out var l) ? l : namesByFrn[frn] = []).Add(i);
        }
        var profile = new StorageSharing.Profile();
        var walk = new Stack<int>([node]);
        while (walk.TryPop(out int id))
        {
            if (tree.IsDirectory[id])
            {
                if (denied is not null && denied.Contains(id)) profile.IsComplete = false;
                int c = tree.FirstChild[id];
                while (c != -1) { walk.Push(c); c = tree.NextSibling[c]; }
                continue;
            }
            long frn = tree.FileId[id];
            if (frn == 0 || (tree.Flags[id] & NodeFlags.HardLink) == 0)
            {
                profile.Add(new StorageSharing.FileFacts(0, frn, false, 1, tree.AllocatedSize[id]));
                continue;
            }
            // Hard-linked: the link count must be real, so ask the file —
            // these are rare, one open each.
            string filePath = tree.PathOf(id, root);
            var facts = StorageSharing.FactsOfPublic(filePath);
            if (facts is null) { profile.IsComplete = false; continue; }
            // NamesStaged = the share of this inode's names inside the
            // staged subtree — names elsewhere stay outside.
            int inside = namesByFrn.TryGetValue(frn, out var sibs)
                ? sibs.Count(s => IsUnder(tree, s, node)) : 1;
            profile.Add(facts.Value with { LinkCount = facts.Value.LinkCount },
                namesStaged: inside);
        }
        return profile;
    }

    private static bool IsUnder(FileTree tree, int id, int ancestor)
    {
        for (int p = tree.Parent[id]; p >= 0; p = tree.Parent[p])
            if (p == ancestor) return true;
        return false;
    }

    /// <summary>Changed FRNs since <paramref name="marker"/> on <paramref name="path"/>'s volume; null when unreadable.</summary>
    private static HashSet<long>? JournalChangesSince(UsnJournal.Marker marker, string path)
    {
        try
        {
            string? volumeRoot = Path.GetPathRoot(path);
            if (volumeRoot is null || volumeRoot.Length < 3 || volumeRoot[1] != ':') return null;
            if (!Win32.EnableBackupPrivileges()) return null;
            string volumePath = @"\\?\" + char.ToUpperInvariant(volumeRoot[0]) + ":";
            using var volume = MftScanner.OpenVolume(volumePath);
            if (volume.IsInvalid) return null;
            if (UsnJournal.Query(volume) is not { } current
                || current.JournalId != marker.JournalId)
                return null;
            var changes = UsnJournal.ReadAll(volume, marker, CancellationToken.None);
            if (changes is null || changes.Wrapped) return null;
            return changes.Entries.Select(e => e.Frn).ToHashSet();
        }
        catch { return null; }
    }

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
            windows,                                                // C:\Windows (covers WinSxS)
            programFiles,                                           // C:\Program Files
            programFilesX86,                                        // C:\Program Files (x86)
            Path.Combine(programData, "Microsoft"),                 // C:\ProgramData\Microsoft
            Path.Combine(localAppData, "Microsoft", "Windows"),     // per-user OS state
            // WIN-069 audit: user-package execution aliases — reparse-
            // point-heavy, and not under Microsoft\Windows. Never stage.
            Path.Combine(localAppData, "Microsoft", "WindowsApps"),
            Path.Combine(systemDrive, "$Recycle.Bin"),              // the bin itself
            Path.Combine(systemDrive, "System Volume Information"), // restore points / USN journal
            Path.Combine(systemDrive, "Recovery"),
            // WIN-069 audit: memory files at the drive root — locked at
            // best, corrupting at worst; never stageable.
            Path.Combine(systemDrive, "pagefile.sys"),
            Path.Combine(systemDrive, "hiberfil.sys"),
            Path.Combine(systemDrive, "swapfile.sys"),
        ];
    }

    /// <summary>
    /// True when <paramref name="path"/> sits under a never-stage prefix
    /// (the exact test <see cref="Stage"/> applies). Catalogs use this to
    /// demote hits to "keep" — and skip them entirely — instead of
    /// offering a location the queue would refuse anyway.
    /// </summary>
    public static bool IsExcludedPath(string path)
    {
        string normalized = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar);
        foreach (var prefix in ExcludedPrefixes)
        {
            if (normalized.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
                && (normalized.Length == prefix.Length || normalized[prefix.Length] is '\\' or '/'))
            {
                return true;
            }
        }
        return false;
    }

    /// <summary>
    /// True when <paramref name="path"/> belongs to an installed app —
    /// the Windows counterpart of the macOS "inside a .app bundle" guard:
    /// a node_modules inside an installed app's folder is part of that
    /// app, not a developer artifact, and removing it breaks the app.
    /// </summary>
    public static bool IsInsideInstalledApp(string path)
    {
        string programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        string programFilesX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        string normalized = Path.GetFullPath(path).TrimEnd('\\');
        foreach (var prefix in new[] { programFiles, programFilesX86 })
        {
            if (prefix.Length > 0
                && normalized.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
                && (normalized.Length == prefix.Length || normalized[prefix.Length] == '\\'))
            {
                return true;
            }
        }
        // Packaged apps (MSIX / Store) live in WindowsApps.
        return normalized.Contains(@"\WindowsApps\", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Stages a path. Returns immediately; the real measurement runs on a
    /// background thread and lands on the item's <see cref="StagedItem.Sharing"/>
    /// (IsMeasuring flips false, <see cref="Measured"/> fires).
    /// </summary>
    public bool Stage(
        string path,
        long size,
        string reason,
        string? sharesStorageGroup = null,
        int groupCopyCount = 1)
    {
        string normalized = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar);
        StagedItem item;
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
            item = new StagedItem
            {
                Path = normalized, Size = size, Reason = reason,
                SharesStorageGroup = sharesStorageGroup,
                GroupCopyCount = Math.Max(groupCopyCount, 1),
                IsMeasuring = true,
            };
            _items.Add(item);
        }
        // Measure off the gate and off the UI thread: a huge folder takes
        // seconds, so staging returns at once and the figure fills in.
        var id = item.Id;
        _ = Task.Run(() =>
        {
            // WIN-013: a folder inside the last scan measures instantly
            // when the journal proves its subtree is unchanged.
            var sharing = TrySeededProfile(normalized) ?? StorageSharing.ProfileAt(normalized);
            lock (_gate)
            {
                var idx = _items.FindIndex(i => i.Id == id);
                if (idx < 0) return;
                _items[idx].Sharing = sharing;
                _items[idx].IsMeasuring = false;
                ResumeWaitersIfSettled();
            }
            Measured?.Invoke(this, EventArgs.Empty);
        });
        return true;
    }

    private void ResumeWaitersIfSettled()
    {
        if (_items.Any(i => i.IsMeasuring)) return;
        var waiters = _measurementWaiters.ToArray();
        _measurementWaiters.Clear();
        foreach (var w in waiters) w.TrySetResult();
    }

    /// <summary>Suspends until every staged item has been measured.</summary>
    public Task WaitForMeasurements()
    {
        lock (_gate)
        {
            if (!_items.Any(i => i.IsMeasuring)) return Task.CompletedTask;
            var tcs = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            _measurementWaiters.Add(tcs);
            return tcs.Task;
        }
    }

    public void Unstage(Guid id)
    {
        lock (_gate)
        {
            _items.RemoveAll(i => i.Id == id);
            ResumeWaitersIfSettled();
        }
    }

    public IReadOnlyList<StagedItem> AllItems()
    {
        lock (_gate) return _items.ToArray();
    }

    /// <summary>Bytes a confirm would free once the bin is emptied.</summary>
    public long TotalSize() => Estimate().Bytes;

    /// <summary>What a commit would free — see <see cref="Estimate(IReadOnlyList{StagedItem})"/>.</summary>
    public ReclaimEstimate Estimate()
    {
        lock (_gate) return Estimate(_items);
    }

    /// <summary>
    /// Reclaim math across a set of staged items (TASK-038 port):
    /// - An item inside another queued item's folder is skipped: the
    ///   folder's profile already contains it.
    /// - Ordinary data counts in full.
    /// - A hard-linked inode counts once, and only when every one of its
    ///   names is queued — <c>nNumberOfLinks</c> is authoritative.
    /// - Items that could not be examined fall back to the caller's size
    ///   plus the caller's shared-storage hint (the pre-TASK-038 rule).
    /// </summary>
    internal static ReclaimEstimate Estimate(IReadOnlyList<StagedItem> items)
    {
        var perItem = new Dictionary<Guid, long>();
        long heldByUnqueued = 0, sharedUnattributed = 0;
        bool isLowerBound = false, isCalculating = false;
        var ordered = items.OrderBy(i => i.Path, StringComparer.OrdinalIgnoreCase).ToList();
        var covered = CoveredItemIds(ordered);

        var hardLinks = new Dictionary<StorageSharing.InodeKey,
            (long Bytes, uint LinkCount, int NamesStaged, Guid Owner)>();
        var hinted = new Dictionary<string, (int Staged, int CopyCount, long FileSize, Guid Owner)>();

        foreach (var item in ordered)
        {
            perItem[item.Id] = 0;
            if (covered.Contains(item.Id)) continue;

            if (item.IsMeasuring)
            {
                // Provisional until measured: the caller's size, flagged.
                isCalculating = true;
                perItem[item.Id] += item.Size;
                continue;
            }
            if (item.Sharing is not { } profile)
            {
                isLowerBound = true;
                if (item.SharesStorageGroup is { } key)
                {
                    hinted.TryGetValue(key, out var entry);
                    entry.Staged++;
                    entry.CopyCount = Math.Max(entry.CopyCount, item.GroupCopyCount);
                    entry.FileSize = item.Size;
                    if (entry.Staged == 1) entry.Owner = item.Id;
                    hinted[key] = entry;
                }
                else
                {
                    perItem[item.Id] += item.Size;
                }
                continue;
            }

            perItem[item.Id] += profile.OwnedBytes;
            sharedUnattributed += profile.SharedUnattributedBytes;
            if (profile.SharedUnattributedBytes > 0 || !profile.IsComplete)
                isLowerBound = true;
            foreach (var (key, share) in profile.HardLinks)
            {
                if (hardLinks.TryGetValue(key, out var existing))
                    hardLinks[key] = (existing.Bytes, existing.LinkCount,
                        existing.NamesStaged + share.NamesStaged, existing.Owner);
                else
                    hardLinks[key] = (share.Bytes, share.LinkCount, share.NamesStaged, item.Id);
            }
        }

        foreach (var (_, entry) in hardLinks)
        {
            if (entry.NamesStaged >= entry.LinkCount) perItem[entry.Owner] += entry.Bytes;
            else heldByUnqueued += entry.Bytes;
        }
        foreach (var (_, entry) in hinted)
        {
            if (entry.CopyCount > 0 && entry.Staged >= entry.CopyCount) perItem[entry.Owner] += entry.FileSize;
            else heldByUnqueued += entry.FileSize;
        }

        return new ReclaimEstimate
        {
            Bytes = perItem.Values.Sum(),
            HeldByUnqueuedCopies = heldByUnqueued,
            SharedUnattributed = sharedUnattributed,
            IsLowerBound = isLowerBound,
            PerItem = perItem,
            IsCalculating = isCalculating,
        };
    }

    /// <summary>Items whose path lies inside another queued item's folder.</summary>
    internal static HashSet<Guid> CoveredItemIds(IReadOnlyList<StagedItem> items)
    {
        var folders = items
            .Select(i => i.Path.TrimEnd('\\', '/') + '\\')
            .ToArray();
        var covered = new HashSet<Guid>();
        for (int i = 0; i < items.Count; i++)
        {
            for (int j = 0; j < folders.Length; j++)
            {
                if (i != j && items[i].Path.StartsWith(folders[j], StringComparison.OrdinalIgnoreCase))
                {
                    covered.Add(items[i].Id);
                    break;
                }
            }
        }
        return covered;
    }

    /// <summary>
    /// Executes the staged cleanup: moves every item to the Recycle Bin.
    /// Folders go first; an item inside a folder that moved successfully
    /// went with it, so it is reported as moved-with-folder rather than
    /// retried and failed. The report carries the freed figure recomputed
    /// over what actually moved, so a partial failure never claims bytes
    /// still on disk. Items that failed stay staged for retry.
    /// </summary>
    public CommitReport Commit()
    {
        // The receipt must be computed from real measurements, and a moved
        // item can no longer be measured — so finish measuring first.
        WaitForMeasurements().Wait();
        StagedItem[] snapshot;
        lock (_gate) snapshot = _items.ToArray();

        // Folders first: path depth ascending, ordinal within a level — a
        // parent always precedes everything inside it.
        var ordered = snapshot
            .OrderBy(i => i.Path.Count(c => c is '\\' or '/'))
            .ThenBy(i => i.Path, StringComparer.OrdinalIgnoreCase)
            .ToList();
        var moved = new List<string>();
        var outcomes = new List<(StagedItem Item, Exception? Error, bool WithFolder)>();
        foreach (var item in ordered)
        {
            if (moved.Any(m => item.Path.StartsWith(
                    m.EndsWith('\\') ? m : m + '\\', StringComparison.OrdinalIgnoreCase)))
            {
                outcomes.Add((item, null, true));
                continue;
            }
            var error = Shell32.RecycleItem(item.Path);
            if (error is null) moved.Add(item.Path);
            outcomes.Add((item, error, false));
        }

        // Recompute the freed figure over what actually moved — a partial
        // failure never claims bytes still on disk.
        var succeeded = outcomes.Where(o => o.Error is null).Select(o => o.Item).ToList();
        var freed = Estimate(succeeded);
        var entries = outcomes.Select(o => new CommitEntry(
            o.Item, o.Error, o.WithFolder,
            o.Error is null ? freed.PerItem.GetValueOrDefault(o.Item.Id) : 0))
            .ToList();

        lock (_gate)
        {
            var failedIds = outcomes.Where(o => o.Error is not null).Select(o => o.Item.Id).ToHashSet();
            _items.RemoveAll(i => !failedIds.Contains(i.Id));
        }
        var report = new CommitReport(entries, freed.Bytes, freed.IsLowerBound);
        SaveCleanupRecord(report);
        return report;
    }

    /// <summary>
    /// The last commit's bin locations, persisted for Put Back (WIN-012).
    /// Only top-level moved items are recorded — an item recycled inside
    /// its folder comes back with the folder.
    /// </summary>
    private static void SaveCleanupRecord(CommitReport report)
    {
        try
        {
            var items = new List<CleanupRecord.Item>();
            foreach (var entry in report.Entries)
            {
                if (entry.Error is not null || entry.MovedWithFolder) continue;
                // The bin path is found by the $I metadata's recorded
                // original path — same drive as the item lived on.
                var resolved = RecycleBinStore.Resolve(entry.Item.Path);
                if (resolved is not null)
                    items.Add(new CleanupRecord.Item(entry.Item.Path, resolved.DataPath, entry.FreedBytes));
            }
            new CleanupRecord(DateTimeOffset.Now, items).Save();
        }
        catch { /* a failed receipt write never fails the commit */ }
    }
}
