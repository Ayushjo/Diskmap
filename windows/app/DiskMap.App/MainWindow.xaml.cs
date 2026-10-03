using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;
using DiskMap.App.Pages;
using DiskMap.Core;

namespace DiskMap.App;

public partial class MainWindow : Window
{
    private readonly ScanModel _model = ScanModel.Shared;
    private readonly Dictionary<string, Func<UserControl>> _pageFactories = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Border> _navItems = new(StringComparer.Ordinal);
    // One instance per page for the session: a page keeps its state
    // (filters, results) and isn't rebuilt on every sidebar click.
    private readonly Dictionary<string, UserControl> _pages = new(StringComparer.Ordinal);
    private string _currentPage = "Overview";
    private TextBox? _searchInput;

    public MainWindow()
    {
        InitializeComponent();
        BuildNav();
        BuildTopBar();
        BuildLogo();
        InspectorHost.Content = new Controls.InspectorPanel();
        ModelEvents.WhileLoaded(this, RefreshDrive);
        _model.PageRequested += SelectPage;
        _model.ScanRequested += async () => await PickAndScan();
        _model.StagedChanged += (_, _) => RefreshCleanupBadge();
        SelectPage("Overview");
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.K && Keyboard.Modifiers == ModifierKeys.Control)
            {
                _searchInput?.Focus();
                e.Handled = true;
            }
        };
        // Dev/screenshot hook: DISKMAP_AUTOSCAN=<path> scans on launch,
        // DISKMAP_PAGE=<page> opens that page afterward.
        Loaded += async (_, _) =>
        {
            if (Environment.GetEnvironmentVariable("DISKMAP_AUTOSCAN") is { Length: > 0 } scanPath
                && !_model.IsScanning && _model.Tree is null)
            {
                await _model.ScanAsync(scanPath);
                if (Environment.GetEnvironmentVariable("DISKMAP_PAGE") is { Length: > 0 } page)
                    SelectPage(page);
            }
        };
    }

    private void BuildLogo()
    {
        LogoTile.Background = Ui.Hex("#1D2B4F");
        LogoTile.Child = new TextBlock
        {
            Text = "D", FontSize = 15, FontWeight = FontWeights.Bold,
            Foreground = System.Windows.Media.Brushes.White,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
    }

    // ---- Sidebar ----

    private void BuildNav()
    {
        // Scan action sits at the top of the nav — the one global action
        // the reference top bar doesn't carry.
        var scan = Ui.Button("Scan Folder…", Icons.Add, Ui.ButtonStyle.Outline,
            async () => await PickAndScan());
        scan.Margin = new Thickness(6, 0, 6, 10);
        NavPanel.Children.Add(scan);

        var sections = new List<(string Header, List<(string Name, string Glyph, Func<UserControl> Factory)> Items)>
        {
            ("MAIN",
            [
                ("Overview", Icons.Overview, () => (UserControl)new OverviewPage()),
            ]),
            ("FIND",
            [
                ("Biggest Files", Icons.BiggestFiles, () => (UserControl)new BiggestFilesPage()),
                ("Biggest Folders", Icons.BiggestFolders, () => (UserControl)new BiggestFoldersPage()),
                ("Forgotten Files", Icons.Forgotten, () => (UserControl)new ForgottenFilesPage()),
                ("Duplicates", Icons.Duplicates, () => (UserControl)new DuplicatesPage()),
            ]),
            ("CLEAN",
            [
                ("Safe to Review", Icons.SafeReview, () => (UserControl)new SafeToReviewPage()),
                ("Caches", Icons.Caches, () => (UserControl)new CachesPage()),
                ("Old Downloads", Icons.Downloads, () => (UserControl)new OldDownloadsPage()),
                ("Large Media", Icons.Media, () => (UserControl)new LargeMediaPage()),
            ]),
            ("EXPLORE",
            [
                ("File Browser", Icons.FileBrowser, () => (UserControl)new FileBrowserPage()),
                ("Visualize", Icons.Visualize, () => (UserControl)new VisualizePage()),
                ("Developer Storage", Icons.Developer, () => (UserControl)new DeveloperStoragePage()),
                ("Applications", Icons.Applications, () => (UserControl)new ApplicationsPage()),
                ("Snapshots", Icons.Snapshots, () => (UserControl)new SnapshotsPage()),
            ]),
        };

        foreach (var (header, items) in sections)
        {
            var label = Ui.SectionLabel(header);
            label.Margin = new Thickness(10, 14, 0, 4);
            NavPanel.Children.Add(label);
            foreach (var (name, glyph, factory) in items)
            {
                _pageFactories[name] = factory;
                var row = new StackPanel { Orientation = Orientation.Horizontal };
                row.Children.Add(Ui.Glyph(glyph, 13, Ui.Brush("AppSubtle")));
                row.Children.Add(new TextBlock
                {
                    Text = name, FontSize = 13,
                    Margin = new Thickness(10, 0, 0, 0),
                    VerticalAlignment = VerticalAlignment.Center,
                });
                var item = new Border
                {
                    CornerRadius = new CornerRadius(6),
                    Padding = new Thickness(10, 6, 10, 6),
                    Margin = new Thickness(0, 1, 0, 1),
                    Child = row,
                    Tag = name,
                    Cursor = Cursors.Hand,
                    Background = System.Windows.Media.Brushes.Transparent,
                };
                item.MouseLeftButtonDown += (_, _) => SelectPage(name);
                _navItems[name] = item;
                NavPanel.Children.Add(item);
            }
        }

        // The Search page exists but has no sidebar slot — reached via the
        // top-bar search box.
        _pageFactories["Search"] = () => new SearchPage();
        _pageFactories["Cleanup"] = () => new CleanupQueuePage();
    }

    private void SelectPage(string name)
    {
        if (!_pageFactories.TryGetValue(name, out var factory)) return;
        _currentPage = name;
        foreach (var (itemName, border) in _navItems)
        {
            bool selected = itemName == name;
            border.Background = selected ? Ui.Brush("AppNavSelected") : System.Windows.Media.Brushes.Transparent;
            if (border.Child is StackPanel row && row.Children.Count == 2)
            {
                ((TextBlock)row.Children[0]).Foreground =
                    selected ? Ui.Brush("AppForeground") : Ui.Brush("AppSubtle");
                ((TextBlock)row.Children[1]).FontWeight =
                    selected ? FontWeights.SemiBold : FontWeights.Normal;
            }
        }
        if (!_pages.TryGetValue(name, out var page)) _pages[name] = page = factory();
        PageHost.Content = page;
    }

    // ---- Top bar ----

    private void BuildTopBar()
    {
        var (box, input) = Ui.SearchBox("Search files, folders or ask anything…  (Ctrl+K)", 460);
        _searchInput = input;
        input.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter && input.Text.Trim().Length > 0)
            {
                _model.SearchQuery = input.Text.Trim();
                SelectPage("Search");
                e.Handled = true;
            }
        };
        SearchHost.Content = box;
        RefreshCleanupBadge();
        RescanButtonHost.Content = Ui.Button("Rescan", Icons.Rescan, Ui.ButtonStyle.Outline,
            async () => await Rescan());
    }

    private void RefreshCleanupBadge()
    {
        int count = _model.StagedItems.Count;
        string text = count > 0 ? $"Cleanup ({count})" : "Cleanup";
        CleanupButtonHost.Content = Ui.Button(text, Icons.Cleanup, Ui.ButtonStyle.Outline,
            () => SelectPage("Cleanup"));
    }

    // ---- Drive card ----

    private void RefreshDrive()
    {
        var vol = _model.Volume ?? VolumeStats.Of(null);
        if (vol is not { } v)
        {
            DriveName.Text = "Drive";
            DriveStats.Text = "";
            return;
        }
        DriveIcon.Content = Ui.Glyph(Icons.Drive, 14, Ui.Brush("AppSubtle"));
        DriveName.Text = v.DriveLabel;
        DriveStats.Text = $"{ByteFormat.Format(v.TotalBytes)} total · {ByteFormat.Format(v.FreeBytes)} free";
        DriveBar.Content = Ui.Bar(v.UsedFraction, Ui.Brush("AppAccent"), 5, 190);
    }

    // ---- Scanning ----

    private async Task PickAndScan()
    {
        if (_model.IsScanning) return;
        var hwnd = new WindowInteropHelper(this).Handle;
        var path = FolderPicker.Pick(hwnd);
        if (path is null) return;
        try
        {
            await _model.ScanAsync(path);
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Scan failed: {ex.Message}", "DiskMap",
                MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private async Task Rescan()
    {
        if (_model.RootPath is null)
        {
            await PickAndScan();
            return;
        }
        if (_model.IsScanning) return;
        try
        {
            await _model.RescanAsync();
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Rescan failed: {ex.Message}", "DiskMap",
                MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }
}
