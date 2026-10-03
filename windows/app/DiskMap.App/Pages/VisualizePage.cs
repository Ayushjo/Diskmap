using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using DiskMap.App.Controls;
using DiskMap.Core;

namespace DiskMap.App.Pages;

/// <summary>
/// "Visualize Storage" — the reference design's flagship screen: mode
/// switcher pills, breadcrumb + Focus bar, the current-folder header
/// card with its type breakdown, the chart canvas with zoom controls,
/// and the largest-items table underneath.
/// </summary>
public sealed class VisualizePage : ListPage
{
    private static readonly (string Mode, string Glyph, string Blurb)[] Modes =
    [
        ("Treemap", Icons.Visualize, "See what's taking space"),
        ("Sunburst", "\u25D0", "Breakdown by depth"),
        ("Flame", "\u25B2", "Hierarchy view"),
        ("Bubbles", "\u25CF", "Compare sizes"),
        ("Mind Map", "\u25C8", "Relationship view"),
        ("Age Map", "\u25F7", "What's been forgotten"),
        ("Top Sizes", "\u2261", "Largest items"),
        ("Folders", "\u25A4", "Browse folders"),
    ];

    private readonly WrapPanel _switcher = new();
    private readonly DockPanel _breadcrumb = new();
    private readonly StackPanel _headerCard = new();
    private readonly Border _chartHost = new();
    private readonly StackPanel _below = new();
    private readonly Grid _chartClip = new();
    private FrameworkElement? _chart;
    private double _zoom = 1.0;
    private readonly TextBlock _zoomLabel = new() { FontSize = 11.5, VerticalAlignment = VerticalAlignment.Center };

    public VisualizePage()
    {
        Root.Margin = new Thickness(24, 20, 24, 20);
        Root.Children.Add(BuildHeader());
        Root.Children.Add(BuildSwitcher());
        Root.Children.Add(BuildColoringBar());
        Root.Children.Add(Ui.Card(_breadcrumb, 10, new Thickness(0, 0, 0, 10)));
        Root.Children.Add(_headerCard);
        var chartCard = Ui.Card(_chartClip, 0, new Thickness(0, 0, 0, 10));
        _chartClip.Height = 420;
        _chartClip.ClipToBounds = true;
        Root.Children.Add(chartCard);
        Root.Children.Add(_multiStrip);
        Root.Children.Add(BuildZoomBar());
        Root.Children.Add(_below);
    }

    protected override void Refresh()
    {
        BuildSwitcherItems();
        RefreshColoringBar();
        RefreshLegend();
        RefreshBreadcrumb();
        RefreshHeaderCard();
        RefreshChart();
        RefreshBelow();
        RefreshMultiStrip();
    }

    // ---- WIN-052: shared multi-select strip ----

    private readonly StackPanel _multiStrip = new();

    /// <summary>
    /// Ctrl+click builds a set across every chart; this strip owns the
    /// actions: count, coverage-deduped bytes, stage-all, clear (Esc).
    /// </summary>
    private void RefreshMultiStrip()
    {
        _multiStrip.Children.Clear();
        var set = Model.MultiSelection;
        if (set.Count == 0) return;
        var bar = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        var left = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        left.Children.Add(Ui.T(
            $"{set.Count} selected · {ByteFormat.Format(Model.MultiSelectionBytes())} (a folder's contents count once)",
            12, FontWeights.SemiBold));
        var stage = Ui.Button("Add to Cleanup", Icons.Add, Ui.ButtonStyle.Dark, () =>
        {
            int staged = 0;
            foreach (int id in set.ToList())
                if (Model.Stage(id, "visualize multi-select")) staged++;
            Model.ClearMulti();
            if (staged > 0) Model.ShowPage("Cleanup");
        });
        stage.Margin = new Thickness(10, 0, 0, 0);
        var copy = Ui.Button("Copy paths", Icons.Copy, Ui.ButtonStyle.Outline, () =>
        {
            var paths = set.Select(id => TreeExporter.QuotePathIfNeeded(Model.PathOf(id)));
            Clipboard.SetText(string.Join(Environment.NewLine, paths));
        });
        copy.Margin = new Thickness(6, 0, 0, 0);
        var clear = Ui.Button("Clear", Icons.Cancel, Ui.ButtonStyle.Outline, () => Model.ClearMulti());
        clear.Margin = new Thickness(6, 0, 0, 0);
        left.Children.Add(stage);
        left.Children.Add(copy);
        left.Children.Add(clear);
        DockPanel.SetDock(left, Dock.Left);
        bar.Children.Add(left);
        _multiStrip.Children.Add(Ui.Card(bar, 8));
    }

    private DockPanel BuildHeader()
    {
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 14) };
        var status = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
        };
        // The green "Scan completed" line from the mockup.
        var dot = new Border
        {
            Width = 8, Height = 8, CornerRadius = new CornerRadius(4),
            Background = Ui.Brush("AppSuccess"), Margin = new Thickness(0, 0, 6, 0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        status.Children.Add(dot);
        var statusText = Ui.Subtle("", 12);
        statusText.Name = "statusText";
        status.Children.Add(statusText);
        DockPanel.SetDock(status, Dock.Right);
        header.Children.Add(status);
        var titles = new StackPanel();
        titles.Children.Add(Ui.PageTitle("Visualize Storage"));
        titles.Children.Add(Ui.PageSubtitle("Explore your disk as a map. Click to inspect, double-click a folder to enter it."));
        header.Children.Add(titles);
        _statusText = statusText;
        return header;
    }

    /// <summary>
    /// WIN-048: coloring mode pills + the depth slider (slice-collapse
    /// threshold). Both repaint the chart through model properties.
    /// </summary>
    private UIElement BuildColoringBar()
    {
        var bar = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };

        var depth = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        depth.Children.Add(Ui.Subtle("Depth ", 11.5));
        var slider = new Slider
        {
            Minimum = 0, Maximum = 4, Value = 3, Width = 90,
            VerticalAlignment = VerticalAlignment.Center,
            ToolTip = "How deep the chart draws: finer shows smaller folders",
        };
        var depthLabel = Ui.Subtle("0.5%", 11.5);
        depthLabel.Margin = new Thickness(6, 0, 0, 0);
        var fractions = new[] { 0.0001, 0.0005, 0.001, ChartLayout.OtherFraction, 0.02 };
        slider.ValueChanged += (_, e) =>
        {
            int i = (int)Math.Round(e.NewValue);
            Model.ChartDepth = fractions[Math.Clamp(i, 0, fractions.Length - 1)];
            depthLabel.Text = $"{fractions[Math.Clamp(i, 0, fractions.Length - 1)] * 100:0.##}%";
        };
        depth.Children.Add(slider);
        depth.Children.Add(depthLabel);
        DockPanel.SetDock(depth, Dock.Right);
        bar.Children.Add(depth);

        _coloringRow = new WrapPanel { VerticalAlignment = VerticalAlignment.Center };
        bar.Children.Add(_coloringRow);

        // WIN-050: a legend explains the active coloring — age buckets or
        // "type/folder" semantic labels; gray always means "Other".
        _legendRow = new WrapPanel { Margin = new Thickness(0, 4, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        var legendHost = new DockPanel();
        legendHost.Children.Add(_legendRow);
        var wrap = new StackPanel();
        wrap.Children.Add(bar);
        wrap.Children.Add(_legendRow);
        return wrap;
    }

    private WrapPanel? _legendRow;

    /// <summary>Repaint the legend to explain whatever coloring is on.</summary>
    private void RefreshLegend()
    {
        if (_legendRow is null) return;
        _legendRow.Children.Clear();
        switch (Model.ColoringMode)
        {
            case "age":
                foreach (var (bucket, label) in new[]
                {
                    (Core.AgeBucket.Under30, "< 30d"),
                    (Core.AgeBucket.Days30To90, "30–90d"),
                    (Core.AgeBucket.Days90To365, "90d–1y"),
                    (Core.AgeBucket.OneToTwoYears, "1–2y"),
                    (Core.AgeBucket.OverTwoYears, "> 2y"),
                })
                {
                    _legendRow.Children.Add(LegendChip(NodeColors.AgeBucket(bucket), label));
                }
                break;
            case "type":
                _legendRow.Children.Add(Ui.Subtle("Tile color = dominant file type; folders keep their own hue. ", 11));
                break;
            default:
                _legendRow.Children.Add(Ui.Subtle("Tile color = folder hue (stable per folder). ", 11));
                break;
        }
        _legendRow.Children.Add(LegendChip(NodeColors.OtherBrush, "Other"));
    }

    private static UIElement LegendChip(Brush brush, string label)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 12, 2) };
        row.Children.Add(new Border
        {
            Width = 10, Height = 10, CornerRadius = new CornerRadius(2),
            Background = brush, Margin = new Thickness(0, 0, 5, 0),
        });
        row.Children.Add(Ui.Subtle(label, 11));
        return row;
    }

    private WrapPanel? _coloringRow;

    private void RefreshColoringBar()
    {
        if (_coloringRow is null) return;
        _coloringRow.Children.Clear();
        _coloringRow.Children.Add(Ui.Subtle("Color by ", 11.5));
        foreach (var (id, label) in new[] { ("type", "Type"), ("folder", "Folder"), ("age", "Age") })
        {
            var pill = Ui.Pill(label, Model.ColoringMode == id,
                () => { Model.ColoringMode = id; RefreshLegend(); });
            pill.Margin = new Thickness(0, 0, 4, 0);
            _coloringRow.Children.Add(pill);
        }
    }

    private TextBlock? _statusText;

    private UIElement BuildSwitcher()
    {
        _switcher.Margin = new Thickness(0, 0, 0, 12);
        return _switcher;
    }

    private void BuildSwitcherItems()
    {
        _switcher.Children.Clear();
        foreach (var (mode, glyph, blurb) in Modes)
        {
            bool selected = Model.VisualizeMode == mode;
            var content = new StackPanel();
            var titleRow = new StackPanel { Orientation = Orientation.Horizontal };
            bool privateUseGlyph = glyph.Length > 0 && glyph[0] >= '';
            titleRow.Children.Add(new TextBlock
            {
                Text = glyph, FontSize = 13,
                FontFamily = privateUseGlyph ? new FontFamily(Icons.Font) : FontFamily,
                Foreground = selected ? Ui.Brush("AppAccent") : Ui.Brush("AppSubtle"),
                VerticalAlignment = VerticalAlignment.Center,
            });
            titleRow.Children.Add(new TextBlock
            {
                Text = "  " + mode, FontSize = 12.5, FontWeight = FontWeights.SemiBold,
                VerticalAlignment = VerticalAlignment.Center,
            });
            content.Children.Add(titleRow);
            content.Children.Add(new TextBlock
            {
                Text = blurb, FontSize = 10.5, Foreground = Ui.Brush("AppFaint"),
                Margin = new Thickness(0, 2, 0, 0),
            });
            var card = new Border
            {
                Background = selected ? Ui.Brush("AppAccentSoft") : Ui.Brush("AppCard"),
                BorderBrush = selected ? Ui.Brush("AppAccent") : Ui.Brush("AppCardBorder"),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(12, 8, 12, 8),
                Margin = new Thickness(0, 0, 8, 8),
                MinWidth = 120,
                Child = content,
                Cursor = System.Windows.Input.Cursors.Hand,
            };
            string captured = mode;
            card.MouseLeftButtonDown += (_, _) => Model.VisualizeMode = captured;
            _switcher.Children.Add(card);
        }
    }

    private void RefreshBreadcrumb()
    {
        _breadcrumb.Children.Clear();
        var back = Ui.Button("", Icons.Back, Ui.ButtonStyle.Outline, () => StepBack());
        back.Padding = new Thickness(7, 3, 7, 3);
        var fwd = Ui.Button("", Icons.Forward, Ui.ButtonStyle.Outline, () => StepForward());
        fwd.Padding = new Thickness(7, 3, 7, 3);
        fwd.Margin = new Thickness(4, 0, 0, 0);
        DockPanel.SetDock(back, Dock.Left);
        DockPanel.SetDock(fwd, Dock.Left);
        _breadcrumb.Children.Add(back);
        _breadcrumb.Children.Add(fwd);

        var focus = Ui.Button("Focus", Icons.Focus, Ui.ButtonStyle.Outline,
            () => { if (Model.SelectedNode >= 0) Model.DrillTo(Model.SelectedNode); });
        focus.Margin = new Thickness(0, 0, 0, 0);
        DockPanel.SetDock(focus, Dock.Right);
        _breadcrumb.Children.Add(focus);

        var crumbs = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 0) };
        var tree = Model.Tree;
        if (tree is not null)
        {
            var folderIcon = Ui.Glyph(Icons.Folder, 12, Ui.Brush("AppSubtle"));
            folderIcon.Margin = new Thickness(0, 0, 8, 0);
            crumbs.Children.Add(folderIcon);
            var chain = Model.Breadcrumbs();
            for (int i = 0; i < chain.Count; i++)
            {
                int id = chain[i];
                bool last = i == chain.Count - 1;
                string label = id == 0 && Model.RootPath is { } rp ? rp.TrimEnd('\\', '/') : tree.NameOf(id);
                var crumb = new TextBlock
                {
                    Text = label, FontSize = 12.5,
                    FontWeight = last ? FontWeights.SemiBold : FontWeights.Normal,
                    Foreground = last ? Ui.Brush("AppForeground") : Ui.Brush("AppSubtle"),
                    VerticalAlignment = VerticalAlignment.Center,
                    Cursor = last ? null : System.Windows.Input.Cursors.Hand,
                };
                if (!last)
                    crumb.MouseLeftButtonDown += (_, _) => Model.DrillToAncestor(id);
                crumbs.Children.Add(crumb);
                if (!last)
                    crumbs.Children.Add(new TextBlock
                    {
                        Text = "  ›  ", FontSize = 12, Foreground = Ui.Brush("AppFaint"),
                        VerticalAlignment = VerticalAlignment.Center,
                    });
            }
        }
        _breadcrumb.Children.Add(crumbs);
    }

    // Back/forward walk the breadcrumb chain — a real navigation history
    // is tracked in PARITY (WIN-051); this gives the buttons honest
    // behavior today: back = parent, forward = last-drilled child.
    private readonly List<int> _drillHistory = new();
    private int _historyIndex = -1;

    private void StepBack()
    {
        var tree = Model.Tree;
        if (tree is null) return;
        if (_historyIndex > 0)
        {
            _historyIndex--;
            Model.DrillToAncestor(_drillHistory[_historyIndex]);
        }
        else
        {
            int parent = tree.Parent[Model.ZoomedNode];
            if (parent >= 0) Model.DrillToAncestor(parent);
        }
    }

    private void StepForward()
    {
        if (_historyIndex >= 0 && _historyIndex < _drillHistory.Count - 1)
        {
            _historyIndex++;
            Model.DrillToAncestor(_drillHistory[_historyIndex]);
            return;
        }
        // No forward entry: drill into the largest child folder.
        var tree = Model.Tree;
        if (tree is null) return;
        var biggest = tree.ChildrenOf(Model.ZoomedNode, Model.Totals)
            .Where(c => tree.IsDirectory[c.Id])
            .OrderByDescending(c => c.Size)
            .Select(c => (int?)c.Id)
            .FirstOrDefault();
        if (biggest is { } childId) Model.DrillTo(childId);
    }

    private void RefreshHeaderCard()
    {
        _headerCard.Children.Clear();
        if (_statusText is not null)
        {
            _statusText.Text = Model.Tree is null || Model.IsScanning
                ? (Model.IsScanning ? $"Scanning… {Model.ScanProgress:N0} items" : "No scan yet — pick a folder to explore")
                : $"Scan completed · {Model.Counts.Files[0]:N0} files · {Model.Counts.Folders[0]:N0} folders";
        }

        var tree = Model.Tree;
        if (tree is null || Model.Totals.Length != tree.Count)
        {
            _headerCard.Children.Add(Ui.EmptyState(Icons.Visualize, "Nothing to visualize",
                "Scan a folder or drive to build your storage map.",
                Ui.Button("Scan Folder…", Icons.Add, Ui.ButtonStyle.Primary,
                    () => Model.ShowPage("Overview"))));
            return;
        }
        int zoom = Model.ZoomedNode;
        var totals = Model.Totals;

        var cardBody = new StackPanel();
        var top = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };
        var folderIcon = Ui.IconTile(Icons.Folder, 40, Ui.Brush("AppAccentSoft"), Ui.Brush("AppAccent"), 9);
        DockPanel.SetDock(folderIcon, Dock.Left);
        var text = new StackPanel { Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        string name;
        if (zoom == 0 && Model.RootPath is { } rp)
        {
            // Root: folder name, or the drive label for a drive root.
            string trimmed = rp.TrimEnd('\\', '/');
            name = trimmed.Contains('\\')
                ? trimmed[(trimmed.LastIndexOf('\\') + 1)..]
                : trimmed;
        }
        else
        {
            name = tree.NameOf(zoom);
        }
        text.Children.Add(Ui.T(name, 16, FontWeights.SemiBold));
        long size = totals[zoom];
        int items = zoom < Model.Counts.Files.Length
            ? Model.Counts.Files[zoom] + Model.Counts.Folders[zoom] : 0;
        string modified = tree.ModifiedDay[zoom] > 0 ? $" · modified {Ui.RelativeDay(tree.ModifiedDay[zoom])}" : "";
        text.Children.Add(Ui.Subtle(
            $"{ByteFormat.Format(size)} · {items:N0} items{modified}", 11.5));
        top.Children.Add(folderIcon);
        top.Children.Add(text);
        cardBody.Children.Add(top);

        var breakdown = FileTypes.TypeBreakdown(tree, totals, zoom)
            .Where(kv => kv.Value > 0).OrderByDescending(kv => kv.Value).ToList();
        if (breakdown.Count > 0)
        {
            var parts = breakdown.Take(6)
                .Select(kv => (FileTypes.LabelOf(kv.Key), kv.Value, Ui.Hex(FileTypes.TileColorOf(kv.Key))))
                .ToList();
            cardBody.Children.Add(Ui.TypeBarWithLegend(parts, breakdown.Sum(kv => kv.Value)));
        }
        _headerCard.Children.Add(Ui.Card(cardBody, 14, new Thickness(0, 0, 0, 10)));
    }

    private void RefreshChart()
    {
        string mode = Model.VisualizeMode;
        FrameworkElement next = mode switch
        {
            "Sunburst" => new SunburstControl(),
            "Flame" => new ScrollViewer { Content = new FlameControl { MinHeight = 400 }, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
            "Bubbles" => new BubblesControl(),
            "Mind Map" => new ScrollViewer { Content = new MindMapControl { MinHeight = 400 }, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
            "Age Map" => new ScrollViewer { Content = BuildAgeMapList(), VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
            "Top Sizes" => new ScrollViewer { Content = BuildTopSizesList(), VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
            "Folders" => new ScrollViewer { Content = BuildFoldersList(), VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
            _ => new TreemapControl(),
        };
        _zoom = 1.0;
        _zoomLabel.Text = "100%";
        _chart = next;
        _chartClip.Children.Clear();
        _chartClip.Children.Add(next);
    }

    private UIElement BuildZoomBar()
    {
        var bar = new DockPanel { Margin = new Thickness(4, 0, 4, 10) };
        var minus = Ui.Button("−", null, Ui.ButtonStyle.Outline, () => SetZoom(_zoom / 1.25));
        minus.Padding = new Thickness(10, 2, 10, 2);
        var plus = Ui.Button("+", null, Ui.ButtonStyle.Outline, () => SetZoom(_zoom * 1.25));
        plus.Padding = new Thickness(10, 2, 10, 2);
        plus.Margin = new Thickness(4, 0, 0, 0);
        var fit = Ui.Button("Fit to view", null, Ui.ButtonStyle.Ghost, () => SetZoom(1.0));
        DockPanel.SetDock(minus, Dock.Left);
        DockPanel.SetDock(plus, Dock.Left);
        var leftGroup = new StackPanel { Orientation = Orientation.Horizontal };
        leftGroup.Children.Add(minus);
        leftGroup.Children.Add(plus);
        leftGroup.Children.Add(new Border { Width = 8 });
        leftGroup.Children.Add(_zoomLabel);
        DockPanel.SetDock(leftGroup, Dock.Left);

        var right = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var count = Ui.Subtle("", 11.5);
        count.Name = "countText";
        _countText = count;
        right.Children.Add(count);
        right.Children.Add(new Border { Width = 10 });
        right.Children.Add(fit);
        DockPanel.SetDock(right, Dock.Right);

        bar.Children.Add(right);
        bar.Children.Add(leftGroup);
        return bar;
    }

    private TextBlock? _countText;

    private void SetZoom(double zoom)
    {
        _zoom = Math.Clamp(zoom, 0.25, 8.0);
        _zoomLabel.Text = $"{_zoom * 100:0}%";
        if (_chart is not null)
            _chart.RenderTransform = new ScaleTransform(_zoom, _zoom);
    }

    /// <summary>"Largest items in this folder" — 10 rows + view-all link.</summary>
    private void RefreshBelow()
    {
        _below.Children.Clear();
        var tree = Model.Tree;
        if (tree is null || Model.Totals.Length != tree.Count) return;
        int zoom = Model.ZoomedNode;
        var children = tree.ChildrenOf(zoom, Model.Totals)
            .OrderByDescending(c => c.Size).ToList();
        if (_countText is not null)
            _countText.Text = $"{children.Count:N0} items · {ByteFormat.Format(Model.Totals[zoom])}";
        if (children.Count == 0) return;

        var label = Ui.SectionLabel("Largest items in this folder");
        label.Margin = new Thickness(2, 0, 0, 6);
        _below.Children.Add(label);

        var table = new StackPanel();
        table.Children.Add(Ui.TableHeader(
            ("#", new GridLength(30), false),
            ("Name", new GridLength(1, GridUnitType.Star), false),
            ("Kind", new GridLength(100), false),
            ("Size", new GridLength(90), true),
            ("% of folder", new GridLength(90), true),
            ("Modified", new GridLength(110), false),
            ("", new GridLength(36), false)));
        int shown = Math.Min(10, children.Count);
        for (int i = 0; i < shown; i++)
        {
            table.Children.Add(ItemRow(tree, children[i], i + 1, Model.Totals[zoom]));
        }
        table.Children.Add(new Border
        {
            BorderBrush = Ui.Brush("AppCardBorder"), BorderThickness = new Thickness(0, 1, 0, 0),
            Margin = new Thickness(0, 6, 0, 0),
        });
        if (children.Count > shown)
        {
            var more = Ui.T($"View all {children.Count:N0} items →", 12, null, Ui.Brush("AppAccent"));
            more.Margin = new Thickness(0, 8, 0, 0);
            more.Cursor = System.Windows.Input.Cursors.Hand;
            more.MouseLeftButtonDown += (_, _) => Model.ShowPage("File Browser");
            table.Children.Add(more);
        }
        _below.Children.Add(Ui.Card(table, 12, new Thickness(0)));
    }

    private UIElement ItemRow(FileTree tree, (int Id, long Size) item, int rank, long parentSize)
    {
        var row = Ui.TableRowGrid(
            new GridLength(30), new GridLength(1, GridUnitType.Star), new GridLength(100),
            new GridLength(90), new GridLength(90), new GridLength(110), new GridLength(36));
        row.Children.Insert(0, new Border { CornerRadius = new CornerRadius(6) }); // selection bg placeholder
        string kind = FileTypes.KindOf(tree, item.Id);
        var cat = FileTypes.Categories.FirstOrDefault(c => c.Id == kind);
        bool isDir = tree.IsDirectory[item.Id];

        Ui.Cell(row, Ui.Faint(rank.ToString()), 0);
        var nameCell = Ui.NameCell(
            Icons.ForKind(kind),
            isDir ? Ui.Brush("AppAccentSoft") : Ui.Hex(cat?.BadgeBackground ?? "#F1F5F9"),
            isDir ? Ui.Brush("AppAccent") : Ui.Hex(cat?.BadgeForeground ?? "#475569"),
            tree.NameOf(item.Id), isDir ? null : Model.DisplayPath(item.Id), 26);
        Ui.Cell(row, nameCell, 1);
        Ui.Cell(row, Ui.KindBadge(kind), 2);
        Ui.Cell(row, Ui.T(ByteFormat.Format(item.Size), 12), 3, right: true);
        double pct = parentSize > 0 ? 100.0 * item.Size / parentSize : 0;
        Ui.Cell(row, Ui.T($"{pct:0.0}%", 12), 4, right: true);
        Ui.Cell(row, Ui.Subtle(Ui.RelativeDay(tree.ModifiedDay[item.Id]), 11.5), 5);
        Ui.Cell(row, Ui.MoreButton(() => Model.Select(item.Id)), 6, right: true);

        row.Cursor = System.Windows.Input.Cursors.Hand;
        int captured = item.Id;
        row.MouseLeftButtonDown += (_, e) =>
        {
            if (e.ClickCount >= 2 && isDir) Model.DrillTo(captured);
            else Model.Select(captured);
        };
        return row;
    }

    // ---- List modes hosted inside the chart area ----

    private UIElement BuildAgeMapList()
    {
        var panel = new StackPanel { Margin = new Thickness(16) };
        var tree = Model.Tree;
        if (tree is null) return panel;
        var totals = Model.Totals;
        int today = AgeMap.Today();
        var buckets = AgeMap.BucketSizes(tree, totals, today);
        long max = buckets.Count > 0 ? Math.Max(1, buckets.Values.Max()) : 1;
        foreach (var bucket in Enum.GetValues<AgeBucket>())
        {
            if (!buckets.TryGetValue(bucket, out long size) || size <= 0) continue;
            var row = new DockPanel { Margin = new Thickness(0, 4, 0, 4) };
            row.Children.Add(Ui.T(AgeMap.Title(bucket), 12.5, FontWeights.Medium));
            var sizeText = Ui.T(ByteFormat.Format(size), 12);
            DockPanel.SetDock(sizeText, Dock.Right);
            var bar = Ui.Bar((double)size / max, Ui.Hex(FileTypes.TileColorOf("archive")), 10, 0);
            bar.Width = double.NaN;
            bar.Margin = new Thickness(12, 0, 12, 0);
            row.Children.Add(sizeText);
            row.Children.Add(bar);
            panel.Children.Add(row);
        }
        return panel;
    }

    private UIElement BuildTopSizesList()
    {
        var panel = new StackPanel { Margin = new Thickness(16) };
        var tree = Model.Tree;
        if (tree is null) return panel;
        var ranked = TopSizes.Ranked(Model.Totals, 100);
        int i = 0;
        foreach (var id in ranked)
        {
            i++;
            var row = new DockPanel { Margin = new Thickness(0, 3, 0, 3) };
            var kind = FileTypes.KindOf(tree, id);
            var cat = FileTypes.Categories.FirstOrDefault(c => c.Id == kind);
            bool isDir = tree.IsDirectory[id];
            var name = Ui.NameCell(Icons.ForKind(kind),
                isDir ? Ui.Brush("AppAccentSoft") : Ui.Hex(cat?.BadgeBackground ?? "#F1F5F9"),
                isDir ? Ui.Brush("AppAccent") : Ui.Hex(cat?.BadgeForeground ?? "#475569"),
                tree.NameOf(id), Model.DisplayPath(id), 24);
            var size = Ui.T(ByteFormat.Format(Model.Totals[id]), 12);
            DockPanel.SetDock(size, Dock.Right);
            row.Children.Add(size);
            row.Children.Add(name);
            int captured = id;
            row.Cursor = System.Windows.Input.Cursors.Hand;
            row.MouseLeftButtonDown += (_, e) =>
            {
                if (e.ClickCount >= 2 && isDir) Model.DrillTo(captured);
                else Model.Select(captured);
            };
            panel.Children.Add(row);
        }
        return panel;
    }

    private UIElement BuildFoldersList()
    {
        var panel = new StackPanel { Margin = new Thickness(16) };
        var tree = Model.Tree;
        if (tree is null) return panel;
        var children = tree.ChildrenOf(Model.ZoomedNode, Model.Totals)
            .Where(c => tree.IsDirectory[c.Id]).OrderByDescending(c => c.Size).ToList();
        long max = children.Count > 0 ? Math.Max(1, children.Max(c => c.Size)) : 1;
        foreach (var (id, size) in children.Take(200))
        {
            var row = new DockPanel { Margin = new Thickness(0, 4, 0, 4) };
            var name = Ui.NameCell(Icons.Folder, Ui.Brush("AppAccentSoft"), Ui.Brush("AppAccent"),
                tree.NameOf(id), null, 24);
            var sizeText = Ui.T(ByteFormat.Format(size), 12);
            DockPanel.SetDock(sizeText, Dock.Right);
            var bar = Ui.Bar((double)size / max, Ui.Brush("AppAccent"), 8, 200);
            bar.HorizontalAlignment = HorizontalAlignment.Right;
            bar.Margin = new Thickness(12, 0, 12, 0);
            DockPanel.SetDock(bar, Dock.Right);
            row.Children.Add(sizeText);
            row.Children.Add(bar);
            row.Children.Add(name);
            int captured = id;
            row.Cursor = System.Windows.Input.Cursors.Hand;
            row.MouseLeftButtonDown += (_, e) =>
            {
                if (e.ClickCount >= 2) Model.DrillTo(captured);
                else Model.Select(captured);
            };
            panel.Children.Add(row);
        }
        return panel;
    }
}
