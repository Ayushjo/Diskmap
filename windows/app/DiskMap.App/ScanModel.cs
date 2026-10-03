using System.Collections.ObjectModel;
using DiskMap.Core;

namespace DiskMap.App;

/// <summary>
/// App-wide scan state — the Windows counterpart of the macOS app's
/// shared ScanModel. One scan feeds every page; totals are rolled up once
/// and reused. Views read Tree/Totals directly and subscribe to changes.
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

    private string? _rootPath;
    public string? RootPath { get => _rootPath; private set { if (Set(ref _rootPath, value)) Changed(); } }

    private int _zoomedNode = 0;
    public int ZoomedNode { get => _zoomedNode; set { if (Set(ref _zoomedNode, value)) Changed(); } }

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

    private List<DuplicateGroup> _duplicates = [];
    public List<DuplicateGroup> Duplicates { get => _duplicates; set { if (Set(ref _duplicates, value)) Changed(); } }

    public CleanupQueue Cleanup { get; } = new();

    public ObservableCollection<CleanupQueue.StagedItem> StagedItems { get; } = [];

    /// <summary>Pages re-render on this — tree, totals, zoom, basis all funnel through it.</summary>
    public event EventHandler? StateChanged;
    private void Changed() => StateChanged?.Invoke(this, EventArgs.Empty);

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
            var (result, totals) = await Task.Run(async () =>
            {
                var scanned = await _engine.ScanAsync(path, progress);
                return (scanned, scanned.Tree.RollUpSizes(basis));
            });
            ItemCount = result.ItemCount;
            Elapsed = result.ElapsedSeconds;
            NotDownloaded = result.NotDownloadedCount;
            Backend = result.Backend;
            FallbackReason = result.FallbackReason;
            Duplicates = [];
            // Totals before Tree: a view refreshed by the Tree change must
            // never pair the new tree with the old totals.
            _totals = totals;
            _zoomedNode = 0;
            RootPath = path;
            Tree = result.Tree;
            if (basis != _sizeBasis) await RerollAsync();
        }
        finally
        {
            IsScanning = false;
        }
    }

    public void DrillTo(int nodeId)
    {
        if (Tree is not null && nodeId >= 0 && nodeId < Tree.Count && Tree.IsDirectory[nodeId])
            ZoomedNode = nodeId;
    }

    public void DrillToAncestor(int nodeId)
    {
        if (Tree is not null && nodeId >= 0 && nodeId < Tree.Count)
            ZoomedNode = nodeId;
    }

    public List<int> Breadcrumbs() =>
        Tree is null ? [] : Tree.AncestorIds(ZoomedNode);

    public string PathOf(int nodeId) =>
        Tree is null || RootPath is null ? "" : Tree.PathOf(nodeId, RootPath);

    public bool Stage(int nodeId, string reason, string? group = null, int groupCount = 1)
    {
        if (Tree is null || nodeId < 0 || nodeId >= Tree.Count) return false;
        string path = PathOf(nodeId);
        long size = nodeId < _totals.Length ? _totals[nodeId] : Tree.LogicalSize[nodeId];
        bool ok = Cleanup.Stage(path, size, reason, group, groupCount);
        if (ok) RefreshStaged();
        return ok;
    }

    public void Unstage(Guid id)
    {
        Cleanup.Unstage(id);
        RefreshStaged();
    }

    /// <summary>
    /// Staging touches only the queue, never the tree, so it doesn't raise
    /// StateChanged — that used to rebuild every page on every Stage click.
    /// </summary>
    public void RefreshStaged()
    {
        StagedItems.Clear();
        foreach (var item in Cleanup.AllItems()) StagedItems.Add(item);
    }
}
