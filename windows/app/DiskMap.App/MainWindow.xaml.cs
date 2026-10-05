using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;
using DiskMap.App.Pages;
using DiskMap.Core;

namespace DiskMap.App;

public partial class MainWindow : Window
{
    private readonly ScanModel _model = ScanModel.Shared;
    private TrayIcon? _tray;
    private readonly Dictionary<string, Func<UserControl>> _pageFactories = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Border> _navItems = new(StringComparer.Ordinal);
    // One instance per page for the session: a page keeps its state
    // (filters, results) and isn't rebuilt on every sidebar click.
    private readonly Dictionary<string, UserControl> _pages = new(StringComparer.Ordinal);
    private string _currentPage = "Overview";
    private TextBox? _searchInput;
    private Border? _topSearchBox;
    private double _textScale = 1;
    private bool _compactInspectorOpen;
    private bool _compactSidebarOpen;
    private bool? _lastCompact;
    private bool? _lastSidebarCompact;

    public MainWindow()
    {
        InitializeComponent();
        ApplyTextScale(AppSettings.Load());
        BuildNav();
        BuildTopBar();
        BuildLogo();
        InspectorHost.Content = new Controls.InspectorPanel();
        ModelEvents.WhileLoaded(this, RefreshDrive);
        _tray = new TrayIcon(this);
        Closed += (_, _) => _tray.Dispose();
        _model.PageRequested += SelectPage;
        _model.ToastRequested += ShowToast;
        _model.ConfirmRisky = (name, verdict) => Dialogs.ConfirmRisky(this, name, verdict);
        _model.ConfirmBulk = (title, message, items, footnote) =>
            Dialogs.Confirm(this, title, message, items, $"Add {items.Count:N0} to Cleanup", footnote: footnote);
        _model.ScanRequested += async () => await PickAndScan();
        _model.StagedChanged += (_, _) => RefreshCleanupBadge();
        _model.PropertyChanged += OnModelChanged;
        RefreshScanBanner();
        SizeChanged += (_, _) => RefreshAdaptiveLayout();
        SelectPage("Overview");
        // WIN-051: the shared keyboard map — destination shortcuts,
        // rescan, list navigation, stage/activate — one handler, routed
        // to the active page when it's a list.
        PreviewKeyDown += OnGlobalKey;
        // WIN-055: a directory argv beats the dev/screenshot env hook —
        // it is the explicit user action ("Scan with DiskMap").
        Loaded += async (_, _) =>
        {
            try
            {
                string? scanPath = App.StartupPath
                    ?? Environment.GetEnvironmentVariable("DISKMAP_AUTOSCAN");
                Trace("loaded");
                if (scanPath is { Length: > 0 }
                    && Directory.Exists(scanPath)
                    && !_model.IsScanning && _model.Tree is null)
                {
                    Trace($"scan:{scanPath}");
                    await _model.ScanAsync(scanPath);
                    Trace("scanned");
                    if (Environment.GetEnvironmentVariable("DISKMAP_PAGE") is { Length: > 0 } page)
                        SelectPage(page);
                }
                // WIN-080: render-to-file screenshot — the macOS --snapshot-dir
                // counterpart. Waits a beat for async page content (the
                // Overview's deferred Compute) before encoding.
                if (Environment.GetEnvironmentVariable("DISKMAP_SHOT") is { Length: > 0 } shotPath)
                {
                    await Task.Delay(
                        int.TryParse(Environment.GetEnvironmentVariable("DISKMAP_SHOT_SETTLE"), out int s) ? s : 1200);
                    SaveShot(shotPath);
                    // The popups too: the tray flyout and the risky-item
                    // warning, rendered next to the window shot.
                    if (Environment.GetEnvironmentVariable("DISKMAP_SHOT_POPUPS") == "1")
                    {
                        string stem = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(shotPath))!,
                            Path.GetFileNameWithoutExtension(shotPath));
                        _tray?.SaveFlyoutShot(stem + "-tray.png");
                        var wsl = StorageClassifier.Classify(@"C:\Users\you\AppData\Local\wsl\{id}\ext4.vhdx", false);
                        var risky = Dialogs.RiskyWindow(this, "ext4.vhdx", wsl, _ => { });
                        SaveWindowShot(risky, stem + "-risky.png");
                        risky.Close();
                    }
                    Trace("shot");
                    if (Environment.GetEnvironmentVariable("DISKMAP_SHOT_QUIT") != "0")
                        Close();
                }
            }
            catch (Exception ex) { Trace("ERR " + ex); }
        };
    }

    /// <summary>
    /// WIN-055: drop a folder anywhere on the window to scan it. Files
    /// get the ⊘ cursor — only directories are scannable.
    /// </summary>
    private void Window_DragOver(object sender, DragEventArgs e)
    {
        e.Effects = DroppedDirectory(e.Data) is not null
            ? DragDropEffects.Link : DragDropEffects.None;
        e.Handled = true;
    }

    private async void Window_Drop(object sender, DragEventArgs e)
    {
        if (DroppedDirectory(e.Data) is { } dir && !_model.IsScanning)
            await _model.ScanAsync(dir);
    }

    private static string? DroppedDirectory(IDataObject data)
    {
        if (!data.GetDataPresent(DataFormats.FileDrop)) return null;
        if (data.GetData(DataFormats.FileDrop) is not string[] paths) return null;
        return paths.FirstOrDefault(Directory.Exists);
    }

    private void BuildLogo()
    {
        LogoTile.Background = System.Windows.Media.Brushes.Transparent;
        LogoTile.Child = Ui.BrandIcon(32);
    }

    // ---- Sidebar ----

    private void BuildNav()
    {
        var sections = new List<(string Header, List<(string Name, string Glyph, Func<UserControl> Factory)> Items)>
        {
            ("MAIN",
            [
                ("Overview", Icons.Overview, () => (UserControl)new OverviewPage()),
            ]),
            ("FIND",
            [
                ("Find", Icons.Search, () => (UserControl)new SearchPage()),
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
                    Text = name, FontSize = Ui.Scaled(13),
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

        _pageFactories["Cleanup"] = () => new CleanupQueuePage();

        // WIN-065: saved searches sit at the bottom of the nav — they
        // re-read the store on every page switch, so a new save appears
        // the moment the user looks at the sidebar again.
        var savedLabel = Ui.SectionLabel("SAVED");
        savedLabel.Margin = new Thickness(10, 14, 0, 4);
        NavPanel.Children.Add(savedLabel);
        NavPanel.Children.Add(_savedHost);
        RefreshSavedSearches();
    }

    private readonly StackPanel _savedHost = new();

    private void RefreshSavedSearches()
    {
        _savedHost.Children.Clear();
        var saved = SavedSearches.Load();
        // Live totals — one count-only pass per search over the scan.
        Dictionary<Guid, SavedSearches.Total>? totals = null;
        if (_model.Tree is { } t && _model.Totals.Length == t.Count && saved.Count > 0)
        {
            var ctx = new FileQuery.Context(DuplicateFileIDs: _model.DuplicateFileIDs);
            totals = SavedSearches.Totals(saved, t, _model.RootPath ?? "", _model.Totals, ctx);
        }
        foreach (var search in saved)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            row.Children.Add(Ui.Glyph(Icons.Search, 13, Ui.Brush("AppSubtle")));
            row.Children.Add(new TextBlock
            {
                Text = search.Name, FontSize = Ui.Scaled(12.5),
                Margin = new Thickness(10, 0, 0, 0),
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
            if (totals is not null && totals.TryGetValue(search.Id, out var live) && live.Count > 0)
            {
                row.Children.Add(new TextBlock
                {
                    Text = $"  {ByteFormat.Format(live.Bytes)}", FontSize = Ui.Scaled(11),
                    Foreground = Ui.Brush("AppFaint"),
                    VerticalAlignment = VerticalAlignment.Center,
                });
            }
            var item = new Border
            {
                CornerRadius = new CornerRadius(6),
                Padding = new Thickness(10, 5, 10, 5),
                Margin = new Thickness(0, 1, 0, 1),
                Child = row,
                Cursor = Cursors.Hand,
                Background = System.Windows.Media.Brushes.Transparent,
                ToolTip = search.Query,
            };
            string query = search.Query;
            item.MouseLeftButtonDown += (_, _) =>
            {
                _model.SearchQuery = query;
                SelectPage("Find");
            };
            // Manage: rename/remove live on a right-click.
            Guid id = search.Id;
            item.MouseRightButtonDown += (_, e) =>
            {
                e.Handled = true;
                var menu = new ContextMenu();
                var rm = new MenuItem { Header = "Remove saved search" };
                rm.Click += (_, _) =>
                {
                    SavedSearches.Save(SavedSearches.Load().Where(s => s.Id != id));
                    RefreshSavedSearches();
                };
                menu.Items.Add(rm);
                menu.PlacementTarget = item;
                menu.IsOpen = true;
            };
            _savedHost.Children.Add(item);
        }
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
                Ui.SetIconBrush((FrameworkElement)row.Children[0],
                    selected ? Ui.Brush("AppAccent") : Ui.Brush("AppFaint"));
                ((TextBlock)row.Children[1]).FontWeight =
                    selected ? FontWeights.SemiBold : FontWeights.Normal;
            }
        }
        if (!_pages.TryGetValue(name, out var page)) _pages[name] = page = factory();
        PageHost.Content = page;
        if (page is ListPage listPage) listPage.ResetScrollPosition();
        if (_lastSidebarCompact == true)
        {
            _compactSidebarOpen = false;
            RefreshAdaptiveLayout();
        }
        RefreshSavedSearches();
    }

    /// <summary>Sidebar order — the Ctrl+1..N destination map.</summary>
    private static readonly string[] DestinationOrder =
    [
        "Overview", "Find", "Biggest Files", "Biggest Folders", "Forgotten Files",
        "Duplicates", "Safe to Review", "Caches", "Old Downloads",
        "Large Media", "File Browser", "Visualize", "Developer Storage",
        "Applications", "Snapshots",
    ];

    // ---- Toasts (WIN-063) ----

    private DispatcherTimer? _toastTimer;

    private void ShowToast(string text)
    {
        ToastText.Text = text;
        ToastHost.Visibility = Visibility.Visible;
        _toastTimer?.Stop();
        // Long toasts (skipped risky items) need time to read.
        _toastTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(text.Length > 60 ? 6 : 2.4) };
        _toastTimer.Tick += (_, _) =>
        {
            ToastHost.Visibility = Visibility.Collapsed;
            _toastTimer.Stop();
        };
        _toastTimer.Start();
    }

    private void OnGlobalKey(object sender, KeyEventArgs e)
    {
        var mods = Keyboard.Modifiers;
        // Ctrl+K / Ctrl+F — the palette.
        if (e.Key is Key.K or Key.F && mods == ModifierKeys.Control)
        {
            OpenCommandPalette();
            e.Handled = true;
            return;
        }
        // Ctrl+O — Scan Folder… (the window menu's old duty).
        if (e.Key == Key.O && mods == ModifierKeys.Control)
        {
            _ = PickAndScan();
            e.Handled = true;
            return;
        }
        // Ctrl+, — Settings (the ⌘, convention, WIN-060).
        if (e.Key == Key.OemComma && mods == ModifierKeys.Control)
        {
            OpenSettings();
            e.Handled = true;
            return;
        }
        if (e.Key == Key.Delete && mods == (ModifierKeys.Control | ModifierKeys.Shift))
        {
            SelectPage("Cleanup");
            e.Handled = true;
            return;
        }
        // Ctrl+1..N — destinations in sidebar order.
        if (mods == ModifierKeys.Control && e.Key is >= Key.D1 and <= Key.D9)
        {
            int index = e.Key - Key.D1;
            if (index < DestinationOrder.Length) SelectPage(DestinationOrder[index]);
            e.Handled = true;
            return;
        }
        // Ctrl+R rescan; Ctrl+Shift+R full rescan (drops the baseline so
        // the journal can't replay — a from-scratch walk).
        if (e.Key == Key.R && mods is ModifierKeys.Control or (ModifierKeys.Control | ModifierKeys.Shift))
        {
            e.Handled = true;
            if (mods.HasFlag(ModifierKeys.Shift) && _model.RootPath is { } rp)
                ScanCache.Remove(rp);
            _ = _model.RescanAsync();
            return;
        }
        if (e.OriginalSource is TextBox) return;   // let inputs own their keys

        // List navigation — the shared row behavior on every list page.
        if (PageHost.Content is FileListPage list)
        {
            if (e.Key == Key.A && mods == ModifierKeys.Control)
            {
                list.SelectAll(); e.Handled = true; return;
            }
            if (e.Key == Key.Escape)
            {
                _model.ClearMulti(); list.ClearChecked(); e.Handled = true; return;
            }
            bool handled = e.Key switch
            {
                Key.Down or Key.J => list.NavigateSelection(1),
                Key.Up or Key.K => list.NavigateSelection(-1),
                Key.Enter => list.ActivateSelection(),
                Key.Delete or Key.Back when mods == ModifierKeys.Control || e.Key == Key.Delete
                    => list.StageSelection(),
                _ => false,
            };
            // Ctrl+Down/Up: drill into / out of the selected folder.
            if (!handled && mods == ModifierKeys.Control
                && _model.Tree is { } t && _model.SelectedNode >= 0)
            {
                if (e.Key == Key.Down && t.IsDirectory[_model.SelectedNode])
                {
                    _model.DrillTo(_model.SelectedNode);
                    handled = true;
                }
                else if (e.Key == Key.Up)
                {
                    int parent = t.Parent[_model.SelectedNode];
                    if (parent >= 0) { _model.DrillToAncestor(parent); handled = true; }
                }
            }
            if (handled) e.Handled = true;
        }
    }

    // ---- Top bar ----

    private async void DriveCard_Click(object sender, MouseButtonEventArgs e) => await PickAndScan();

    /// <summary>Scan Folder… — the tray and Ctrl+O route here.</summary>
    internal Task ScanFolder() => PickAndScan();

    /// <summary>Export the current scan (JSON / NDJSON / CSV / ncdu) — the Snapshots header has the same.</summary>
    internal void ExportScan()
    {
        if (_model.Tree is not { } t || _model.RootPath is not { } root) return;
        var dlg = new Microsoft.Win32.SaveFileDialog
        {
            Title = "Export scan", FileName = "diskmap-scan",
            Filter = "JSON (nested)|*.json|NDJSON|*.ndjson|CSV|*.csv|ncdu|*.ncdu",
        };
        if (dlg.ShowDialog(this) != true) return;
        var format = dlg.FilterIndex switch
        {
            2 => TreeExporter.Format.Ndjson,
            3 => TreeExporter.Format.Csv,
            4 => TreeExporter.Format.Ncdu,
            _ => TreeExporter.Format.Json,
        };
        try
        {
            File.WriteAllText(dlg.FileName, TreeExporter.Export(t, _model.Totals, root, format));
            _model.Toast($"Exported to {Path.GetFileName(dlg.FileName)}");
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Couldn't write the export: {ex.Message}",
                "freedisk.space", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    /// <summary>WIN-080: launch-harness trace — one line per milestone when DISKMAP_TRACE is set.</summary>
    private static void Trace(string line)
    {
        if (Environment.GetEnvironmentVariable("DISKMAP_TRACE") is { Length: > 0 } path)
            File.AppendAllText(path, $"{DateTime.Now:HH:mm:ss.fff} {line}\n");
    }

    /// <summary>WIN-080: PNG of the whole window at device pixels — no z-order dependency.</summary>
    /// <summary>Shows <paramref name="window"/> off to the side, lays it out and saves it as PNG (harness only).</summary>
    internal static void SaveWindowShot(Window window, string path)
    {
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.Left = -10000;
        window.Top = 0;
        window.ShowActivated = false;
        window.Show();
        window.UpdateLayout();
        var element = (FrameworkElement)window.Content;
        var dpi = System.Windows.Media.VisualTreeHelper.GetDpi(window);
        var bmp = new System.Windows.Media.Imaging.RenderTargetBitmap(
            Math.Max(1, (int)Math.Ceiling(element.ActualWidth * dpi.DpiScaleX)),
            Math.Max(1, (int)Math.Ceiling(element.ActualHeight * dpi.DpiScaleY)),
            96 * dpi.DpiScaleX, 96 * dpi.DpiScaleY, System.Windows.Media.PixelFormats.Pbgra32);
        bmp.Render(element);
        var encoder = new System.Windows.Media.Imaging.PngBitmapEncoder();
        encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bmp));
        using var stream = File.Create(path);
        encoder.Save(stream);
    }

    private void SaveShot(string path)
    {
        var dpi = System.Windows.Media.VisualTreeHelper.GetDpi(this);
        var bmp = new System.Windows.Media.Imaging.RenderTargetBitmap(
            Math.Max(1, (int)Math.Ceiling(ActualWidth * dpi.DpiScaleX)),
            Math.Max(1, (int)Math.Ceiling(ActualHeight * dpi.DpiScaleY)),
            96 * dpi.DpiScaleX, 96 * dpi.DpiScaleY,
            System.Windows.Media.PixelFormats.Pbgra32);
        bmp.Render(this);
        var encoder = new System.Windows.Media.Imaging.PngBitmapEncoder();
        encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bmp));
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        using var stream = File.Create(path);
        encoder.Save(stream);
    }

    /// <summary>WIN-060: the Settings window — one instance, re-activated if open.</summary>
    private SettingsWindow? _settingsWindow;

    internal void OpenSettings()
    {
        if (_settingsWindow is not null)
        {
            _settingsWindow.Activate();
            return;
        }
        _settingsWindow = new SettingsWindow(SetAppearance, SetTextScale, RebuildForTheme) { Owner = this };
        _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        _settingsWindow.Show();
    }

    internal void OpenAbout()
    {
        var body = new StackPanel
        {
            Margin = new Thickness(36, 28, 36, 26),
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        var mark = Ui.BrandIcon(132);
        mark.HorizontalAlignment = HorizontalAlignment.Center;
        body.Children.Add(mark);
        var name = Ui.T("freedisk.space", 20, FontWeights.SemiBold);
        name.HorizontalAlignment = HorizontalAlignment.Center;
        name.Margin = new Thickness(0, 12, 0, 4);
        body.Children.Add(name);
        var version = System.Reflection.Assembly.GetExecutingAssembly().GetName().Version;
        var versionText = Ui.Mono(version is null ? "Development build" : $"Version {version}",
            11, null, Ui.Brush("AppFaint"));
        versionText.HorizontalAlignment = HorizontalAlignment.Center;
        body.Children.Add(versionText);
        var description = Ui.Subtle("See where your space went. Nothing leaves your PC.", 12);
        description.HorizontalAlignment = HorizontalAlignment.Center;
        description.Margin = new Thickness(0, 12, 0, 8);
        body.Children.Add(description);
        var promise = Ui.MonoLabel("LOCAL  ·  FAST  ·  PRIVATE");
        promise.HorizontalAlignment = HorizontalAlignment.Center;
        body.Children.Add(promise);
        new Window
        {
            Title = "About freedisk.space",
            Owner = this,
            Content = body,
            Width = 360,
            Height = 390,
            ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
        }.ShowDialog();
    }

    /// <summary>Appearance switch — palette + Fluent theme + rebuild cached pages.</summary>
    private void SetAppearance(string mode)
    {
        var settings = AppSettings.Load();
        settings.Appearance = mode;
        settings.Save();
        bool dark = settings.WantsDark;
#pragma warning disable WPF0001
        Application.Current.ThemeMode = dark ? ThemeMode.Dark : ThemeMode.Light;
#pragma warning restore WPF0001
        Theme.Apply(dark);
        RebuildForTheme();
    }

    internal void RebuildForTheme()
    {
        _pages.Clear();
        NavPanel.Children.Clear();
        _pageFactories.Clear();
        _navItems.Clear();
        BuildNav();
        BuildTopBar();
        BuildLogo();
        InspectorHost.Content = new Controls.InspectorPanel();
        SelectPage(_currentPage);
    }

    /// <summary>WIN-059: rebuild code-built typography at the selected text scale.</summary>
    private void SetTextScale(double scale)
    {
        var settings = AppSettings.Load();
        settings.TextScale = scale;
        settings.Save();
        ApplyTextScale(settings);
        RebuildForTheme();
    }

    private void ApplyTextScale(AppSettings settings)
    {
        _textScale = settings.TextScale;
        Ui.TextScale = settings.TextScale;
        RefreshAdaptiveLayout();
    }

    private void RefreshAdaptiveLayout()
    {
        bool compact = ActualWidth > 0 && ActualWidth < 1200;
        bool compactChanged = _lastCompact != compact;
        if (compactChanged)
        {
            _compactInspectorOpen = false;
            _lastCompact = compact;
        }
        InspectorButtonHost.Visibility = compact ? Visibility.Visible : Visibility.Collapsed;
        if (compact)
        {
            InspectorColumn.Width = new GridLength(0);
            Grid.SetColumn(InspectorBorder, 0);
            InspectorBorder.HorizontalAlignment = HorizontalAlignment.Right;
            InspectorBorder.Width = 320 * Math.Max(1, _textScale);
            InspectorBorder.Visibility = _compactInspectorOpen ? Visibility.Visible : Visibility.Collapsed;
        }
        else
        {
            Grid.SetColumn(InspectorBorder, 1);
            InspectorBorder.HorizontalAlignment = HorizontalAlignment.Stretch;
            InspectorBorder.Width = double.NaN;
            InspectorBorder.Visibility = Visibility.Visible;
            double baseWidth = ActualWidth >= 1450 ? 320 : 290;
            InspectorColumn.Width = new GridLength(baseWidth * Math.Max(1, _textScale));
        }

        bool compactSidebar = ActualWidth > 0 && ActualWidth < 1000;
        if (_lastSidebarCompact != compactSidebar)
        {
            _compactSidebarOpen = false;
            _lastSidebarCompact = compactSidebar;
        }
        SidebarButtonHost.Visibility = compactSidebar ? Visibility.Visible : Visibility.Collapsed;
        if (compactSidebar)
        {
            SidebarColumn.Width = new GridLength(0);
            Grid.SetColumn(SidebarBorder, 1);
            SidebarBorder.HorizontalAlignment = HorizontalAlignment.Left;
            SidebarBorder.Width = 212 * Math.Max(1, _textScale);
            SidebarBorder.Visibility = _compactSidebarOpen ? Visibility.Visible : Visibility.Collapsed;
        }
        else
        {
            Grid.SetColumn(SidebarBorder, 0);
            SidebarBorder.HorizontalAlignment = HorizontalAlignment.Stretch;
            SidebarBorder.Width = double.NaN;
            SidebarBorder.Visibility = Visibility.Visible;
            SidebarColumn.Width = new GridLength(212 * Math.Max(1, _textScale));
        }
        if (_topSearchBox is not null) _topSearchBox.Width = compact ? 260 : 460;
        if (compactChanged && _topSearchBox is not null) RefreshScanButton();
    }

    private void BuildTopBar()
    {
        var (box, input) = Ui.SearchBox("Search files, folders or ask anything…  (Ctrl+K)", 460);
        _topSearchBox = box;
        _searchInput = input;
        input.PreviewMouseLeftButtonDown += (_, e) =>
        {
            OpenCommandPalette();
            e.Handled = true;
        };
        input.GotKeyboardFocus += (_, e) =>
        {
            // Tab focus also opens the palette — the box is a launcher.
            if (_palette?.IsOpen != true) OpenCommandPalette();
        };
        input.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter && input.Text.Trim().Length > 0)
            {
                _model.SearchQuery = input.Text.Trim();
                SelectPage("Find");
                e.Handled = true;
            }
        };
        SearchHost.Content = box;
        var appearance = AppSettings.Load();
        AppearanceButtonHost.Content = Ui.IconButton(
            appearance.WantsDark ? Icons.LightMode : Icons.DarkMode,
            appearance.WantsDark ? "Use light appearance" : "Use dark appearance",
            () => SetAppearance(appearance.WantsDark ? "light" : "dark"));
        SidebarButtonHost.Content = Ui.IconButton(Icons.List, "Sidebar", () =>
        {
            _compactSidebarOpen = !_compactSidebarOpen;
            RefreshAdaptiveLayout();
        });
        InspectorButtonHost.Content = Ui.IconButton(Icons.Info, "Inspector", () =>
        {
            _compactInspectorOpen = !_compactInspectorOpen;
            RefreshAdaptiveLayout();
        });
        RefreshAdaptiveLayout();
        RefreshCleanupBadge();
        RefreshScanButton();
        ScanCancelHost.Content = Ui.Button("Cancel", Icons.Cancel, Ui.ButtonStyle.Outline,
            () => _model.CancelScan());
    }

    // ---- WIN-053: command palette (⌘K port) ----

    private Popup? _palette;

    private void OpenCommandPalette()
    {
        var card = new Border
        {
            Background = Ui.Brush("AppCard"),
            BorderBrush = Ui.Brush("AppCardBorder"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(14),
            Width = 520,
            Effect = new System.Windows.Media.Effects.DropShadowEffect
            {
                BlurRadius = 18, Opacity = 0.18, ShadowDepth = 4,
            },
        };
        var body = new StackPanel();
        var (searchBox, input) = Ui.SearchBox("type a query — size>500MB age>1y, or plain words…", 460);
        input.Text = _model.SearchQuery;
        body.Children.Add(searchBox);
        var meaning = Ui.Faint("");
        meaning.Margin = new Thickness(0, 6, 0, 0);
        body.Children.Add(meaning);
        var results = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
        body.Children.Add(results);
        var footer = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
        body.Children.Add(footer);
        card.Child = body;

        var popup = new Popup
        {
            PlacementTarget = SearchHost,
            Placement = PlacementMode.Bottom,
            HorizontalOffset = -30,
            VerticalOffset = 8,
            StaysOpen = false,
            AllowsTransparency = true,
            Child = card,
        };
        _palette = popup;

        void repopulate()
        {
            results.Children.Clear();
            footer.Children.Clear();
            string q = input.Text.Trim();
            var tree = _model.Tree;
            if (q.Length > 0 && tree is not null && _model.Totals.Length == tree.Count)
            {
                var parsed = FileQuery.Parse(q,
                    home: Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                    root: _model.RootPath ?? "");
                meaning.Text = parsed.Query.IsStructured
                    ? string.Join("  ·  ", parsed.Query.Describe())
                    : $"matching \"{q}\" by name, largest first";
                var ctx = new FileQuery.Context(DuplicateFileIDs: _model.DuplicateFileIDs);
                var hits = parsed.Query.IsStructured
                    ? parsed.Query.Run(tree, _model.RootPath ?? "", _model.Totals, ctx, limit: 8).Ids
                    : FileSearch.Search(tree, _model.Totals, q, limit: 8);
                if (parsed.Problems.Count > 0)
                    meaning.Text += " — not understood: "
                        + string.Join("; ", parsed.Problems.Select(p => $"{p.Token} ({p.Message})"));
                foreach (var id in hits)
                {
                    string name = tree.NameOf(id);
                    long size = _model.Totals[id];
                    var row = new DockPanel { Margin = new Thickness(0, 3, 0, 3) };
                    var sz = Ui.T(ByteFormat.Format(size), 11.5, FontWeights.Medium);
                    DockPanel.SetDock(sz, Dock.Right);
                    row.Children.Add(sz);
                    row.Children.Add(Ui.T($"{name}  —  {_model.DisplayPath(id)}", 12));
                    row.Cursor = Cursors.Hand;
                    int captured = id;
                    row.MouseLeftButtonDown += (_, _) =>
                    {
                        popup.IsOpen = false;
                        _model.Select(captured);
                    };
                    results.Children.Add(row);
                }
                var all = Ui.T("Show all results in Find →", 12, FontWeights.Medium, Ui.Brush("AppAccent"));
                all.Cursor = Cursors.Hand;
                all.MouseLeftButtonDown += (_, _) =>
                {
                    popup.IsOpen = false;
                    _model.SearchQuery = q;
                    SelectPage("Find");
                };
                footer.Children.Add(all);
            }
            else
            {
                meaning.Text = tree is null
                    ? "Scan a folder first — the palette searches the scan."
                    : "Saved searches and quick filters — Enter runs the query.";
                var saved = SavedSearches.Load();
                if (saved.Count > 0)
                {
                    footer.Children.Add(Ui.SectionLabel("SAVED SEARCHES"));
                    foreach (var s in saved)
                    {
                        var row = new DockPanel { Margin = new Thickness(0, 3, 0, 3) };
                        row.Children.Add(Ui.T($"{s.Name}  —  {s.Query}", 12));
                        row.Cursor = Cursors.Hand;
                        string query = s.Query;
                        row.MouseLeftButtonDown += (_, _) =>
                        {
                            popup.IsOpen = false;
                            _model.SearchQuery = query;
                            SelectPage("Find");
                        };
                        footer.Children.Add(row);
                    }
                }
            }
        }
        repopulate();
        input.TextChanged += (_, _) => repopulate();
        input.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter && input.Text.Trim().Length > 0)
            {
                popup.IsOpen = false;
                _model.SearchQuery = input.Text.Trim();
                SelectPage("Find");
                e.Handled = true;
            }
            else if (e.Key == Key.Escape) { popup.IsOpen = false; e.Handled = true; }
        };
        popup.Opened += (_, _) => Dispatcher.BeginInvoke(() => input.Focus());
        popup.IsOpen = true;
    }

    /// <summary>
    /// While scanning, the Rescan button becomes Cancel — a scan in flight
    /// needs a stop affordance, not a second start.
    /// </summary>
    private void RefreshScanButton()
    {
        bool compact = ActualWidth > 0 && ActualWidth < 1200;
        RescanButtonHost.Content = compact
            ? _model.IsScanning
                ? Ui.IconButton(Icons.Cancel, "Cancel scan", () => _model.CancelScan())
                : Ui.IconButton(Icons.Rescan, "Rescan", async () => await Rescan())
            : _model.IsScanning
                ? Ui.Button("Cancel", Icons.Cancel, Ui.ButtonStyle.Outline, () => _model.CancelScan())
                : Ui.Button("Rescan", Icons.Rescan, Ui.ButtonStyle.Outline, async () => await Rescan());
    }

    private void OnModelChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(ScanModel.IsScanning):
                RefreshScanButton();
                RefreshScanBanner();
                break;
            case nameof(ScanModel.ScanStats):
            case nameof(ScanModel.ScanPhase):
                RefreshScanBanner();
                break;
        }
    }

    private void RefreshScanBanner()
    {
        if (!_model.IsScanning)
        {
            ScanBanner.Visibility = Visibility.Collapsed;
            ScanTopLevels.ItemsSource = null;
            ScanDustyHost.Content = null;
            return;
        }
        ScanBanner.Visibility = Visibility.Visible;
        ScanDustyHost.Content = AppSettings.Load().ShowDusty ? Ui.BrandIcon(40) : null;
        if (_model.ScanPhase == "summarizing")
        {
            ScanBannerText.Text = "Summarizing scan — rolling up sizes…";
            return;
        }
        var s = _model.ScanStats;
        ScanBannerText.Text = s is null
            ? $"Scanning {_model.RootPath}…"
            : $"Scanning {s.CurrentFolder}…  {s.Items:N0} items · " +
              $"{s.ItemsPerSecond:N0}/s · {ByteFormat.Format(s.Bytes)}";
        // WIN-006: per-top-level fill bars — the live report already
        // carries each top-level folder's running bytes.
        if (s?.TopLevel is { Count: > 1 } top)
        {
            long max = top.Max(t => t.Bytes);
            ScanTopLevels.ItemsSource = top.OrderByDescending(t => t.Bytes).Take(6).Select(t =>
            {
                var row = new DockPanel { Margin = new Thickness(0, 1, 0, 0) };
                var fill = new Border
                {
                    Height = 3, CornerRadius = new CornerRadius(1.5),
                    HorizontalAlignment = HorizontalAlignment.Left,
                    Background = Ui.Brush("AppAccent"),
                    Width = 140 * Math.Max(0.02, max > 0 ? (double)t.Bytes / max : 0),
                    Margin = new Thickness(0, 0, 6, 0),
                    VerticalAlignment = VerticalAlignment.Center,
                };
                DockPanel.SetDock(fill, Dock.Left);
                row.Children.Add(fill);
                row.Children.Add(Ui.Subtle($"{t.Name}  {ByteFormat.Format(t.Bytes)}", 10.5));
                return (UIElement)row;
            }).ToList();
        }
        else
        {
            ScanTopLevels.ItemsSource = null;
        }
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
        DriveStats.Text = $"{ByteFormat.Format(v.FreeBytes)} free of {ByteFormat.Format(v.TotalBytes)}";
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
            MessageBox.Show($"Scan failed: {ex.Message}", "freedisk.space",
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
            MessageBox.Show($"Rescan failed: {ex.Message}", "freedisk.space",
                MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }
}
