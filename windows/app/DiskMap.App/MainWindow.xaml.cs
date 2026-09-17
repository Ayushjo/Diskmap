using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using DiskMap.App.Pages;
using DiskMap.Core;

namespace DiskMap.App;

public partial class MainWindow : Window
{
    private readonly ScanModel _model = ScanModel.Shared;
    private readonly Dictionary<string, Func<UserControl>> _pageFactories;

    public MainWindow()
    {
        InitializeComponent();

        _pageFactories = new Dictionary<string, Func<UserControl>>(StringComparer.Ordinal)
        {
            ["Map"] = () => new TreemapPage(),
            ["Top Sizes"] = () => new TopSizesPage(),
            ["Folders"] = () => new FoldersPage(),
            ["Age Map"] = () => new AgeMapPage(),
            ["Sunburst"] = () => new SunburstPage(),
            ["Flame"] = () => new FlamePage(),
            ["Bubbles"] = () => new BubblesPage(),
            ["Mind Map"] = () => new MindMapPage(),
            ["Snapshots"] = () => new SnapshotsPage(),
            ["Duplicates"] = () => new DuplicatesPage(),
            ["Quick Wins"] = () => new QuickWinsPage(),
            ["Apps"] = () => new AppsPage(),
            ["Cleanup"] = () => new CleanupQueuePage(),
        };
        var glyphs = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["Map"] = "▦", ["Top Sizes"] = "≡", ["Folders"] = "▤",
            ["Age Map"] = "◷", ["Sunburst"] = "◐", ["Flame"] = "▲",
            ["Bubbles"] = "●", ["Mind Map"] = "◈", ["Snapshots"] = "◫",
            ["Duplicates"] = "⧉", ["Quick Wins"] = "⚡", ["Apps"] = "▣",
            ["Cleanup"] = "⌫",
        };
        foreach (var name in _pageFactories.Keys)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            row.Children.Add(new TextBlock
            {
                Text = glyphs.GetValueOrDefault(name, "▪"),
                Width = 22,
                Foreground = System.Windows.Media.Brushes.Gray,
            });
            row.Children.Add(new TextBlock { Text = name });
            NavList.Items.Add(new ListBoxItem { Content = row, Tag = name });
        }
        NavList.SelectionChanged += OnNavChanged;
        NavList.SelectedIndex = 0;

        ScanButton.Click += async (_, _) => await PickAndScan();
        BasisToggle.SelectionChanged += (_, _) =>
            _model.SizeBasis = BasisToggle.SelectedIndex == 0 ? SizeBasis.Allocated : SizeBasis.Logical;
        ResetZoom.Click += (_, _) => _model.DrillToAncestor(0);
        _model.StateChanged += (_, _) => Dispatcher.InvokeAsync(RefreshChrome);
        _model.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(ScanModel.ScanProgress) or nameof(ScanModel.IsScanning))
                Dispatcher.InvokeAsync(RefreshChrome);
        };
        Loaded += (_, _) => RefreshChrome();
    }

    private void OnNavChanged(object sender, SelectionChangedEventArgs e)
    {
        if (NavList.SelectedItem is ListBoxItem { Tag: string name }
            && _pageFactories.TryGetValue(name, out var factory))
        {
            PageHost.Content = factory();
        }
    }

    private async Task PickAndScan()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        var path = FolderPicker.Pick(hwnd);
        if (path is null) return;
        try
        {
            ScanStatus.Text = $"Scanning {path}…";
            await _model.ScanAsync(path);
        }
        catch (Exception ex)
        {
            ScanStatus.Text = $"Scan failed: {ex.Message}";
        }
    }

    private void RefreshChrome()
    {
        // Breadcrumb bar — each crumb clickable, mirrors the macOS path bar.
        Breadcrumbs.Children.Clear();
        var tree = _model.Tree;
        if (tree is null || _model.RootPath is null)
        {
            ScanStatus.Text = _model.IsScanning ? $"Scanning… {_model.ScanProgress} items" : "Pick a folder to scan.";
            StatusBar.Text = "";
            return;
        }
        var chain = _model.Breadcrumbs();
        for (int i = 0; i < chain.Count; i++)
        {
            int id = chain[i];
            var crumb = new Button
            {
                Content = tree.NameOf(id),
                Padding = new Thickness(6, 2, 6, 2),
                Margin = new Thickness(0, 0, 2, 0),
                FontWeight = id == _model.ZoomedNode ? FontWeights.SemiBold : FontWeights.Normal,
            };
            crumb.Click += (_, _) => _model.DrillToAncestor(id);
            Breadcrumbs.Children.Add(crumb);
            if (i < chain.Count - 1)
                Breadcrumbs.Children.Add(new TextBlock
                {
                    Text = "›",
                    VerticalAlignment = VerticalAlignment.Center,
                    Foreground = (System.Windows.Media.Brush)FindResource("AppSubtle"),
                });
        }
        if (_model.ZoomedNode < _model.Totals.Length)
        {
            Breadcrumbs.Children.Add(new TextBlock
            {
                Text = $"  {ByteFormat.Format(_model.Totals[_model.ZoomedNode])}",
                VerticalAlignment = VerticalAlignment.Center,
                FontWeight = FontWeights.SemiBold,
            });
        }
        string scanned = $"Scanned {_model.ItemCount:N0} items in {_model.Elapsed:0.0}s via {_model.Backend}";
        if (_model.NotDownloaded > 0) scanned += $" · {_model.NotDownloaded} in cloud only";
        ScanStatus.Text = scanned;
        StatusBar.Text = $"{_model.RootPath} — {ByteFormat.Format(_model.Totals[0])} total";
    }
}
