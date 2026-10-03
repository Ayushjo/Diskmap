using DiskMap.Core.Native;
using Microsoft.Win32.SafeHandles;

namespace DiskMap.Core;

/// <summary>
/// Incremental rescan (WIN-031): replay the USN journal since the
/// baseline's marker and apply just those records to the cached tree —
/// the Windows counterpart of the macOS FSEvents rescan (TASK-061).
///
/// A rescan is a three-part question: did the journal wrap, is the
/// change set sane, and do untouched folders still check out. Any "no"
/// returns null with a reason and the caller does a full walk instead —
/// the journal is an accelerator, never an authority.
///
/// Fallbacks: journal id changed (recreated), the window after the
/// marker was overwritten before we read it, more than <see cref=
/// "ChangeFlood"/> records, a baseline without file ids (walk backend),
/// or a spot-check disagreement. All are silent wins for correctness.
/// </summary>
internal static class IncrementalScan
{
    /// <summary>Beyond this many touched records a replay costs more than a walk.</summary>
    private const int ChangeFlood = 100_000;
    private const int SpotCheckFolders = 64;

    public static WalkResult? TryRescan(
        string root, IProgress<ScanEngine.ScanProgress>? progress,
        CancellationToken cancellationToken, out string? whyNot)
    {
        whyNot = "no baseline";
        var baseline = ScanCache.Load(root);
        if (baseline is null) return null;
        var baseTree = baseline.Snapshot.Tree;

        string? volumeRoot = Path.GetPathRoot(Path.GetFullPath(root));
        whyNot = "not a local drive";
        if (volumeRoot is null || volumeRoot.Length < 3 || volumeRoot[1] != ':') return null;
        string volumePath = @"\\?\" + char.ToUpperInvariant(volumeRoot[0]) + ":";

        whyNot = "needs administrator";
        if (!Win32.EnableBackupPrivileges()) return null;
        using var volume = MftScanner.OpenVolume(volumePath);
        if (volume.IsInvalid) return null;

        whyNot = "no USN journal";
        if (UsnJournal.Query(volume) is not { } current) return null;
        whyNot = "journal recreated";
        if (current.JournalId != baseline.Marker.JournalId) return null;

        whyNot = "not NTFS";
        if (!MftScanner.GetVolumeData(volume, out var data)) return null;
        int recordSize = (int)data.BytesPerFileRecordSegment;
        long clusterSize = data.BytesPerCluster;
        whyNot = "$MFT layout unreadable";
        var extents = MftScanner.ReadMftExtents(
            volume, recordSize, clusterSize, data.MftStartLcn, data.MftValidDataLength);
        if (extents is null) return null;

        whyNot = "journal unreadable";
        if (UsnJournal.ReadAll(volume, baseline.Marker, cancellationToken) is not { } changes)
            return null;
        whyNot = "journal wrapped";
        if (changes.Wrapped) return null;
        var changedFrns = changes.Entries.Select(e => e.Frn).ToHashSet();
        whyNot = "change flood";
        if (changedFrns.Count > ChangeFlood) return null;

        var started = System.Diagnostics.Stopwatch.StartNew();
        progress?.Report(new ScanEngine.ScanProgress(0, 0, 0,
            $"Applying {changedFrns.Count:N0} changes…", []));

        // frn → all baseline nodes (hard links share a frn).
        var nodesByFrn = new Dictionary<long, List<int>>();
        for (int i = 0; i < baseTree.Count; i++)
        {
            long frn = baseTree.FileId[i] & Win32.UsnRecordMask;
            if (frn == 0) continue;
            (nodesByFrn.TryGetValue(frn, out var l) ? l : nodesByFrn[frn] = []).Add(i);
        }
        long rootFrn = baseTree.FileId[0] & Win32.UsnRecordMask;

        // Re-read every touched record: parses live → its current state is
        // authoritative; a dead slot means delete. USN reasons only say
        // which FRNs to look at.
        var updates = new Dictionary<long, MftScanner.EntryInfo>();
        var removedFrns = new HashSet<long>();
        foreach (long frn in changedFrns)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (frn == rootFrn) continue;
            bool inTree = nodesByFrn.ContainsKey(frn);
            var rec = MftScanner.ReadRecordAt(volume, extents, recordSize, clusterSize, frn);
            if (rec is not null && MftScanner.ParseEntry(rec, recordSize, out var info))
            {
                updates[frn] = info;
                removedFrns.Remove(frn);
            }
            else if (inTree)
            {
                removedFrns.Add(frn);
            }
        }

        // Resolve "in the scanned subtree": a kept/new node's parent chain
        // must reach the root. Iterate updates until stable — a moved-in
        // dir makes its own parent resolvable, then its contents'.
        var resolved = new HashSet<long> { rootFrn };
        foreach (var frn in nodesByFrn.Keys)
            if (!removedFrns.Contains(frn)) resolved.Add(frn);
        bool grew;
        do
        {
            grew = false;
            foreach (var (frn, info) in updates)
            {
                if (resolved.Contains(frn) || !resolved.Contains(info.ParentFrn)) continue;
                resolved.Add(frn);
                grew = true;
            }
        } while (grew);
        // Anything resolved-away still updates; unresolved = out of scope.
        foreach (var frn in updates.Keys.ToList())
        {
            if (resolved.Contains(frn)) continue;
            updates.Remove(frn);
            if (nodesByFrn.ContainsKey(frn)) removedFrns.Add(frn);
        }

        // Child specs keyed by parent frn — rebuilt from baseline nodes
        // plus update entries; removal happens implicitly (removed nodes
        // never emit, and their parents' spec list is never visited).
        var childrenOf = new Dictionary<long, List<ChildSpec>>();
        // Names an existing baseline node already claimed for a file —
        // what remains of a file's name set is created/moved-in.
        var claimed = new Dictionary<long, HashSet<(long ParentFrn, string Name)>>();

        void Emit(long parentFrn, ChildSpec spec)
        {
            if (!resolved.Contains(parentFrn)) return;
            (childrenOf.TryGetValue(parentFrn, out var l) ? l : childrenOf[parentFrn] = []).Add(spec);
        }

        for (int i = 1; i < baseTree.Count; i++)
        {
            long frn = baseTree.FileId[i] & Win32.UsnRecordMask;
            if (frn == 0 || removedFrns.Contains(frn)) continue;
            int parentId = baseTree.Parent[i];
            long parentFrn = parentId >= 0 ? baseTree.FileId[parentId] : 0;
            string name = baseTree.NameOf(i);

            if (updates.TryGetValue(frn, out var info))
            {
                // This node survives only if its (parent, name) is still
                // one of the file's names — primary or a link.
                bool stillThere = (info.ParentFrn == parentFrn && info.Name == name)
                    || info.Links.Any(l => l.ParentFrn == parentFrn && l.Name == name);
                if (!stillThere) continue;   // this name is gone
                (claimed.TryGetValue(frn, out var c) ? c : claimed[frn] = [])
                    .Add((parentFrn, name));
                Emit(parentFrn, new ChildSpec(frn, i, name, baseTree.IsDirectory[i],
                    info.Logical, info.Allocated, info.Day, info.CreatedDay,
                    info.Attributes, ApplyDecision: true,
                    HardLinked: info.Links.Count > 0));
            }
            else
            {
                // Unchanged: copy the stored row verbatim — the baseline
                // already decided inclusion and flags for this node.
                Emit(parentFrn, new ChildSpec(frn, i, name, baseTree.IsDirectory[i],
                    baseTree.LogicalSize[i], baseTree.AllocatedSize[i],
                    baseTree.ModifiedDay[i], baseTree.CreatedDay[i],
                    StoredFlags: baseTree.Flags[i]));
            }
        }
        // The names a changed/created file still owns — whatever no
        // baseline node claimed is a create or move-in.
        foreach (var (frn, info) in updates)
        {
            claimed.TryGetValue(frn, out var taken);
            void EmitIfNew(long parentFrn, string name, bool isDir)
            {
                if (taken is not null && taken.Contains((parentFrn, name))) return;
                Emit(parentFrn, new ChildSpec(frn, -1, name, isDir,
                    info.Logical, info.Allocated, info.Day, info.CreatedDay,
                    info.Attributes, ApplyDecision: true,
                    HardLinked: info.Links.Count > 0));
            }
            EmitIfNew(info.ParentFrn, info.Name, info.IsDirectory);
            foreach (var (lp, ln) in info.Links)
                EmitIfNew(lp, ln, false);
        }

        var tree = new FileTree(Math.Max(baseTree.Count, 16));
        int rootId = tree.AddNode(Win32Scanner.RootName(root).AsSpan(), -1, true, 0, 0, 0);
        var queue = new Queue<(long Frn, int NewId)>();
        queue.Enqueue((rootFrn, rootId));
        int itemCount = 0, notDownloaded = 0;

        while (queue.TryDequeue(out var frame))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!childrenOf.TryGetValue(frame.Frn, out var specs)) continue;
            foreach (var spec in specs)
            {
                long logical = spec.Logical, allocated = spec.Allocated;
                byte flags = spec.StoredFlags;
                bool skipDescendants = false;
                if (spec.ApplyDecision)
                {
                    var decision = ScanEngine.DecideFromAttributes(
                        spec.Attributes
                            | (spec.IsDirectory ? Win32.FILE_ATTRIBUTE_DIRECTORY : 0),
                        logical, allocated);
                    if (!decision.Include) continue;
                    logical = decision.LogicalSize;
                    allocated = decision.AllocatedSize;
                    skipDescendants = decision.SkipDescendants;
                    if (decision.NotDownloaded) { flags |= NodeFlags.NotDownloaded; notDownloaded++; }
                }
                else if (spec.IsDirectory)
                {
                    skipDescendants =
                        (flags & NodeFlags.NotDownloaded) != 0;
                }
                if (spec.HardLinked) flags |= NodeFlags.HardLink;
                int id = tree.AddNode(spec.Name, frame.NewId, spec.IsDirectory,
                    logical, allocated, spec.Day,
                    flags: flags, createdDaysSinceEpoch: spec.CreatedDay, fileId: spec.Frn);
                itemCount++;
                if (spec.IsDirectory && !skipDescendants)
                    queue.Enqueue((spec.Frn, id));
            }
            if (itemCount % 65_536 == 0)
                progress?.Report(new ScanEngine.ScanProgress(itemCount, 0, 0, "Rebuilding tree…", []));
        }

        // Spot check: untouched folders must have the children the tree
        // claims — a miss means the journal lost something.
        var rng = new Random(0);
        var byDir = new Dictionary<long, HashSet<string>>(childrenOf.Count);
        foreach (var (parentFrn, specs) in childrenOf)
            byDir[parentFrn] = specs.Select(s => s.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);

        var candidates = nodesByFrn.Keys
            .Where(frn => !changedFrns.Contains(frn) && frn != rootFrn
                && resolved.Contains(frn))
            .OrderBy(_ => rng.Next())
            .Take(SpotCheckFolders)
            .ToList();
        foreach (var frn in candidates)
        {
            int node = nodesByFrn[frn][0];
            if (!baseTree.IsDirectory[node]) continue;
            string path = baseTree.PathOf(node, root);
            HashSet<string> onDisk;
            try
            {
                onDisk = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (string entry in Directory.EnumerateFileSystemEntries(path))
                {
                    // Filter like the scanner does: non-cloud reparse
                    // points never enter the tree, so they can't be
                    // evidence either.
                    var attrs = File.GetAttributes(entry);
                    if ((attrs & FileAttributes.ReparsePoint) != 0
                        && (attrs & (FileAttributes)0x00400000) == 0)   // RECALL_ON_OPEN
                        continue;
                    string? n = Path.GetFileName(entry);
                    if (n is not null) onDisk.Add(n);
                }
            }
            catch { continue; }   // a folder we can't list isn't evidence
            var expected = byDir.GetValueOrDefault(frn) ?? new HashSet<string>();
            if (!onDisk.SetEquals(expected))
            {
                whyNot = $"spot check disagreed at {path}";
                return null;
            }
        }

        progress?.Report(new ScanEngine.ScanProgress(itemCount, 0, 0, "", []));
        // The rescan's own tree + end-of-replay cursor are the next baseline.
        ScanCache.Save(root, tree, changes.Marker);
        return new WalkResult
        {
            Tree = tree,
            ItemCount = itemCount,
            NotDownloadedCount = notDownloaded,
            Backend = "usn",
            FallbackReason = null,
            ScanMarker = changes.Marker,
            // 0-denied can't be told from a journal replay — the baseline's
            // number would be a lie about the new tree; leave empty and let
            // the next full walk recount.
        };
    }

    /// <summary>
    /// One row of the rebuilt tree. Kept nodes carry StoredFlags verbatim
    /// (the baseline already decided them); fresh/moved nodes carry
    /// Attributes + ApplyDecision so the same include/flag rules re-run.
    /// </summary>
    private readonly record struct ChildSpec(
        long Frn, int OldNodeId, string Name, bool IsDirectory,
        long Logical, long Allocated, int Day, int CreatedDay,
        uint Attributes = 0, bool ApplyDecision = false,
        bool HardLinked = false, byte StoredFlags = 0);
}
