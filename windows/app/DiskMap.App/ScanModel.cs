using System.Collections.ObjectModel;
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

    private ScanModel() { }

    private FileTree? _tree;
    public FileTree? Tree { get => _tree; private set { if (Set(ref _tree, value)) Changed(); } }

    private long[] _totals = [];
    public long[] Totals { get => _totals; private set { if (Set(ref _totals, value)) Changed(); } }

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

    private int _scanProgress;
    public int ScanProgress { get => _scanProgress; private set => Set(ref _scanProgress, value); }

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

    /// <summary>Capacity of the scanned volume — the sidebar drive card.</summary>
    private VolumeInfo? _volume;
    public VolumeInfo? Volume { get => _volume; private set { if (Set(ref _volume, value)) Changed(); } }

    /// <summary>Which chart mode the Visualize page shows.</summary>
    private string _visualizeMode = "Treemap";
    public string VisualizeMode { get => _visualizeMode; set { if (Set(ref _visualizeMode, value)) Changed(); } }

    /// <summary>The top-bar search box's committed query.</summary>
    private string _searchQuery = "";
    public string SearchQuery { get => _searchQuery; set { if (Set(ref _searchQuery, value)) Changed(); } }

    private List<DuplicateGroup> _duplicates = [];
    public List<DuplicateGroup> Duplicates { get => _duplicates; set { if (Set(ref _duplicates, value)) Changed(); } }

    /// <summary>Quick-wins hits, built once per scan (sidebar pages share it).</summary>
    private List<QuickWins.Hit>? _quickWins;
    public List<QuickWins.Hit>? QuickWins { get => _quickWins; set { if (Set(ref _quickWins, value)) Changed(); } }

    public CleanupQueue Cleanup { get; } = new();

    public ObservableCollection<CleanupQueue.StagedItem> StagedItems { get; } = [];

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
        if (_tree is not { } tree) return;
        var basis = _sizeBasis;
        var totals = await Task.Run(() => tree.RollUpSizes(basis));
        // A newer toggle or scan may have landed while this one ran.
        if (ReferenceEquals(tree, _tree) && basis == _sizeBasis) Totals = totals;
    }

    public async Task ScanAsync(string path)
    {
        if (IsScanning) return;
        IsScanning = true;
        ScanProgress = 0;
        try
        {
            var progress = new Progress<int>(i => ScanProgress = i);
            var basis = _sizeBasis;
            var (result, totals, counts, quickWins) = await Task.Run(async () =>
            {
                var scanned = await _engine.ScanAsync(path, progress);
                return (scanned,
                        scanned.Tree.RollUpSizes(basis),
                        scanned.Tree.RollUpCounts(),
                        Core.QuickWins.Find(scanned.Tree, path, Core.QuickWins.BundledPatterns()));
            });
            ItemCount = result.ItemCount;
            Elapsed = result.ElapsedSeconds;
            NotDownloaded = result.NotDownloadedCount;
            Backend = result.Backend;
            FallbackReason = result.FallbackReason;
            Duplicates = [];
            QuickWins = quickWins;
            // Totals before Tree: a view refreshed by the Tree change must
            // never pair the new tree with the old totals.
            _totals = totals;
            _counts = counts;
            _zoomedNode = 0;
            _selectedNode = -1;
            _zoomBack.Clear();
            _zoomForward.Clear();
            RootPath = path;
            Volume = VolumeStats.Of(path);
            Tree = result.Tree;
            if (basis != _sizeBasis) await RerollAsync();
        }
        finally
        {
            IsScanning = false;
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
        var (totals, counts, quickWins) = await Task.Run(() =>
            (snapshot.Tree.RollUpSizes(basis),
             snapshot.Tree.RollUpCounts(),
             Core.QuickWins.Find(snapshot.Tree, snapshot.RootPath, Core.QuickWins.BundledPatterns())));
        ItemCount = snapshot.Tree.Count;
        Elapsed = 0;
        NotDownloaded = 0;
        Backend = "snapshot";
        FallbackReason = null;
        Duplicates = [];
        QuickWins = quickWins;
        _totals = totals;
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

    public bool Stage(int nodeId, string reason, string? group = null, int groupCount = 1)
    {
        if (Tree is null || nodeId < 0 || nodeId >= Tree.Count) return false;
        string path = PathOf(nodeId);
        long size = nodeId < _totals.Length ? _totals[nodeId] : Tree.LogicalSize[nodeId];
        bool ok = Cleanup.Stage(path, size, reason, group, groupCount);
        if (ok) RefreshStaged();
        return ok;
    }

    /// <summary>Stage a raw path (leftovers, staged folders).</summary>
    public bool StagePath(string path, long size, string reason)
    {
        bool ok = Cleanup.Stage(path, size, reason);
        if (ok) RefreshStaged();
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
        StagedChanged?.Invoke(this, EventArgs.Empty);
    }
}
