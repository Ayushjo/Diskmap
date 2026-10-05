using System.Collections.ObjectModel;
using System.IO;
using DiskMap.Core;

namespace DiskMap.App;

/// <summary>
/// App-wide scan state — the Windows counterpart of the macOS app's
/// shared ScanModel. One scan feeds every page; totals and item counts
/// are rolled up once and reused. Views read Tree/Totals directly and
/// subscribe to changes.
///
/// Anything proportional to the tree (the scan itself, rollups) runs off
/// the UI thread; only the finished values are published here.
/// </summary>
public sealed class ScanModel : ViewModelBase
{
    public static ScanModel Shared { get; } = new();

    private readonly ScanEngine _engine = new();

    private ScanModel()
    {
        // A landed measurement changes the staged figures; refresh the
        // badge + any open page on the UI thread.
        Cleanup.Measured += (_, _) =>
            System.Windows.Application.Current?.Dispatcher.Invoke(RefreshStaged);
    }

    private FileTree? _tree;
    public FileTree? Tree { get => _tree; private set { if (Set(ref _tree, value)) Changed(); } }

    private long[] _totals = [];
    public long[] Totals { get => _totals; private set { if (Set(ref _totals, value)) Changed(); } }

    /// <summary>Both rollup bases, kept so the size toggle and the AnalysisSnapshot don't re-walk.</summary>
    private long[] _totalsLogical = [];
    private long[] _totalsAllocated = [];

    /// <summary>Both rollups for one node — the inspector's logical-vs-on-disk line.</summary>
    public (long Logical, long Allocated)? DualTotals(int id) =>
        Tree is { Count: > 0 } t && _totalsLogical.Length == t.Count && _totalsAllocated.Length == t.Count
            && id >= 0 && id < t.Count
            ? (_totalsLogical[id], _totalsAllocated[id]) : null;

    /// <summary>The post-scan summary Overview reads (volume reconciliation, categories, top hits).</summary>
    private AnalysisSnapshot? _snapshot;
    public AnalysisSnapshot? Snapshot { get => _snapshot; private set { if (Set(ref _snapshot, value)) Changed(); } }

    /// <summary>Per-root scan history (one JSON file per root under %LOCALAPPDATA%\DiskMap\History).</summary>
    private readonly StorageHistory _history = new();

    /// <summary>"What grew this week" for the current root, if history allows.</summary>
    public StorageHistory.Comparison? HistoryComparison
    {
        get
        {
            if (RootPath is not { } root || _totalsAllocated.Length == 0) return null;
            var entries = _history.Entries(root);
            var latest = entries.LastOrDefault();
            if (latest is null) return null;
            return StorageHistory.Compare(entries, latest);
        }
    }

    /// <summary>(files, folders) descendant counts per node — "N items" labels.</summary>
    private (int[] Files, int[] Folders) _counts = ([], []);
    public (int[] Files, int[] Folders) Counts => _counts;

    private string? _rootPath;
    public string? RootPath { get => _rootPath; private set { if (Set(ref _rootPath, value)) Changed(); } }

    private int _zoomedNode = 0;
    public int ZoomedNode { get => _zoomedNode; set { if (Set(ref _zoomedNode, value)) Changed(); } }

    /// <summary>
    /// The item the inspector shows — set by row clicks and tile taps.
    /// Falls back to the zoomed folder when nothing is selected.
    /// </summary>
    private int _selectedNode = -1;
    public int SelectedNode
    {
        get => _selectedNode;
        set { if (Set(ref _selectedNode, value)) Changed(); }
    }

    /// <summary>Inspector target: the selection, else the zoomed folder.</summary>
    public int InspectedNode =>
        _selectedNode >= 0 && _selectedNode < (Tree?.Count ?? 0) ? _selectedNode : _zoomedNode;

    private SizeBasis _sizeBasis = SizeBasis.Allocated;
    public SizeBasis SizeBasis
    {
        get => _sizeBasis;
        set { if (Set(ref _sizeBasis, value)) _ = RerollAsync(); }
    }

    private bool _isScanning;
    public bool IsScanning { get => _isScanning; private set => Set(ref _isScanning, value); }

    /// <summary>"walking" while directories list, "summarizing" during the rollup pass.</summary>
    private string _scanPhase = "walking";
    public string ScanPhase { get => _scanPhase; private set => Set(ref _scanPhase, value); }

    private int _scanProgress;
    public int ScanProgress { get => _scanProgress; private set => Set(ref _scanProgress, value); }

    /// <summary>Live scan telemetry — items/s, bytes found, top-level attribution.</summary>
    private ScanEngine.ScanProgress? _scanStats;
    public ScanEngine.ScanProgress? ScanStats { get => _scanStats; private set => Set(ref _scanStats, value); }

    private CancellationTokenSource? _scanCts;

    /// <summary>
    /// Cancels the in-flight scan. The last finished scan's tree stays —
    /// a cancelled walk never publishes a partial tree (PARITY WIN-004).
    /// </summary>
    public void CancelScan() => _scanCts?.Cancel();

    private int _itemCount;
    public int ItemCount { get => _itemCount; private set => Set(ref _itemCount, value); }

    private double _elapsed;
    public double Elapsed { get => _elapsed; private set => Set(ref _elapsed, value); }

    private int _notDownloaded;
    public int NotDownloaded { get => _notDownloaded; private set => Set(ref _notDownloaded, value); }

    private string _backend = "";
    public string Backend { get => _backend; private set => Set(ref _backend, value); }

    /// <summary>Why the fast MFT path was skipped ("needs administrator", …); null when it ran or wasn't wanted.</summary>
    private string? _fallbackReason;
    public string? FallbackReason { get => _fallbackReason; private set => Set(ref _fallbackReason, value); }

    /// <summary>
    /// Directories that refused to list in the last scan — their bytes are
    /// missing from every total above them, so the UI says so rather than
    /// silently under-reporting (PARITY WIN-003).
    /// </summary>
    private IReadOnlyList<int> _deniedDirectories = [];
    public IReadOnlyList<int> DeniedDirectories { get => _deniedDirectories; private set { if (Set(ref _deniedDirectories, value)) Changed(); } }

    /// <summary>Directories that failed to list for other reasons (raced deletes etc.) — counted, not listed.</summary>
    private int _failedDirectoryCount;
    public int FailedDirectoryCount { get => _failedDirectoryCount; private set => Set(ref _failedDirectoryCount, value); }

    /// <summary>Capacity of the scanned volume — the sidebar drive card.</summary>
    private VolumeInfo? _volume;
    public VolumeInfo? Volume { get => _volume; private set { if (Set(ref _volume, value)) Changed(); } }

    /// <summary>WIN-066: non-null when the opt-in ReFS block-clone pass ran on the last scan.</summary>
    public BlockClones.Report? CloneProfile { get; private set; }

    /// <summary>What clone dedup removed from the allocated totals, if the tree was profiled.</summary>
    public FileTree.SharingCorrection CloneCorrection =>
        Tree?.GetSharingCorrection() ?? FileTree.SharingCorrection.None;

    /// <summary>Which chart mode the Visualize page shows.</summary>
    private string _visualizeMode = "Treemap";
    public string VisualizeMode { get => _visualizeMode; set { if (Set(ref _visualizeMode, value)) Changed(); } }

    /// <summary>The top-bar search box's committed query.</summary>
    /// <summary>WIN-048: chart coloring — "type" (dominant file kind), "age" (forgotten-band), "folder" (per-sibling hue).</summary>
    private string _coloringMode = "type";
    public string ColoringMode { get => _coloringMode; set { if (Set(ref _coloringMode, value)) Changed(); } }

    /// <summary>WIN-048: slice-collapse threshold — the depth slider's value (fraction of the parent, default 0.5%).</summary>
    private double _chartDepth = ChartLayout.OtherFraction;
    public double ChartDepth { get => _chartDepth; set { if (Set(ref _chartDepth, value)) Changed(); } }

    private string _searchQuery = "";
    public string SearchQuery { get => _searchQuery; set { if (Set(ref _searchQuery, value)) Changed(); } }

    private List<DuplicateGroup> _duplicates = [];
    public List<DuplicateGroup> Duplicates { get => _duplicates; set { if (Set(ref _duplicates, value)) Changed(); } }

    /// <summary>True once the duplicate finder has run on this scan.</summary>
    private bool _duplicatesRan;

    /// <summary>
    /// Ids of files inside a duplicate group — null until a duplicate
    /// search actually ran, so queries can say "not searched yet" instead
    /// of matching nothing.
    /// </summary>
    public HashSet<int>? DuplicateFileIDs =>
        _duplicatesRan ? Duplicates.SelectMany(g => g.FileIDs).ToHashSet() : null;

    /// <summary>The duplicate finder completed (possibly finding nothing).</summary>
    public void MarkDuplicatesSearched() => _duplicatesRan = true;

    /// <summary>Quick-wins hits, built once per scan (sidebar pages share it).</summary>
    private List<QuickWins.Hit>? _quickWins;
    public List<QuickWins.Hit>? QuickWins { get => _quickWins; set { if (Set(ref _quickWins, value)) Changed(); } }

    // ---- WIN-052: chart multi-selection ----

    /// <summary>
    /// Ctrl+click toggles a node in this set; plain click selects the one
    /// (and clears this). Esc clears. Exposed as the shared chart-select
    /// set every chart control reads.
    /// </summary>
    public HashSet<int> MultiSelection { get; } = [];

    public void ToggleMulti(int nodeId)
    {
        if (!MultiSelection.Remove(nodeId)) MultiSelection.Add(nodeId);
        Changed();
    }

    public void ClearMulti()
    {
        if (MultiSelection.Count == 0) return;
        MultiSelection.Clear();
        Changed();
    }

    /// <summary>
    /// Bytes across the selection counting a folder and its contents once
    /// — a selected dir's selected descendants don't double up.
    /// </summary>
    public long MultiSelectionBytes()
    {
        if (Tree is null || MultiSelection.Count == 0) return 0;
        long bytes = 0;
        foreach (int id in MultiSelection)
        {
            bool covered = false;
            for (int p = Tree.Parent[id]; p > 0; p = Tree.Parent[p])
                if (MultiSelection.Contains(p)) { covered = true; break; }
            if (!covered && id < _totals.Length) bytes += _totals[id];
        }
        return bytes;
    }

    public CleanupQueue Cleanup { get; } = new();

    public ObservableCollection<CleanupQueue.StagedItem> StagedItems { get; } = [];

    /// <summary>Latest reclaim figure — recomputed by the queue's own measurements.</summary>
    private CleanupQueue.ReclaimEstimate _reclaimEstimate = CleanupQueue.ReclaimEstimate.Empty;
    public CleanupQueue.ReclaimEstimate ReclaimEstimate { get => _reclaimEstimate; private set => Set(ref _reclaimEstimate, value); }

    /// <summary>Pages re-render on this — tree, totals, zoom, basis all funnel through it.</summary>
    public event EventHandler? StateChanged;
    private void Changed() => StateChanged?.Invoke(this, EventArgs.Empty);

    /// <summary>Raised by pages/inspector to switch the main navigation (e.g. "View in File Browser").</summary>
    public event Action<string>? PageRequested;
    public void ShowPage(string name) => PageRequested?.Invoke(name);

    /// <summary>Raised when a page wants a folder picked (it can't show the dialog itself).</summary>
    public event Action? ScanRequested;
    public void RequestScan() => ScanRequested?.Invoke();

    /// <summary>Drill + navigate to Visualize, used by "Visualize this folder".</summary>
    public void Visualize(int nodeId)
    {
        DrillTo(nodeId);
        VisualizeMode = "Treemap";
        ShowPage("Visualize");
    }

    private async Task RerollAsync()
    {
        if (_tree is not { } tree || _rootPath is not { } root) return;
        var basis = _sizeBasis;
        var snapshot = await Task.Run(() =>
        {
            var totals = basis == SizeBasis.Logical ? _totalsLogical : _totalsAllocated;
            return AnalysisSnapshot.Build(tree, root, _totalsLogical, _totalsAllocated, basis, QuickWins);
        });
        // A newer toggle or scan may have landed while this one ran.
        if (ReferenceEquals(tree, _tree) && basis == _sizeBasis)
        {
            Totals = basis == SizeBasis.Logical ? _totalsLogical : _totalsAllocated;
            Snapshot = snapshot;
        }
    }

    public async Task ScanAsync(string path)
    {
        if (IsScanning) return;
        IsScanning = true;
        ScanPhase = "walking";
        ScanProgress = 0;
        ScanStats = null;
        using var cts = _scanCts = new CancellationTokenSource();
        try
        {
            var progress = new Progress<ScanEngine.ScanProgress>(p =>
            {
                ScanProgress = p.Items;
                ScanStats = p;
            });
            var basis = _sizeBasis;
            var settings = AppSettings.Load();
            var scanned = await Task.Run(
                () => _engine.ScanAsync(path, progress, cts.Token, settings.CloneAccounting),
                cts.Token);
            ScanPhase = "summarizing";
            var (logical, allocated, counts, quickWins, snapshot) = await Task.Run(() =>
            {
                var l = scanned.Tree.RollUpSizes(SizeBasis.Logical);
                var a = scanned.Tree.RollUpSizes(SizeBasis.Allocated);
                var c = scanned.Tree.RollUpCounts();
                var qw = Core.QuickWins.Find(scanned.Tree, path, Core.QuickWins.BundledPatterns());
                var snap = AnalysisSnapshot.Build(scanned.Tree, path, l, a, basis, qw);
                return (l, a, c, qw, snap);
            }, cts.Token);
            cts.Token.ThrowIfCancellationRequested();
            // History record — one JSON line per scan, feeds "what grew".
            var volume = VolumeStats.Of(path);
            if (settings.KeepHistory)
            {
                var folders = StorageHistory.Folders(scanned.Tree, allocated);
                _history.Record(new StorageHistory.Entry(
                    DateTimeOffset.Now,
                    volume?.FreeBytes ?? 0,
                    volume?.TotalBytes ?? 0,
                    allocated.Length > 0 ? allocated[0] : 0,
                    scanned.FailedDirectoryCount,
                    scanned.Tree.Sharing.IsEmpty
                        ? StorageHistory.Entry.SharingModeHardLinkDedup
                        : StorageHistory.Entry.SharingModeBlockCloneDedup,
                    folders), path);
            }
            ItemCount = scanned.ItemCount;
            Elapsed = scanned.ElapsedSeconds;
            NotDownloaded = scanned.NotDownloadedCount;
            Backend = scanned.Backend;
            FallbackReason = scanned.FallbackReason;
            DeniedDirectories = scanned.DeniedDirectoryIds;
            FailedDirectoryCount = scanned.FailedDirectoryCount;
            Duplicates = [];
            _duplicatesRan = false;
            QuickWins = quickWins;
            Snapshot = snapshot;
            // Totals before Tree: a view refreshed by the Tree change must
            // never pair the new tree with the old totals.
            _totalsLogical = logical;
            _totalsAllocated = allocated;
            _totals = basis == SizeBasis.Logical ? logical : allocated;
            _counts = counts;
            _zoomedNode = 0;
            _selectedNode = -1;
            _zoomBack.Clear();
            _zoomForward.Clear();
            CloneProfile = scanned.CloneProfile;
            RootPath = path;
            Volume = VolumeStats.Of(path);
            Tree = scanned.Tree;
            // WIN-013: let staging measure from this tree when the journal
            // proves a staged folder's subtree is unchanged since the scan.
            Cleanup.SetScanContext(scanned.Tree, path, scanned.ScanMarker,
                scanned.DeniedDirectoryIds);
            if (basis != _sizeBasis) await RerollAsync();
        }
        catch (OperationCanceledException)
        {
            // Keep the previous scan — a cancelled walk publishes nothing.
        }
        finally
        {
            IsScanning = false;
            ScanPhase = "walking";
            _scanCts = null;
        }
    }

    /// <summary>Rescan the current root — the top bar's button.</summary>
    public async Task RescanAsync()
    {
        if (RootPath is { } path) await ScanAsync(path);
    }

    /// <summary>Adopt a loaded snapshot as the current scan — no rescan.</summary>
    public async Task LoadSnapshot(DiskSnapshot snapshot)
    {
        var basis = _sizeBasis;
        var (logical, allocated, counts, quickWins, snap) = await Task.Run(() =>
        {
            var l = snapshot.Tree.RollUpSizes(SizeBasis.Logical);
            var a = snapshot.Tree.RollUpSizes(SizeBasis.Allocated);
            var c = snapshot.Tree.RollUpCounts();
            var qw = Core.QuickWins.Find(snapshot.Tree, snapshot.RootPath, Core.QuickWins.BundledPatterns());
            var s = AnalysisSnapshot.Build(snapshot.Tree, snapshot.RootPath, l, a, basis, qw);
            return (l, a, c, qw, s);
        });
        ItemCount = snapshot.Tree.Count;
        Elapsed = 0;
        NotDownloaded = 0;
        Backend = "snapshot";
        FallbackReason = null;
        DeniedDirectories = [];
        FailedDirectoryCount = 0;
        CloneProfile = null;
        Duplicates = [];
        _duplicatesRan = false;
        QuickWins = quickWins;
        Snapshot = snap;
        _totalsLogical = logical;
        _totalsAllocated = allocated;
        _totals = basis == SizeBasis.Logical ? logical : allocated;
        _counts = counts;
        _zoomedNode = 0;
        _selectedNode = -1;
        _zoomBack.Clear();
        _zoomForward.Clear();
        RootPath = snapshot.RootPath;
        Volume = VolumeStats.Of(snapshot.RootPath);
        Tree = snapshot.Tree;
    }

    // Zoom navigation history for the breadcrumb ‹ › buttons.
    private readonly List<int> _zoomBack = [];
    private readonly List<int> _zoomForward = [];

    public void DrillTo(int nodeId)
    {
        if (Tree is not null && nodeId >= 0 && nodeId < Tree.Count && Tree.IsDirectory[nodeId]
            && nodeId != ZoomedNode)
        {
            _zoomBack.Add(ZoomedNode);
            _zoomForward.Clear();
            ZoomedNode = nodeId;
        }
    }

    public void DrillToAncestor(int nodeId)
    {
        if (Tree is not null && nodeId >= 0 && nodeId < Tree.Count)
            ZoomedNode = nodeId;
    }

    public bool CanGoBack => _zoomBack.Count > 0;
    public bool CanGoForward => _zoomForward.Count > 0;

    public void GoBack()
    {
        if (_zoomBack.Count == 0) return;
        _zoomForward.Add(ZoomedNode);
        ZoomedNode = _zoomBack[^1];
        _zoomBack.RemoveAt(_zoomBack.Count - 1);
    }

    public void GoForward()
    {
        if (_zoomForward.Count == 0) return;
        _zoomBack.Add(ZoomedNode);
        ZoomedNode = _zoomForward[^1];
        _zoomForward.RemoveAt(_zoomForward.Count - 1);
    }

    public void Select(int nodeId)
    {
        if (Tree is not null && nodeId >= 0 && nodeId < Tree.Count)
            SelectedNode = nodeId;
    }

    public List<int> Breadcrumbs() =>
        Tree is null ? [] : Tree.AncestorIds(ZoomedNode);

    public string PathOf(int nodeId) =>
        Tree is null || RootPath is null ? "" : Tree.PathOf(nodeId, RootPath);

    /// <summary>"~"-style display path: the scanned root shown as its name.</summary>
    public string DisplayPath(int nodeId)
    {
        string path = PathOf(nodeId);
        if (RootPath is { } root && path.StartsWith(root, StringComparison.OrdinalIgnoreCase))
        {
            string rest = path[root.Length..].TrimStart('\\', '/');
            string name = Tree!.NameOf(0);
            return rest.Length == 0 ? name : $"{name}/{rest}";
        }
        return path;
    }

    /// <summary>Transient confirmations — stage/commit/put-back (WIN-063).</summary>
    public event Action<string>? ToastRequested;
    public void Toast(string text) => ToastRequested?.Invoke(text);
    public void ToastAdded(int count) => Toast(count == 1
        ? "Added to Cleanup — Ctrl+Shift+Delete to review"
        : $"Added {count:N0} items to Cleanup — Ctrl+Shift+Delete to review");

    /// <summary>What this node is and what removing it means (WSL disk, app, cache…).</summary>
    public StorageVerdict VerdictOf(int nodeId) =>
        Tree is null || nodeId < 0 || nodeId >= Tree.Count
            ? new StorageVerdict(StorageClassifier.Other, CleanupAdvice.Fine)
            : StorageClassifier.Classify(PathOf(nodeId), Tree.IsDirectory[nodeId]);

    /// <summary>
    /// Asked before a single risky item (a WSL distro, Docker's disk, an
    /// installed app…) is staged; true = stage anyway. Set by the window —
    /// null means refuse, the safe default.
    /// </summary>
    public Func<string, StorageVerdict, bool>? ConfirmRisky { get; set; }

    /// <summary>
    /// Stages one node. Windows-managed items are refused with the right
    /// alternative; risky ones ask first when <paramref name="notify"/> is
    /// set (an interactive single add) and are refused in silent bulk use —
    /// <see cref="StageMany"/> reports those.
    /// </summary>
    public bool Stage(int nodeId, string reason, string? group = null, int groupCount = 1,
        bool notify = true)
    {
        if (Tree is null || nodeId < 0 || nodeId >= Tree.Count) return false;
        var verdict = VerdictOf(nodeId);
        if (verdict.Advice == CleanupAdvice.Never)
        {
            if (notify)
                Toast($"{Tree.NameOf(nodeId)} is managed by Windows — {verdict.Instead ?? verdict.Note ?? "it can't be cleaned up here"}");
            return false;
        }
        if (verdict.Advice == CleanupAdvice.Warn
            && !(notify && ConfirmRisky?.Invoke(Tree.NameOf(nodeId), verdict) == true))
            return false;
        string path = PathOf(nodeId);
        long size = nodeId < _totals.Length ? _totals[nodeId] : Tree.LogicalSize[nodeId];
        bool ok = Cleanup.Stage(path, size, reason, group, groupCount);
        if (ok)
        {
            RefreshStaged();
            if (notify) ToastAdded(1);
        }
        return ok;
    }

    /// <summary>
    /// The one bulk-add path behind every "Add Selected to Cleanup": stages
    /// what's safe to stage, skips risky and Windows-managed items (they
    /// need a deliberate single add, with the warning), and says so in one
    /// toast. Returns how many were added.
    /// </summary>
    public int StageMany(IEnumerable<int> nodeIds, string reason)
    {
        if (Tree is null) return 0;
        int added = 0, already = 0;
        var skipped = new List<string>();
        foreach (int id in nodeIds)
        {
            if (id < 0 || id >= Tree.Count) continue;
            var advice = VerdictOf(id).Advice;
            if (advice is CleanupAdvice.Warn or CleanupAdvice.Never) { skipped.Add(Tree.NameOf(id)); continue; }
            if (Stage(id, reason, notify: false)) added++;
            else already++;
        }
        string addedText = added == 1 ? "Added 1 item to Cleanup" : $"Added {added:N0} items to Cleanup";
        if (skipped.Count > 0)
        {
            string names = string.Join(", ", skipped.Take(2)) + (skipped.Count > 2 ? $" +{skipped.Count - 2}" : "");
            Toast($"{(added > 0 ? addedText + " · " : "")}skipped {skipped.Count} risky item{(skipped.Count == 1 ? "" : "s")} ({names}) — add those one at a time to see the warning");
        }
        else if (added > 0)
        {
            ToastAdded(added);
        }
        else if (already > 0)
        {
            Toast("Already in Cleanup");
        }
        return added;
    }

    /// <summary>
    /// Shows the bulk confirmation (every item by full path); true = go.
    /// Set by the window; null means refuse — the safe default.
    /// </summary>
    public Func<string, string, IReadOnlyList<Dialogs.ConfirmItem>, string?, bool>? ConfirmBulk { get; set; }

    /// <summary>
    /// <see cref="StageMany"/> behind a confirmation that lists exactly what
    /// will be added — folder by folder, with full paths and sizes.
    /// </summary>
    public int ConfirmStageMany(IEnumerable<int> nodeIds, string reason, string title)
    {
        if (Tree is null) return 0;
        var ids = nodeIds.Distinct().Where(id => id >= 0 && id < Tree.Count).ToList();
        if (ids.Count == 0) return 0;
        var safe = ids.Where(id => VerdictOf(id).Advice is not (CleanupAdvice.Warn or CleanupAdvice.Never)).ToList();
        int risky = ids.Count - safe.Count;
        var items = safe.Select(id => new Dialogs.ConfirmItem(Tree.NameOf(id), PathOf(id),
            id < _totals.Length ? _totals[id] : 0)).ToList();
        if (items.Count > 0)
        {
            string? footnote = risky > 0
                ? $"{risky} risky item{(risky == 1 ? "" : "s")} (WSL/Docker disks, apps, browser data…) won't be added — add those one at a time to see the warning."
                : null;
            bool ok = ConfirmBulk?.Invoke(title,
                "These will be added to Cleanup. Nothing is deleted yet — you review the list on the Cleanup page and confirm again before anything moves to the Recycle Bin.",
                items, footnote) == true;
            if (!ok) return 0;
        }
        return StageMany(ids, reason);
    }

    /// <summary>Stage a raw path (leftovers, staged folders).</summary>
    public bool StagePath(string path, long size, string reason, bool notify = true)
    {
        bool ok = Cleanup.Stage(path, size, reason);
        if (ok)
        {
            RefreshStaged();
            if (notify) ToastAdded(1);
        }
        return ok;
    }

    public void Unstage(Guid id)
    {
        Cleanup.Unstage(id);
        RefreshStaged();
    }

    /// <summary>Fired when the staged set changes — chrome badges listen on this.</summary>
    public event EventHandler? StagedChanged;

    /// <summary>
    /// Staging touches only the queue, never the tree, so it doesn't raise
    /// StateChanged — that used to rebuild every page on every Stage click.
    /// Chrome that shows the staged count subscribes to StagedChanged.
    /// </summary>
    public void RefreshStaged()
    {
        StagedItems.Clear();
        foreach (var item in Cleanup.AllItems()) StagedItems.Add(item);
        ReclaimEstimate = Cleanup.Estimate();
        StagedChanged?.Invoke(this, EventArgs.Empty);
    }

}
