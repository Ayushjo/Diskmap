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

    public MainWindow()
    {
        InitializeComponent();
        BuildNav();
        BuildTopBar();
        BuildLogo();
        InspectorHost.Content = new Controls.InspectorPanel();
        ModelEvents.WhileLoaded(this, RefreshDrive);
        _tray = new TrayIcon(this);
        Closed += (_, _) => _tray.Dispose();
        _model.PageRequested += SelectPage;
        _model.ToastRequested += ShowToast;
        _model.ScanRequested += async () => await PickAndScan();
        _model.StagedChanged += (_, _) => RefreshCleanupBadge();
        _model.PropertyChanged += OnModelChanged;
        RefreshScanBanner();
        ApplyTextScale(AppSettings.Load());
        SelectPage("Overview");
        // WIN-051: the shared keyboard map — destination shortcuts,
        // rescan, list navigation, stage/activate — one handler, routed
        // to the active page when it's a list.
        PreviewKeyDown += OnGlobalKey;
        // WIN-055: a directory argv beats the dev/screenshot env hook —
        // it is the explicit user action ("Scan with DiskMap").
        Loaded += async (_, _) =>
        {
            string? scanPath = App.StartupPath
                ?? Environment.GetEnvironmentVariable("DISKMAP_AUTOSCAN");
            if (scanPath is { Length: > 0 }
                && Directory.Exists(scanPath)
                && !_model.IsScanning && _model.Tree is null)
            {
                await _model.ScanAsync(scanPath);
                if (Environment.GetEnvironmentVariable("DISKMAP_PAGE") is { Length: > 0 } page)
                    SelectPage(page);
            }
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
                Text = search.Name, FontSize = 12.5,
                Margin = new Thickness(10, 0, 0, 0),
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
            if (totals is not null && totals.TryGetValue(search.Id, out var live) && live.Count > 0)
            {
                row.Children.Add(new TextBlock
                {
                    Text = $"  {ByteFormat.Format(live.Bytes)}", FontSize = 11,
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
                SelectPage("Search");
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
                ((TextBlock)row.Children[0]).Foreground =
                    selected ? Ui.Brush("AppForeground") : Ui.Brush("AppSubtle");
                ((TextBlock)row.Children[1]).FontWeight =
                    selected ? FontWeights.SemiBold : FontWeights.Normal;
            }
        }
        if (!_pages.TryGetValue(name, out var page)) _pages[name] = page = factory();
        PageHost.Content = page;
        RefreshSavedSearches();
    }

    /// <summary>Sidebar order — the Ctrl+1..N destination map.</summary>
    private static readonly string[] DestinationOrder =
    [
        "Overview", "Biggest Files", "Biggest Folders", "Forgotten Files",
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
        _toastTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2.4) };
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

    /// <summary>
    /// WIN-056: the File/Go menu — Scan, rescan quick/full, export, put
    /// back, destinations, exit. The staging toast covers the transient
    /// feedback side.
    /// </summary>
    private void MenuButton_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu();
        var scan = new MenuItem { Header = "Scan Folder…" };
        scan.Click += async (_, _) => await PickAndScan();
        menu.Items.Add(scan);
        var rescan = new MenuItem { Header = "Rescan\tCtrl+R", IsEnabled = _model.RootPath is not null };
        rescan.Click += async (_, _) => await _model.RescanAsync();
        menu.Items.Add(rescan);
        var full = new MenuItem { Header = "Full Rescan\tCtrl+Shift+R", IsEnabled = _model.RootPath is not null };
        full.Click += async (_, _) =>
        {
            if (_model.RootPath is { } rp) ScanCache.Remove(rp);
            await _model.RescanAsync();
        };
        menu.Items.Add(full);
        menu.Items.Add(new Separator());
        var export = new MenuItem
        {
            Header = "Export Scan…",
            IsEnabled = _model.Tree is not null,
        };
        export.Click += (_, _) =>
        {
            // Same affordance as the Snapshots header.
            if (_model.Tree is { } t && _model.RootPath is { } root)
            {
                var dlg = new Microsoft.Win32.SaveFileDialog
                {
                    Title = "Export scan", FileName = "diskmap-scan",
                    Filter = "JSON (nested)|*.json|NDJSON|*.ndjson|CSV|*.csv|ncdu|*.ncdu",
                };
                if (dlg.ShowDialog() == true)
                {
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
                            "DiskMap", MessageBoxButton.OK, MessageBoxImage.Warning);
                    }
                }
            }
        };
        menu.Items.Add(export);
        var putBack = new MenuItem { Header = "Put Back Last Cleanup", IsEnabled = CleanupRecord.Load() is { Items.Count: > 0 } };
        putBack.Click += (_, _) => SelectPage("Cleanup");
        menu.Items.Add(putBack);
        menu.Items.Add(new Separator());
        var go = new MenuItem { Header = "Go" };
        foreach (var dest in DestinationOrder)
        {
            var item = new MenuItem { Header = dest };
            string captured = dest;
            item.Click += (_, _) => SelectPage(captured);
            go.Items.Add(item);
        }
        menu.Items.Add(go);
        // WIN-058/059: View — appearance + text scale, applied live.
        var view = new MenuItem { Header = "View" };
        var appearance = new MenuItem { Header = "Appearance" };
        foreach (var (id, label) in new[] { ("system", "Follow Windows"), ("light", "Light"), ("dark", "Dark") })
        {
            var item = new MenuItem { Header = label };
            string captured = id;
            item.Click += (_, _) => SetAppearance(captured);
            appearance.Items.Add(item);
        }
        view.Items.Add(appearance);
        var textSize = new MenuItem { Header = "Text size" };
        foreach (var (scale, label) in new[] { (0.9, "Small"), (1.0, "Default"), (1.1, "Large"), (1.2, "Extra large") })
        {
            var item = new MenuItem { Header = label };
            double captured = scale;
            item.Click += (_, _) => SetTextScale(captured);
            textSize.Items.Add(item);
        }
        view.Items.Add(textSize);
        menu.Items.Add(view);
        menu.Items.Add(new Separator());
        var exit = new MenuItem { Header = "Exit" };
        exit.Click += (_, _) => Close();
        menu.Items.Add(exit);
        menu.PlacementTarget = (Button)sender;
        menu.IsOpen = true;
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
        _pages.Clear();               // code-built brushes resolve once — rebuild
        SelectPage(_currentPage);
    }

    /// <summary>WIN-059: text scale as a LayoutTransform on the content root.</summary>
    private void SetTextScale(double scale)
    {
        var settings = AppSettings.Load();
        settings.TextScale = scale;
        settings.Save();
        ApplyTextScale(settings);
    }

    private void ApplyTextScale(AppSettings settings)
    {
        // Uniform scale on the page+inspector column; sidebar stays 1x —
        // its labels are already compact.
        PageHost.LayoutTransform = new System.Windows.Media.ScaleTransform(
            settings.TextScale, settings.TextScale);
    }

    private void BuildTopBar()
    {
        var (box, input) = Ui.SearchBox("Search files, folders or ask anything…  (Ctrl+K)", 460);
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
                SelectPage("Search");
                e.Handled = true;
            }
        };
        SearchHost.Content = box;
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
                    SelectPage("Search");
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
                            SelectPage("Search");
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
                SelectPage("Search");
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
        RescanButtonHost.Content = _model.IsScanning
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
            return;
        }
        ScanBanner.Visibility = Visibility.Visible;
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
