using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using DiskMap.Core;

namespace DiskMap.App.Pages;

/// <summary>
/// Shared helper for the list-style pages: a vertical stack with a header
/// row, content area, and refresh on state changes (while on screen —
/// see <see cref="ModelEvents"/>).
/// </summary>
public abstract class ListPage : UserControl
{
    protected ScanModel Model => ScanModel.Shared;
    protected readonly StackPanel Root = new() { Margin = new Thickness(24, 20, 24, 20) };

    /// <summary>Secondary-text brush, follows the theme palette.</summary>
    protected static Brush Subtle => Ui.Brush("AppSubtle");

    private int _generation;

    protected ListPage()
    {
        Content = new ScrollViewer { Content = Root, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        ModelEvents.WhileLoaded(this, Refresh);
    }

    protected abstract void Refresh();

    /// <summary>
    /// Runs <paramref name="work"/> (anything proportional to the tree) on
    /// a worker thread, then <paramref name="show"/> on the UI thread —
    /// unless a newer refresh started meanwhile.
    /// </summary>
    protected async void Compute<T>(Func<T> work, Action<T> show)
    {
        int generation = ++_generation;
        T result;
        try
        {
            result = await Task.Run(work);
        }
        catch (Exception ex)
        {
            if (generation == _generation) Root.Children.Add(new TextBlock { Text = $"Failed: {ex.Message}", Foreground = Subtle });
            return;
        }
        if (generation == _generation) show(result);
    }

    protected static TextBlock Working(string text) => new() { Text = text, Foreground = Subtle };

    /// <summary>
    /// Page header (§17 anatomy): a mono eyebrow for the nav group, the
    /// 20 pt semibold title, the subtitle, an optional mono stat right.
    /// The legacy icon params are accepted and ignored — no icon tiles.
    /// </summary>
    protected DockPanel Header(string title, string subtitle, string? rightStat = null,
        string? glyph = null, Brush? iconBg = null, Brush? iconFg = null)
    {
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 14) };
        if (rightStat is not null)
        {
            var stat = Ui.Mono(rightStat, 11, null, Ui.Brush("AppFaint"));
            stat.VerticalAlignment = VerticalAlignment.Bottom;
            DockPanel.SetDock(stat, Dock.Right);
            header.Children.Add(stat);
        }
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        titles.Children.Add(Ui.MonoLabel(EyebrowFor(title), Ui.Brush("AppSubtle")));
        titles.Children.Add(Ui.PageTitle(title));
        titles.Children.Add(Ui.PageSubtitle(subtitle));
        header.Children.Add(titles);
        return header;
    }

    private static string EyebrowFor(string title) => title switch
    {
        "Overview" => "MAIN",
        "Biggest Files" or "Biggest Folders" or "Forgotten Files" or "Duplicates" => "FIND",
        "Safe to Review" or "Caches" or "Old Downloads" or "Large Media" or "Cleanup" => "CLEAN",
        "File Browser" or "Visualize" or "Developer Storage" or "Applications" or "Snapshots" => "EXPLORE",
        _ => title,
    };

    protected UIElement NeedsScan(string what)
    {
        return Ui.EmptyState(Icons.Folder, "Scan a folder to begin",
            $"{what} Once you pick a folder, DiskMap maps it in seconds.",
            Ui.Button("Scan Folder…", Icons.Add, Ui.ButtonStyle.Primary, () => Model.RequestScan()));
    }
}

/// <summary>
/// A ranked file/folder table — the shared body of Biggest Files,
/// Biggest Folders, Forgotten Files, Large Media, Old Downloads, File
/// Browser and Search: toolbar (name filter, kind pills, sort), the
/// mockup's column grid, and selection into the inspector.
/// </summary>
public abstract class FileListPage : ListPage
{
    private string _filterText = "";
    private string _kindFilter = "all";
    private string _sort = "largest";

    /// <summary>Candidate node ids for this page (already basis-aware).</summary>
    protected abstract List<int> Collect(FileTree tree, long[] totals, string rootPath);
    protected abstract string PageName { get; }
    protected abstract string PageBlurb { get; }
    protected abstract string PageIcon { get; }
    protected virtual Brush PageIconBg => Ui.Brush("AppAccentSoft");
    protected virtual Brush PageIconFg => Ui.Brush("AppAccent");
    protected virtual string Noun => "files";

    private readonly ContentControl _headerHost = new();
    private readonly ContentControl _heroHost = new();
    private readonly StackPanel _toolbar = new();
    private readonly StackPanel _table = new();
    private readonly ContentControl _bottomHost = new();
    private readonly HashSet<int> _checked = [];
    private List<int> _filtered = [];
    private readonly Dictionary<int, Border> _rowBorders = [];

    protected FileListPage()
    {
        Root.Children.Add(_headerHost);
        Root.Children.Add(_heroHost);
        Root.Children.Add(_toolbar);
        Root.Children.Add(_table);
        Root.Children.Add(_bottomHost);
    }

    /// <summary>Optional hero content (stat cards, breakdowns) between header and toolbar.</summary>
    protected virtual UIElement? Hero(FileTree tree, long[] totals, List<int> ids) => null;

    protected override void Refresh()
    {
        _headerHost.Content = null;
        _heroHost.Content = null;
        _toolbar.Children.Clear();
        _table.Children.Clear();
        _bottomHost.Content = null;
        var tree = Model.Tree;
        if (tree is null || Model.Totals.Length != tree.Count || Model.RootPath is not { } rootPath)
        {
            _table.Children.Add(NeedsScan(PageBlurb));
            return;
        }
        var totals = Model.Totals;
        _table.Children.Add(Working("Ranking…"));
        var filterText = _filterText;
        var kindFilter = _kindFilter;
        var sort = _sort;
        Compute(() => Collect(tree, totals, rootPath), ids =>
        {
            _table.Children.Clear();
            _rowBorders.Clear();
            var filtered = ApplyFilters(tree, totals, ids, filterText, kindFilter, sort);
            _filtered = filtered;
            _checked.IntersectWith(filtered);
            var hero = Hero(tree, totals, filtered);
            if (hero is not null) _heroHost.Content = hero;
            BuildToolbar(tree, totals, ids);
            long bytes = filtered.Sum(id => totals[id]);
            _headerHost.Content = Header(PageName, PageBlurb,
                $"Showing {filtered.Count:N0} {Noun} · Total {ByteFormat.Format(bytes)}",
                PageIcon, PageIconBg, PageIconFg);
            _table.Children.Add(BuildTable(tree, totals, filtered.Take(500).ToList(), rootPath));
            if (filtered.Count > 500)
                _table.Children.Add(Ui.Faint($"… and {filtered.Count - 500:N0} smaller {Noun} not shown"));
            PaintBottomBar();
        });
    }

    /// <summary>
    /// WIN-051: ↑/↓/j/k move the inspector selection through this page's
    /// rows — the shared list-navigation behavior from Keyboard.swift.
    /// Returns true when the key was consumed.
    /// </summary>
    public bool NavigateSelection(int delta)
    {
        if (_filtered.Count == 0) return false;
        int at = _filtered.IndexOf(Model.SelectedNode);
        int next = at < 0 ? (delta > 0 ? 0 : _filtered.Count - 1)
            : Math.Clamp(at + delta, 0, _filtered.Count - 1);
        int previous = Model.SelectedNode;
        Model.Select(_filtered[next]);
        // Repaint the two touched rows — no table rebuild.
        foreach (int touched in new[] { previous, _filtered[next] })
        {
            if (_rowBorders.TryGetValue(touched, out var b))
                b.Background = touched == Model.SelectedNode
                    ? Ui.Brush("AppRowSelected") : Brushes.Transparent;
        }
        return true;
    }

    /// <summary>Reveal/Open on Enter — dirs drill, files reveal in Explorer.</summary>
    public bool ActivateSelection()
    {
        var tree = Model.Tree;
        if (tree is null || Model.SelectedNode < 0 || Model.SelectedNode >= tree.Count) return false;
        int id = Model.SelectedNode;
        if (tree.IsDirectory[id]) { Model.DrillTo(id); Model.ShowPage("File Browser"); }
        else Explorer.Reveal(Model.PathOf(id));
        return true;
    }

    /// <summary>Delete/Ctrl+Backspace stages the selected row via this page's reason.</summary>
    public bool StageSelection()
    {
        if (Model.SelectedNode < 0) return false;
        if (!Model.Stage(Model.SelectedNode, PageName.ToLowerInvariant())) return false;
        Model.ShowPage("Cleanup");
        return true;
    }

    /// <summary>WIN-052: Ctrl+A checks every filtered row.</summary>
    public void SelectAll()
    {
        _checked.UnionWith(_filtered);
        PaintBottomBar();
        foreach (var cb in EnumerateCheckBoxes()) cb.IsChecked = true;
    }

    /// <summary>WIN-052: Esc clears the checked set.</summary>
    public void ClearChecked()
    {
        _checked.Clear();
        PaintBottomBar();
        foreach (var cb in EnumerateCheckBoxes()) cb.IsChecked = false;
    }

    private IEnumerable<CheckBox> EnumerateCheckBoxes()
    {
        foreach (var border in _table.Children.OfType<Border>())
            if (border.Child is Grid row && row.Children.OfType<CheckBox>().FirstOrDefault() is { } cb)
                yield return cb;
    }

    private void PaintSelected() { /* per-row closures handle hover; keyboard nav repaints via _rowBorders */ }

    /// <summary>The mockup's bottom bar: "N selected · X | Add to Cleanup Review | M files · Y".</summary>
    protected void PaintBottomBar()
    {
        var totals = Model.Totals;
        var selected = _filtered.Where(_checked.Contains).ToList();
        long selBytes = selected.Sum(id => totals[id]);
        long allBytes = _filtered.Sum(id => totals[id]);

        // Copy-paths multi-select: newline-joined list for whatever is
        // checked — one line per path, no shell quoting guesses.
        var right = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Center,
            Children =
            {
                Ui.Mono($"{_filtered.Count:N0} {Noun} · {ByteFormat.Format(allBytes)}", 11, null, Ui.Brush("AppSubtle")),
                new Border { Width = 14 },
                RescanLink(),
            },
        };
        if (selected.Count > 0)
        {
            var copy = Ui.T("Copy paths", 12, FontWeights.Medium, Ui.Brush("AppAccent"));
            copy.Cursor = System.Windows.Input.Cursors.Hand;
            copy.ToolTip = new ToolTip { Content = "Copy the selected paths, one per line" };
            copy.MouseLeftButtonDown += (_, _) =>
            {
                var paths = selected.Select(id => TreeExporter.QuotePathIfNeeded(Model.PathOf(id)));
                Clipboard.SetText(string.Join(Environment.NewLine, paths));
            };
            right.Children.Insert(0, copy);
            right.Children.Insert(1, new Border { Width = 14 });
        }

        _bottomHost.Content = Ui.BottomBar(
            Ui.Mono($"{selected.Count} selected · {ByteFormat.Format(selBytes)}", 12, FontWeights.Medium),
            right,
            Ui.Button("Add to Cleanup Review", Icons.Cleanup, Ui.ButtonStyle.Dark,
                () =>
                {
                    foreach (var id in selected) Model.Stage(id, PageName.ToLowerInvariant());
                    _checked.Clear();
                    PaintBottomBar();
                    Model.ShowPage("Cleanup");
                }));
    }

    private static UIElement RescanLink()
    {
        var link = Ui.T("Rescan", 12, FontWeights.Medium, Ui.Brush("AppAccent"));
        link.Cursor = System.Windows.Input.Cursors.Hand;
        link.MouseLeftButtonDown += async (_, _) => await ScanModel.Shared.RescanAsync();
        return link;
    }

    private void BuildToolbar(FileTree tree, long[] totals, List<int> ids)
    {
        var kinds = ids.Select(id => FileTypes.KindOf(tree, id))
            .GroupBy(k => k).OrderByDescending(g => g.Count()).Select(g => g.Key)
            .Where(k => k != FileTypes.FolderId).Take(6).ToList();

        var row = new WrapPanel { Margin = new Thickness(0, 0, 0, 10) };
        var (box, input) = Ui.SearchBox("Search by name or path…", 260);
        input.Text = _filterText;
        input.TextChanged += (_, _) =>
        {
            _filterText = input.Text;
            RefreshTableOnly(tree, totals, ids);
        };
        row.Children.Add(new Border { Margin = new Thickness(0, 0, 10, 4), Child = box });

        var pills = new List<(string Id, string Label)> { ("all", $"All {Noun}") };
        pills.AddRange(kinds.Select(k => (k, FileTypes.LabelOf(k))));
        foreach (var (id, label) in pills)
        {
            var pill = Ui.Pill(label, _kindFilter == id, () =>
            {
                _kindFilter = id;
                RefreshTableOnly(tree, totals, ids);
            });
            pill.Margin = new Thickness(0, 0, 6, 4);
            row.Children.Add(pill);
        }

        var sort = new ComboBox { Width = 130, Margin = new Thickness(4, 0, 0, 4), VerticalAlignment = VerticalAlignment.Center };
        foreach (var (id, label) in new[]
        {
            ("largest", "Sort: Largest"), ("smallest", "Sort: Smallest"),
            ("name", "Sort: Name"), ("oldest", "Sort: Oldest"), ("newest", "Sort: Newest"),
        })
        {
            var item = new ComboBoxItem { Content = label, Tag = id };
            sort.Items.Add(item);
            if (id == _sort) sort.SelectedItem = item;
        }
        sort.SelectionChanged += (_, _) =>
        {
            _sort = (sort.SelectedItem as ComboBoxItem)?.Tag as string ?? "largest";
            RefreshTableOnly(tree, totals, ids);
        };
        row.Children.Add(sort);
        _toolbar.Children.Add(row);
    }

    private void RefreshTableOnly(FileTree tree, long[] totals, List<int> ids)
    {
        // Rebuild just the table region: header and toolbar stay.
        var filtered = ApplyFilters(tree, totals, ids, _filterText, _kindFilter, _sort);
        _filtered = filtered;
        _checked.IntersectWith(filtered);
        _table.Children.Clear();
        _table.Children.Add(BuildTable(tree, totals, filtered.Take(500).ToList(), Model.RootPath ?? ""));
        if (filtered.Count > 500)
            _table.Children.Add(Ui.Faint($"… and {filtered.Count - 500:N0} smaller {Noun} not shown"));
        PaintBottomBar();
    }

    private List<int> ApplyFilters(FileTree tree, long[] totals, List<int> ids,
        string filterText, string kindFilter, string sort)
    {
        IEnumerable<int> q = ids;
        if (kindFilter != "all")
            q = q.Where(id => FileTypes.KindOf(tree, id) == kindFilter);
        if (filterText.Trim().Length > 0)
        {
            string needle = filterText.Trim();
            q = q.Where(id => tree.NameOf(id).Contains(needle, StringComparison.OrdinalIgnoreCase)
                || Model.DisplayPath(id).Contains(needle, StringComparison.OrdinalIgnoreCase));
        }
        q = sort switch
        {
            "smallest" => q.OrderBy(id => totals[id]),
            "name" => q.OrderBy(id => tree.NameOf(id), StringComparer.OrdinalIgnoreCase),
            "oldest" => q.OrderBy(id => tree.ModifiedDay[id] == 0 ? int.MaxValue : tree.ModifiedDay[id]),
            "newest" => q.OrderByDescending(id => tree.ModifiedDay[id]),
            _ => q.OrderByDescending(id => totals[id]),
        };
        return q.ToList();
    }

    /// <summary>The reference table: ☑, #, name cell, type badge, modified, size, ⋯.</summary>
    protected UIElement BuildTable(FileTree tree, long[] totals, List<int> ids, string rootPath)
    {
        var table = new StackPanel();
        var headerRow = Ui.TableRowGrid(
            new GridLength(30), new GridLength(30), new GridLength(1, GridUnitType.Star),
            new GridLength(110), new GridLength(110), new GridLength(90), new GridLength(36));
        headerRow.Margin = new Thickness(0, 0, 0, 8);
        var selectAll = new CheckBox
        {
            VerticalAlignment = VerticalAlignment.Center,
            IsChecked = ids.Count > 0 && ids.All(_checked.Contains),
        };
        selectAll.Checked += (_, _) =>
        {
            foreach (var i in _filtered) _checked.Add(i);
            RebuildRows();
            PaintBottomBar();
        };
        selectAll.Unchecked += (_, _) =>
        {
            _checked.Clear();
            RebuildRows();
            PaintBottomBar();
        };
        Ui.Cell(headerRow, selectAll, 0);
        Ui.Cell(headerRow, Ui.Mono("#", 10, null, Ui.Brush("AppFaint")), 1);
        Ui.Cell(headerRow, Ui.TableHead("Name"), 2);
        Ui.Cell(headerRow, Ui.TableHead("Type"), 3);
        Ui.Cell(headerRow, Ui.TableHead("Modified"), 4);
        Ui.Cell(headerRow, Ui.TableHead("Size"), 5, right: true);
        table.Children.Add(headerRow);
        table.Children.Add(Ui.Hairline());

        _rowsHost = new StackPanel();
        for (int i = 0; i < ids.Count; i++)
        {
            if (i > 0) _rowsHost.Children.Add(Ui.Hairline());
            _rowsHost.Children.Add(FileRow(tree, totals, ids[i], i + 1, rootPath));
        }
        if (ids.Count == 0)
            _rowsHost.Children.Add(Ui.Subtle("Nothing matches these filters."));
        _rowsHost.Tag = (tree, ids, rootPath);
        table.Children.Add(_rowsHost);
        return table;
    }

    private StackPanel? _rowsHost;

    /// <summary>Re-render the row stack in place — used when select-all toggles.</summary>
    private void RebuildRows()
    {
        if (_rowsHost?.Tag is not (FileTree tree, List<int> ids, string rootPath)) return;
        var totals = Model.Totals;
        _rowsHost.Children.Clear();
        for (int i = 0; i < ids.Count; i++)
        {
            if (i > 0) _rowsHost.Children.Add(Ui.Hairline());
            _rowsHost.Children.Add(FileRow(tree, totals, ids[i], i + 1, rootPath));
        }
    }

    private UIElement FileRow(FileTree tree, long[] totals, int id, int rank, string rootPath)
    {
        string kind = FileTypes.KindOf(tree, id);
        var cat = FileTypes.Categories.FirstOrDefault(c => c.Id == kind);
        bool isDir = tree.IsDirectory[id];

        var outer = new Border { CornerRadius = new CornerRadius(6), Background = Brushes.Transparent };
        _rowBorders[id] = outer;
        var row = Ui.TableRowGrid(
            new GridLength(30), new GridLength(30), new GridLength(1, GridUnitType.Star),
            new GridLength(110), new GridLength(110), new GridLength(90), new GridLength(36));
        outer.Child = row;
        void PaintSelected() => outer.Background =
            Model.SelectedNode == id ? Ui.Brush("AppRowSelected") : Brushes.Transparent;
        PaintSelected();

        var check = new CheckBox { IsChecked = _checked.Contains(id), VerticalAlignment = VerticalAlignment.Center };
        check.Checked += (_, _) => { _checked.Add(id); PaintBottomBar(); };
        check.Unchecked += (_, _) => { _checked.Remove(id); PaintBottomBar(); };
        Ui.Cell(row, check, 0);
        Ui.Cell(row, Ui.Mono(rank.ToString(), 10, null, Ui.Brush("AppFaint")), 1);
        // WIN-046: cloud-only rows get the glyph — the bytes sit online,
        // and Reveal would recall the content.
        bool cloud = (tree.Flags[id] & NodeFlags.NotDownloaded) != 0;
        var nameCell = Ui.NameCell(
            cloud ? "☁" : Icons.ForKind(kind),
            cloud ? Ui.Hex("#E0F2FE")
                : isDir ? Ui.Brush("AppAccentSoft") : Ui.Hex(cat?.BadgeBackground ?? "#F1F5F9"),
            cloud ? Ui.Hex("#0284C7")
                : isDir ? Ui.Brush("AppAccent") : Ui.Hex(cat?.BadgeForeground ?? "#475569"),
            tree.NameOf(id),
            cloud
                ? $"{Model.DisplayPath(id)}  ·  cloud-only — opening downloads it"
                : Model.DisplayPath(id), 26);
        Ui.Cell(row, nameCell, 2);
        Ui.Cell(row, Ui.KindBadge(kind), 3);
        Ui.Cell(row, Ui.Mono(Ui.RelativeDay(tree.ModifiedDay[id]), 11, null, Ui.Brush("AppSubtle")), 4);
        Ui.Cell(row, Ui.Mono(ByteFormat.Format(totals[id]), 12), 5, right: true);
        Ui.Cell(row, Ui.MoreButton(() => OpenRowMenu(outer, tree, id)), 6, right: true);

        outer.Cursor = System.Windows.Input.Cursors.Hand;
        outer.MouseLeftButtonDown += (_, e) =>
        {
            if (e.ClickCount >= 2)
            {
                // Double-click: dirs drill, files reveal in Explorer —
                // the macOS FindView open-on-double-click behavior.
                if (isDir) { Model.DrillTo(id); Model.ShowPage("File Browser"); }
                else Explorer.Reveal(Model.PathOf(id));
            }
            else { Model.Select(id); PaintSelected(); }
        };
        outer.MouseEnter += (_, _) => { if (Model.SelectedNode != id) outer.Background = Ui.Brush("AppHover"); };
        outer.MouseLeave += (_, _) => PaintSelected();
        return outer;
    }

    private void OpenRowMenu(UIElement anchor, FileTree tree, int id)
    {
        Model.Select(id);
        string path = Model.PathOf(id);
        var menu = new ContextMenu();
        var reveal = new MenuItem { Header = "Reveal in Explorer" };
        reveal.Click += (_, _) => Explorer.Reveal(path);
        menu.Items.Add(reveal);
        var copy = new MenuItem { Header = "Copy Path" };
        copy.Click += (_, _) => Clipboard.SetText(path);
        menu.Items.Add(copy);
        if (tree.IsDirectory[id])
        {
            var vis = new MenuItem { Header = "Visualize this folder" };
            vis.Click += (_, _) => Model.Visualize(id);
            menu.Items.Add(vis);
        }
        else
        {
            // Show-in-map: the file's parent folder in Visualize, selected.
            var show = new MenuItem { Header = "Show in Visualize" };
            int parent = tree.Parent[id];
            show.Click += (_, _) =>
            {
                if (parent >= 0) Model.DrillTo(parent);
                Model.Select(id);
                Model.ShowPage("Visualize");
            };
            menu.Items.Add(show);
        }
        menu.Items.Add(new Separator());
        var stage = new MenuItem { Header = "Add to Cleanup" };
        stage.Click += (_, _) => Model.Stage(id, PageName.ToLowerInvariant());
        menu.Items.Add(stage);
        menu.PlacementTarget = anchor;
        menu.IsOpen = true;
    }
}

/// <summary>Biggest Files — ranked individual files, folders excluded.</summary>
public sealed class BiggestFilesPage : FileListPage
{
    protected override string PageName => "Biggest Files";
    protected override string PageIcon => Icons.BiggestFiles;
    protected override string PageBlurb =>
        "The largest individual files using storage on this drive. Folders are not shown here.";
    protected override List<int> Collect(FileTree tree, long[] totals, string rootPath) =>
        TopSizes.Largest(1, tree.Count, 5000, id => totals[id],
            id => !tree.IsDirectory[id] && totals[id] > 0);
}

/// <summary>Biggest Folders — ranked directories by subtree total.</summary>
public sealed class BiggestFoldersPage : FileListPage
{
    protected override string PageName => "Biggest Folders";
    protected override string PageIcon => Icons.BiggestFolders;
    protected override Brush PageIconBg => Ui.Hex("#FEF3DE");
    protected override Brush PageIconFg => Ui.Hex("#B45309");
    protected override string PageBlurb =>
        "The largest folders by total size, including everything inside them.";
    protected override string Noun => "folders";
    protected override List<int> Collect(FileTree tree, long[] totals, string rootPath) =>
        TopSizes.Largest(1, tree.Count, 3000, id => totals[id],
            id => tree.IsDirectory[id] && totals[id] > 0);
}

/// <summary>Forgotten Files — large files untouched for over a year.</summary>
public sealed class ForgottenFilesPage : FileListPage
{
    protected override string PageName => "Forgotten Files";
    protected override string PageIcon => Icons.Forgotten;
    protected override Brush PageIconBg => Ui.Hex("#FEF3DE");
    protected override Brush PageIconFg => Ui.Hex("#B45309");
    protected override string PageBlurb =>
        "Large files you haven't touched in over a year — the best candidates to review.";

    /// <summary>WIN-045: a clicked age band filters the list; null = all.</summary>
    private AgeBucket? _band;

    protected override List<int> Collect(FileTree tree, long[] totals, string rootPath)
    {
        int today = AgeMap.Today();
        var ids = AgeMap.Untouched(tree, totals, today, limit: 1000);
        if (_band is { } band)
            ids = ids.Where(id => AgeMap.Bucket(tree.ModifiedDay[id], today) == band).ToList();
        return ids;
    }

    /// <summary>Stat cards + segmented age bar, like the mockup.</summary>
    protected override UIElement? Hero(FileTree tree, long[] totals, List<int> ids)
    {
        int today = AgeMap.Today();
        var bucketBytes = new Dictionary<AgeBucket, long>();
        foreach (var id in ids)
        {
            var b = AgeMap.Bucket(tree.ModifiedDay[id], today);
            bucketBytes[b] = bucketBytes.GetValueOrDefault(b) + totals[id];
        }
        long total = ids.Sum(id => totals[id]);
        long year1 = ids.Where(id => today - tree.ModifiedDay[id] > 365).Sum(id => totals[id]);
        long year2 = ids.Where(id => today - tree.ModifiedDay[id] > 2 * 365).Sum(id => totals[id]);
        long big = ids.Where(id => totals[id] >= 1_000_000_000).Sum(id => totals[id]);

        var stats = Ui.StatRow(
            Ui.StatCard(Icons.Forgotten, Ui.Hex("#FEF3DE"), Ui.Hex("#B45309"),
                ByteFormat.Format(total), $"Reviewable · {ids.Count:N0} files"),
            Ui.StatCard(Icons.Forgotten, Ui.Hex("#FDECEC"), Ui.Hex("#DC2626"),
                ByteFormat.Format(year1), "Over a year untouched"),
            Ui.StatCard(Icons.Forgotten, Ui.Hex("#F3E8FF"), Ui.Hex("#7C3AED"),
                ByteFormat.Format(year2), "Over two years"),
            Ui.StatCard(Icons.BiggestFiles, Ui.Brush("AppAccentSoft"), Ui.Brush("AppAccent"),
                ByteFormat.Format(big), "In files over 1 GB"));

        var order = new[] { AgeBucket.OneToTwoYears, AgeBucket.OverTwoYears };
        var colors = new Dictionary<AgeBucket, Brush>
        {
            [AgeBucket.Under30] = Ui.Hex("#4ADE80"), [AgeBucket.Days30To90] = Ui.Hex("#86EFAC"),
            [AgeBucket.Days90To365] = Ui.Hex("#FDE68A"), [AgeBucket.OneToTwoYears] = Ui.Hex("#F0A95F"),
            [AgeBucket.OverTwoYears] = Ui.Hex("#DC2626"), [AgeBucket.Unknown] = Ui.Brush("AppBarTrack"),
        };
        var present = order.Where(b => bucketBytes.GetValueOrDefault(b) > 0).ToList();
        long barTotal = Math.Max(1, present.Sum(b => bucketBytes[b]));
        var barCard = new StackPanel();
        barCard.Children.Add(Ui.T("Forgotten files by age", 13, FontWeights.SemiBold));
        barCard.Children.Add(new Border { Height = 8 });
        barCard.Children.Add(Ui.Segmented(
            present.Select(b => ((double)bucketBytes[b] / barTotal, colors[b])).ToList(), 10));
        barCard.Children.Add(new Border { Height = 8 });
        // WIN-045: legend dots are the filter — click a band to list just
        // those files; the active band shows as selected.
        var legend = new WrapPanel();
        foreach (var b in present)
        {
            bool on = _band == b;
            var dot = Ui.LegendDot(colors[b],
                $"{(on ? "• " : "")}{AgeMap.Title(b)}  {ByteFormat.Format(bucketBytes[b])} ({bucketBytes[b] * 100 / barTotal}%)");
            dot.Cursor = System.Windows.Input.Cursors.Hand;
            if (dot.Children.Count > 1 && dot.Children[1] is TextBlock tb)
                tb.FontWeight = on ? FontWeights.SemiBold : FontWeights.Normal;
            var captured = b;
            dot.ToolTip = new ToolTip { Content = on ? "Show all bands" : "Show only this band" };
            dot.MouseLeftButtonDown += (_, _) =>
            {
                _band = on ? null : captured;
                Refresh();
            };
            legend.Children.Add(dot);
        }
        if (_band is not null)
        {
            var clear = Ui.Pill("Clear age filter ×", false, () => { _band = null; Refresh(); });
            clear.Margin = new Thickness(0, 0, 0, 2);
            legend.Children.Add(clear);
        }
        barCard.Children.Add(legend);

        var wrap = new StackPanel();
        wrap.Children.Add(stats);
        wrap.Children.Add(Ui.Card(barCard, 14));
        return wrap;
    }
}

/// <summary>Large Media — video, audio and image files over 100 MB.</summary>
public sealed class LargeMediaPage : FileListPage
{
    private const long MinBytes = 100L * 1000 * 1000;
    private static readonly HashSet<string> MediaKinds = new(StringComparer.Ordinal)
        { "video", "audio", "image" };

    protected override string PageName => "Large Media";
    protected override string PageIcon => Icons.Media;
    protected override Brush PageIconBg => Ui.Hex("#F3E8FF");
    protected override Brush PageIconFg => Ui.Hex("#7C3AED");
    protected override string PageBlurb =>
        "Find the videos, photos and audio using the most space on this drive. Nothing is deleted automatically.";
    protected override List<int> Collect(FileTree tree, long[] totals, string rootPath) =>
        TopSizes.Largest(1, tree.Count, 3000, id => totals[id],
            id => !tree.IsDirectory[id] && totals[id] >= MinBytes
                && MediaKinds.Contains(FileTypes.KindOfFile(tree.NameOf(id))));

    protected override UIElement? Hero(FileTree tree, long[] totals, List<int> ids)
    {
        long total = ids.Sum(id => totals[id]);
        var byKind = ids.GroupBy(id => FileTypes.KindOfFile(tree.NameOf(id)))
            .ToDictionary(g => g.Key, g => (Bytes: g.Sum(i => totals[i]), Count: g.Count()));
        long Video(string k) => byKind.GetValueOrDefault(k).Bytes;
        int Count(string k) => byKind.GetValueOrDefault(k).Count;

        var stats = Ui.StatRow(
            Ui.StatCard(Icons.Media, Ui.Hex("#F3E8FF"), Ui.Hex("#7C3AED"),
                ByteFormat.Format(total), "Media storage", $"in {ids.Count:N0} files"),
            Ui.StatCard(Icons.Media, Ui.Hex("#FDECEC"), Ui.Hex("#DC2626"),
                ByteFormat.Format(Video("video")), "Video files", $"in {Count("video"):N0} files"),
            Ui.StatCard(Icons.Image, Ui.Hex("#E8F6EE"), Ui.Hex("#16A34A"),
                ByteFormat.Format(Video("image")), "Images & photos", $"in {Count("image"):N0} files"),
            Ui.StatCard(Icons.Audio, Ui.Hex("#EAF1FE"), Ui.Hex("#2563EB"),
                ByteFormat.Format(Video("audio")), "Audio files", $"in {Count("audio"):N0} files"));

        // Breakdown cards: by type | age.
        var byType = new StackPanel();
        byType.Children.Add(Ui.T("Media storage by type", 13, FontWeights.SemiBold));
        var kindColors = new Dictionary<string, Brush>
        {
            ["video"] = Ui.Hex("#F472B6"), ["image"] = Ui.Hex("#4ADE80"),
            ["audio"] = Ui.Hex("#818CF8"), ["other"] = Ui.Brush("AppBarTrack"),
        };
        foreach (var kv in byKind.OrderByDescending(k => k.Value.Bytes).Take(5))
        {
            long bytes = kv.Value.Bytes;
            byType.Children.Add(Ui.DotRow(kindColors.GetValueOrDefault(kv.Key, Ui.Brush("AppBarTrack")),
                FileTypes.LabelOf(kv.Key),
                $"{ByteFormat.Format(bytes)} ({bytes * 100 / Math.Max(1, total):0.0}%)",
                (double)bytes / Math.Max(1, total)));
        }
        var age = new StackPanel();
        age.Children.Add(Ui.T("Age distribution", 13, FontWeights.SemiBold));
        int today = AgeMap.Today();
        var ageBytes = new Dictionary<AgeBucket, long>();
        foreach (var id in ids)
        {
            var b = AgeMap.Bucket(tree.ModifiedDay[id], today);
            ageBytes[b] = ageBytes.GetValueOrDefault(b) + totals[id];
        }
        var ageColors = new Dictionary<AgeBucket, Brush>
        {
            [AgeBucket.Under30] = Ui.Hex("#60A5FA"), [AgeBucket.Days30To90] = Ui.Hex("#93C5FD"),
            [AgeBucket.Days90To365] = Ui.Hex("#F0A95F"), [AgeBucket.OneToTwoYears] = Ui.Hex("#A78BFA"),
            [AgeBucket.OverTwoYears] = Ui.Hex("#F472B6"), [AgeBucket.Unknown] = Ui.Brush("AppBarTrack"),
        };
        foreach (var b in new[] { AgeBucket.Under30, AgeBucket.Days30To90, AgeBucket.Days90To365,
                     AgeBucket.OneToTwoYears, AgeBucket.OverTwoYears, AgeBucket.Unknown }
                     .Where(b => ageBytes.GetValueOrDefault(b) > 0))
        {
            long bytes = ageBytes[b];
            age.Children.Add(Ui.DotRow(ageColors[b], AgeMap.Title(b),
                ByteFormat.Format(bytes), (double)bytes / Math.Max(1, total)));
        }

        var pair = new Grid { Margin = new Thickness(0, 0, 0, 12) };
        pair.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        pair.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) });
        pair.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var left = Ui.Card(byType, 14, new Thickness(0));
        var right = Ui.Card(age, 14, new Thickness(0));
        Grid.SetColumn(left, 0); Grid.SetColumn(right, 2);
        pair.Children.Add(left); pair.Children.Add(right);

        var wrap = new StackPanel();
        wrap.Children.Add(stats);
        wrap.Children.Add(pair);
        return wrap;
    }
}

/// <summary>Old Downloads — files inside any "Downloads" folder.</summary>
public sealed class OldDownloadsPage : FileListPage
{
    protected override string PageName => "Old Downloads";
    protected override string PageIcon => Icons.Downloads;
    protected override Brush PageIconBg => Ui.Brush("AppSuccessBg");
    protected override Brush PageIconFg => Ui.Brush("AppSuccess");
    protected override string PageBlurb =>
        "Files sitting in Downloads — mostly installers, zips and documents you already used.";

    protected override List<int> Collect(FileTree tree, long[] totals, string rootPath)
    {
        // Find directories named Downloads, then rank the files inside them.
        var roots = new List<int>();
        var stack = new Stack<int>();
        if (tree.Count > 0) stack.Push(0);
        while (stack.Count > 0)
        {
            int id = stack.Pop();
            if (id != 0 && tree.IsDirectory[id]
                && tree.NameOf(id).Equals("Downloads", StringComparison.OrdinalIgnoreCase))
            {
                roots.Add(id);
                continue; // don't nest into a second Downloads below this one
            }
            int child = tree.FirstChild[id];
            while (child != -1) { stack.Push(child); child = tree.NextSibling[child]; }
        }
        var files = new List<int>();
        foreach (var r in roots)
        {
            var inner = new Stack<int>();
            inner.Push(r);
            while (inner.Count > 0)
            {
                int id = inner.Pop();
                int child = tree.FirstChild[id];
                while (child != -1)
                {
                    if (tree.IsDirectory[child]) inner.Push(child);
                    else if (totals[child] > 0) files.Add(child);
                    child = tree.NextSibling[child];
                }
            }
        }
        return files;
    }

    protected override UIElement? Hero(FileTree tree, long[] totals, List<int> ids)
    {
        int today = AgeMap.Today();
        long total = ids.Sum(id => totals[id]);
        long days30 = ids.Where(id => today - tree.ModifiedDay[id] > 30).Sum(id => totals[id]);
        long days90 = ids.Where(id => today - tree.ModifiedDay[id] > 90).Sum(id => totals[id]);
        var big = ids.Where(id => totals[id] >= 100_000_000).ToList();

        var stats = Ui.StatRow(
            Ui.StatCard(Icons.Downloads, Ui.Brush("AppSuccessBg"), Ui.Brush("AppSuccess"),
                ByteFormat.Format(total), "Old downloads", $"in {ids.Count:N0} files"),
            Ui.StatCard(Icons.Forgotten, Ui.Hex("#EAF1FE"), Ui.Hex("#2563EB"),
                ByteFormat.Format(days30), "30+ days old"),
            Ui.StatCard(Icons.Forgotten, Ui.Hex("#F3E8FF"), Ui.Hex("#7C3AED"),
                ByteFormat.Format(days90), "90+ days old"),
            Ui.StatCard(Icons.BiggestFiles, Ui.Hex("#FEF3DE"), Ui.Hex("#B45309"),
                $"{big.Count:N0} files", "Worth reviewing", "> 100 MB"));

        // Green hero card — the mockup's "what's in Downloads" explainer.
        var heroText = new StackPanel();
        var top3 = ids.OrderByDescending(id => totals[id]).Take(3).ToList();
        long top3Bytes = top3.Sum(id => totals[id]);
        long yearOld = ids.Where(id => today - tree.ModifiedDay[id] > 365).Sum(id => totals[id]);
        heroText.Children.Add(Ui.T(
            $"Downloads has {ByteFormat.Format(total)} of files — " +
            $"{ByteFormat.Format(top3Bytes)} comes from {top3.Count} large files. " +
            $"{ByteFormat.Format(yearOld)} hasn't been modified in over a year. " +
            "Review the files below and add the ones you don't need to Cleanup Review.",
            13, null, Ui.Brush("AppForeground"), wrap: true));
        heroText.Children.Add(new Border { Height = 12 });
        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        actions.Children.Add(Ui.Button($"Review files ({ids.Count:N0})", null, Ui.ButtonStyle.Dark,
            () => { }));
        actions.Children.Add(new Border { Width = 10 });
        var reveal = Ui.Button("Reveal Downloads in Explorer", null, Ui.ButtonStyle.Outline,
            () =>
            {
                if (Model.RootPath is { } rp)
                {
                    string dl = System.IO.Path.Combine(rp, "Downloads");
                    if (System.IO.Directory.Exists(dl)) Explorer.Reveal(dl);
                    else Explorer.Reveal(Model.PathOf(ids.FirstOrDefault()));
                }
            });
        actions.Children.Add(reveal);
        heroText.Children.Add(actions);
        var hero = new Border
        {
            Background = Ui.Brush("AppSuccessBg"),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(18, 14, 18, 14),
            Margin = new Thickness(0, 0, 0, 12),
            Child = heroText,
        };

        // Age + type breakdown side by side.
        var age = new StackPanel();
        age.Children.Add(Ui.T("Age distribution", 13, FontWeights.SemiBold));
        var ageBytes = new Dictionary<AgeBucket, long>();
        foreach (var id in ids)
        {
            var b = AgeMap.Bucket(tree.ModifiedDay[id], today);
            ageBytes[b] = ageBytes.GetValueOrDefault(b) + totals[id];
        }
        var ageColors = new Dictionary<AgeBucket, Brush>
        {
            [AgeBucket.Under30] = Ui.Hex("#60A5FA"), [AgeBucket.Days30To90] = Ui.Hex("#93C5FD"),
            [AgeBucket.Days90To365] = Ui.Hex("#F0A95F"), [AgeBucket.OneToTwoYears] = Ui.Hex("#A78BFA"),
            [AgeBucket.OverTwoYears] = Ui.Hex("#DC2626"), [AgeBucket.Unknown] = Ui.Brush("AppBarTrack"),
        };
        foreach (var b in new[] { AgeBucket.Under30, AgeBucket.Days30To90, AgeBucket.Days90To365,
                     AgeBucket.OneToTwoYears, AgeBucket.OverTwoYears, AgeBucket.Unknown }
                     .Where(b => ageBytes.GetValueOrDefault(b) > 0))
            age.Children.Add(Ui.DotRow(ageColors[b], AgeMap.Title(b),
                ByteFormat.Format(ageBytes[b]), (double)ageBytes[b] / Math.Max(1, total)));

        var byType = new StackPanel();
        byType.Children.Add(Ui.T("File type breakdown", 13, FontWeights.SemiBold));
        var kinds = ids.GroupBy(id => FileTypes.KindOfFile(tree.NameOf(id)))
            .Select(g => (Kind: g.Key, Bytes: g.Sum(i => totals[i])))
            .OrderByDescending(k => k.Bytes).Take(6).ToList();
        foreach (var k in kinds)
        {
            var cat = FileTypes.Categories.FirstOrDefault(c => c.Id == k.Kind);
            byType.Children.Add(Ui.DotRow(Ui.Hex(cat?.BadgeForeground ?? "#94A3B8"),
                FileTypes.LabelOf(k.Kind), ByteFormat.Format(k.Bytes),
                (double)k.Bytes / Math.Max(1, total)));
        }

        var pair = new Grid { Margin = new Thickness(0, 0, 0, 12) };
        pair.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        pair.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) });
        pair.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var left = Ui.Card(age, 14, new Thickness(0));
        var right = Ui.Card(byType, 14, new Thickness(0));
        Grid.SetColumn(left, 0); Grid.SetColumn(right, 2);
        pair.Children.Add(left); pair.Children.Add(right);

        var wrap = new StackPanel();
        wrap.Children.Add(stats);
        wrap.Children.Add(hero);
        wrap.Children.Add(pair);
        return wrap;
    }
}

/// <summary>File Browser — children of the zoomed folder, sorted by size.</summary>
public sealed class FileBrowserPage : FileListPage
{
    protected override string PageName => "File Browser";
    protected override string PageIcon => Icons.FileBrowser;
    protected override string PageBlurb =>
        "Browse the current folder item by item — sizes, kinds and dates at a glance.";
    protected override string Noun => "items";
    protected override List<int> Collect(FileTree tree, long[] totals, string rootPath) =>
        tree.ChildrenOf(Model.ZoomedNode, totals).Select(c => c.Id).ToList();

    /// <summary>Breadcrumb + folder header card, mirroring the mockup.</summary>
    protected override UIElement? Hero(FileTree tree, long[] totals, List<int> ids)
    {
        int zoom = Model.ZoomedNode;
        // Breadcrumb: ‹ › | folder icon | segments | Focus
        var crumbs = new WrapPanel { VerticalAlignment = VerticalAlignment.Center };
        var chain = new List<int>();
        for (int id = zoom; id >= 0 && id != tree.Parent[id]; id = tree.Parent[id]) chain.Insert(0, id);
        foreach (var (id, i) in chain.Select((c, i) => (c, i)))
        {
            if (i > 0) crumbs.Children.Add(Ui.Faint("  ›  "));
            bool last = id == zoom;
            string label = id == 0 && Model.RootPath is { } rp
                ? rp.TrimEnd('\\', '/')
                : tree.NameOf(id);
            var t = Ui.T(label, 12.5, last ? FontWeights.SemiBold : FontWeights.Normal,
                last ? Ui.Brush("AppForeground") : Ui.Brush("AppSubtle"));
            if (!last)
            {
                int captured = id;
                t.Cursor = System.Windows.Input.Cursors.Hand;
                t.MouseLeftButtonDown += (_, _) => { Model.DrillTo(captured); };
            }
            crumbs.Children.Add(t);
        }
        var crumbRow = new DockPanel();
        var back = Ui.Button("", Icons.Back, Ui.ButtonStyle.Ghost, () => Model.GoBack());
        back.Padding = new Thickness(8, 6, 8, 6);
        var fwd = Ui.Button("", Icons.Forward, Ui.ButtonStyle.Ghost, () => Model.GoForward());
        fwd.Padding = new Thickness(8, 6, 8, 6);
        var focus = Ui.Button("Focus", null, Ui.ButtonStyle.Outline,
            () => Model.DrillTo(zoom));
        DockPanel.SetDock(focus, Dock.Right);
        crumbRow.Children.Add(focus);
        var left = new StackPanel { Orientation = Orientation.Horizontal };
        left.Children.Add(back); left.Children.Add(fwd);
        left.Children.Add(Ui.IconTile(Icons.Folder, 24, Ui.Brush("AppAccentSoft"), Ui.Brush("AppAccent"), 6));
        left.Children.Add(new Border { Width = 8 });
        left.Children.Add(crumbs);
        crumbRow.Children.Add(left);
        var crumbCard = Ui.Card(crumbRow, 10, new Thickness(0, 0, 0, 10));

        // Folder header card: icon + name/size/items + type bar with legend.
        var card = new DockPanel();
        card.Children.Add(Ui.IconTile(
            tree.IsDirectory[zoom] ? Icons.Folder : Icons.File, 40,
            Ui.Brush("AppAccentSoft"), Ui.Brush("AppAccent"), 9));
        var text = new StackPanel { Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        string name = zoom == 0 && Model.RootPath is { } rp2
            ? System.IO.Path.GetFileName(rp2.TrimEnd('\\', '/')) is { Length: > 0 } n ? n : rp2.TrimEnd('\\', '/')
            : tree.NameOf(zoom);
        text.Children.Add(Ui.T(name, 16, FontWeights.SemiBold));
        long size = totals[zoom];
        int items = zoom < Model.Counts.Files.Length
            ? Model.Counts.Files[zoom] + Model.Counts.Folders[zoom] : 0;
        text.Children.Add(Ui.Subtle($"{ByteFormat.Format(size)} · {items:N0} items", 11.5));
        DockPanel.SetDock(text, Dock.Left);
        card.Children.Add(text);
        var parts = FileTypes.TypeBreakdown(tree, totals, zoom)
            .OrderByDescending(kv => kv.Value)
            .Select(kv => (FileTypes.LabelOf(kv.Key), kv.Value,
                Ui.Hex(FileTypes.TileColorOf(kv.Key))))
            .ToList();
        var right = new StackPanel { Width = 300, VerticalAlignment = VerticalAlignment.Center };
        DockPanel.SetDock(right, Dock.Right);
        right.Children.Add(Ui.TypeBarWithLegend(parts, Math.Max(1, size)));
        card.Children.Add(right);

        var wrap = new StackPanel();
        wrap.Children.Add(crumbCard);
        wrap.Children.Add(Ui.Card(card, 14, new Thickness(0)));
        return wrap;
    }
}

/// <summary>
/// Search — the Find page: a query box taking the FileQuery language
/// (ext: size&gt; age&gt; name: path: in: is: type: kind:), suggestion chips
/// that toggle tokens in the text, and plain-language explanation of
/// what the query means. Bare words fall back to substring matching.
/// </summary>
public sealed class SearchPage : FileListPage
{
    private FileQuery.Result? _lastResult;
    private FileQuery.Parsed _lastParsed;
    private bool _usedQuery;
    private Dictionary<Guid, SavedSearches.Total> _savedTotals = [];

    protected override string PageName => "Find";
    protected override string PageIcon => Icons.Search;
    protected override Brush PageIconBg => Ui.Brush("AppHover");
    protected override Brush PageIconFg => Ui.Brush("AppSubtle");
    protected override string Noun => "matches";
    protected override string PageBlurb =>
        $"Results for \"{Model.SearchQuery}\"";

    private static readonly (string Label, string Token)[] Chips =
    [
        ("Large", "size>500MB"),
        ("Old", "age>1y"),
        ("Duplicated", "is:duplicate"),
        ("Cached", "in:caches"),
        ("Media", "kind:media"),
        ("Downloads", "in:downloads"),
    ];

    protected override List<int> Collect(FileTree tree, long[] totals, string rootPath)
    {
        _lastParsed = FileQuery.Parse(Model.SearchQuery, home: Environment.GetFolderPath(
            Environment.SpecialFolder.UserProfile), root: rootPath);
        _usedQuery = _lastParsed.Query.IsStructured;
        if (!_usedQuery)
        {
            // Bare words — the fast substring index answers directly.
            _lastResult = null;
            return FileSearch.Search(tree, totals, Model.SearchQuery, limit: 500);
        }
        var context = new FileQuery.Context(
            DuplicateFileIDs: Model.DuplicateFileIDs);
        _lastResult = _lastParsed.Query.Run(tree, rootPath, totals, context, limit: 500);
        // Saved searches get their live totals here — off the UI thread,
        // one count-only pass each.
        var saved = SavedSearches.Load();
        _savedTotals = saved.Count > 0
            ? SavedSearches.Totals(saved, tree, rootPath, totals, context)
            : [];
        return _lastResult.Ids;
    }

    /// <summary>
    /// Query box + chips + the meaning of the current query, between the
    /// header and the toolbar.
    /// </summary>
    protected override UIElement? Hero(FileTree tree, long[] totals, List<int> ids)
    {
        var hero = new StackPanel { Margin = new Thickness(0, 0, 0, 12) };

        var (box, input) = Ui.SearchBox(
            "ext:mp4 size>500MB age>1y in:downloads — or plain words", 460);
        input.Text = Model.SearchQuery;
        input.KeyDown += (_, e) =>
        {
            if (e.Key == System.Windows.Input.Key.Enter && input.Text.Trim().Length > 0)
            {
                Model.SearchQuery = input.Text.Trim();
                Refresh();
                e.Handled = true;
            }
        };
        var queryRow = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        var save = Ui.Button("Save search", Icons.Add, Ui.ButtonStyle.Outline, () =>
        {
            string text = Model.SearchQuery.Trim();
            if (text.Length == 0 || Model.RootPath is not { } r) return;
            var list = SavedSearches.Load();
            if (list.Count >= SavedSearches.Limit || list.Any(s => s.Query == text)) return;
            list.Add(SavedSearch.New(SavedSearches.DefaultName(text, r), text));
            SavedSearches.Save(list);
            Refresh();
        });
        DockPanel.SetDock(save, Dock.Right);
        save.Margin = new Thickness(8, 0, 0, 0);
        queryRow.Children.Add(save);
        DockPanel.SetDock(box, Dock.Left);
        queryRow.Children.Add(box);
        hero.Children.Add(queryRow);

        var chips = new WrapPanel { Margin = new Thickness(0, 0, 0, 8) };
        foreach (var (label, token) in Chips)
        {
            bool on = FileQuery.ContainsToken(token, Model.SearchQuery);
            var pill = Ui.Pill(label, on, () =>
            {
                Model.SearchQuery = FileQuery.Toggling(token, Model.SearchQuery);
                Refresh();
            });
            pill.Margin = new Thickness(0, 0, 6, 4);
            chips.Children.Add(pill);
        }
        hero.Children.Add(chips);

        // WIN-029: saved searches — live totals over this scan; right-click
        // a pill to forget it.
        var saved = SavedSearches.Load();
        if (saved.Count > 0)
        {
            var totalsById = _savedTotals;
            var savedRow = new WrapPanel { Margin = new Thickness(0, 0, 0, 8) };
            foreach (var search in saved)
            {
                string label = search.Name;
                if (totalsById.TryGetValue(search.Id, out var total) && total.Count > 0)
                    label += $"  ·  {ByteFormat.Format(total.Bytes)}";
                var pill = Ui.Pill(label, search.Query == Model.SearchQuery, () =>
                {
                    Model.SearchQuery = search.Query;
                    Refresh();
                });
                pill.Margin = new Thickness(0, 0, 6, 4);
                pill.ToolTip = new ToolTip
                {
                    Content = $"{search.Query}\nRight-click to remove",
                };
                var capturedId = search.Id;
                pill.MouseRightButtonDown += (_, _) =>
                {
                    SavedSearches.Save(SavedSearches.Load().Where(s => s.Id != capturedId));
                    Refresh();
                };
                savedRow.Children.Add(pill);
            }
            hero.Children.Add(savedRow);
        }

        if (_usedQuery)
        {
            var parts = _lastParsed.Query.Describe();
            hero.Children.Add(Ui.Subtle(string.Join("  ·  ", parts), 12));
            if (_lastParsed.Problems.Count > 0)
                hero.Children.Add(Ui.Subtle(
                    "Not understood: " + string.Join("; ", _lastParsed.Problems.Select(p =>
                        $"{p.Token} ({p.Message})")), 11.5));
        }
        if (_lastResult is { } result)
        {
            if (result.MatchCount > result.Ids.Count)
                hero.Children.Add(Ui.Subtle(
                    $"{result.MatchCount:N0} matches · " +
                    $"{ByteFormat.Format(result.MatchedBytes)} matched · showing the largest {result.Ids.Count}", 12));
            else if (result.MatchedBytes > 0)
                hero.Children.Add(Ui.Subtle(
                    $"{result.MatchCount:N0} matches · {ByteFormat.Format(result.MatchedBytes)} matched", 12));
            foreach (var note in result.Notes)
                hero.Children.Add(Ui.Subtle(note, 11.5));
            if (FileQuery.ContainsToken("is:duplicate", Model.SearchQuery))
                hero.Children.Add(Ui.Subtle(
                    "Duplicated means in a same-content group — run Duplicates to refresh.", 11.5));
        }
        return hero;
    }
}

/// <summary>
/// Overview — the calm-system landing page (docs/DESIGN.md §17):
/// one reading column (max 880), the hero figure, "where it's going"
/// category rows, worth-reviewing and growth/file columns, a mono
/// footer. Hairlines and space — no cards.
/// </summary>
public sealed class OverviewPage : ListPage
{
    protected override void Refresh()
    {
        Root.Children.Clear();
        var tree = Model.Tree;
        if (tree is null || Model.Totals.Length != tree.Count)
        {
            Root.Children.Add(FirstRunHero());
            return;
        }

        var totals = Model.Totals;
        var volume = Model.Volume;
        Root.Children.Add(Working("Summarizing…"));
        Compute(() =>
        {
            long compressed = 0, cloudBytes = 0;
            for (int i = 0; i < tree.Count; i++)
            {
                if (tree.AllocatedSize[i] < tree.LogicalSize[i])
                    compressed += tree.LogicalSize[i] - tree.AllocatedSize[i];
                if ((tree.Flags[i] & NodeFlags.NotDownloaded) != 0)
                    cloudBytes += totals[i];
            }
            return new
            {
                TopFiles = TopSizes.Largest(1, tree.Count, 5, id => totals[id],
                    id => !tree.IsDirectory[id] && totals[id] > 0),
                Compressed = compressed,
                CloudBytes = cloudBytes,
            };
        }, data => Show(tree, totals, volume, data.TopFiles, data.Compressed, data.CloudBytes));
    }

    /// <summary>The one reading column — centred, 880 max (§17).</summary>
    private StackPanel ReadingColumn()
    {
        var center = new Grid();
        var column = new StackPanel
        {
            MaxWidth = 880,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(32, 8, 32, 0),
        };
        center.Children.Add(column);
        Root.Children.Add(center);
        return column;
    }

    private void Show(FileTree tree, long[] totals, VolumeInfo? volume,
        List<int> topFiles, long compressedBytes, long cloudOnlyBytes)
    {
        Root.Children.Clear();
        var column = ReadingColumn();
        column.Children.Add(Hero(tree, totals, volume, compressedBytes, cloudOnlyBytes));

        // Access-denied notice — the one bordered row the page may carry.
        if (Model.DeniedDirectories is { Count: > 0 } denied && Model.RootPath is { } rootPath)
        {
            var examples = denied.Take(3).Select(id => tree.PathOf(id, rootPath)).ToList();
            var notice = Ui.Notice(
                $"{denied.Count} folder{(denied.Count == 1 ? "" : "s")} couldn't be scanned",
                "Access was denied — the figures above are missing what's inside. " +
                "Run DiskMap as administrator to include everything." +
                (examples.Count > 0 ? "\n" + string.Join("\n", examples.Select(e => "  " + e)) +
                    (denied.Count > examples.Count ? $"\n  …and {denied.Count - examples.Count} more" : "") : ""));
            notice.Margin = new Thickness(0, 0, 0, 32);
            column.Children.Add(notice);
        }

        var going = WhereGoing(tree, totals);
        going.Margin = new Thickness(0, 0, 0, 32);
        column.Children.Add(going);

        var pair = TwoColumns(tree, totals, topFiles);
        pair.Margin = new Thickness(0, 0, 0, 32);
        column.Children.Add(pair);

        column.Children.Add(Footer());
    }

    // ---- Hero (§17.1): volume label, the one display figure, the
    // capacity bar, one coverage sentence + the Why? popover ----

    private FrameworkElement Hero(FileTree tree, long[] totals, VolumeInfo? volume,
        long compressedBytes, long cloudOnlyBytes)
    {
        var hero = new StackPanel { Margin = new Thickness(0, 0, 0, 32) };
        long used, total, free;
        string driveName;
        if (volume is { } v)
        {
            used = v.UsedBytes; total = v.TotalBytes; free = v.FreeBytes;
            driveName = v.DriveLabel;
        }
        else
        {
            used = totals[0]; total = totals[0]; free = 0;
            driveName = Model.RootPath ?? "Scan";
        }
        double usedFrac = total > 0 ? (double)used / total : 0;
        double freeFrac = total > 0 ? (double)free / total : 1;
        bool low = freeFrac < 0.10;

        hero.Children.Add(Ui.MonoLabel(driveName));
        var display = Ui.Mono($"{ByteFormat.Format(free)} free", 28, FontWeights.SemiBold);
        display.Margin = new Thickness(0, 4, 0, 2);
        hero.Children.Add(display);

        var sub = new StackPanel { Orientation = Orientation.Horizontal };
        sub.Children.Add(Ui.Mono($"of {ByteFormat.Format(total)} · {usedFrac * 100:0}% used", 12, null, Ui.Brush("AppSubtle")));
        if (low)
        {
            var safety = Ui.SafetyLabel(Ui.Brush("AppDanger"), "Low on space");
            safety.Margin = new Thickness(14, 0, 0, 0);
            safety.VerticalAlignment = VerticalAlignment.Center;
            sub.Children.Add(safety);
        }
        sub.Margin = new Thickness(0, 0, 0, 10);
        hero.Children.Add(sub);

        var bar = Ui.CapacityBar(usedFrac,
            low ? Ui.Brush("AppDanger") : Ui.WithOpacity("AppForeground", 0.55));
        bar.Margin = new Thickness(0, 0, 0, 10);
        hero.Children.Add(bar);

        // Coverage sentence + Why? popover (§16.3) — the reconciliation
        // numbers live in the popover, the sentence on the page.
        var coverage = new StackPanel { Orientation = Orientation.Horizontal };
        var rec = Model.Snapshot?.Reconciliation;
        string sentence = rec is { } r && !r.ScannedExceedsUsed
            ? $"This scan accounts for {ByteFormat.Format(r.ScannedBytes)} of the {ByteFormat.Format(r.UsedBytes)} in use ({r.CoverageFraction * 100:0.#}%)."
            : $"This scan counts {ByteFormat.Format(totals[0])} across every name it could read.";
        var sent = Ui.Subtle(sentence, 12);
        coverage.Children.Add(sent);
        var whyLink = Ui.LinkText("Why?", () => { }, 12);
        whyLink.Margin = new Thickness(8, 0, 0, 0);
        var popup = WhyPopover(whyLink, tree, compressedBytes, cloudOnlyBytes);
        whyLink.MouseLeftButtonDown += (_, _) => popup.IsOpen = !popup.IsOpen;
        coverage.Children.Add(whyLink);
        hero.Children.Add(coverage);
        hero.Children.Add(popup);
        return hero;
    }

    /// <summary>§16.3 — "WHY THE NUMBERS DIFFER", raised, 340 wide.</summary>
    private System.Windows.Controls.Primitives.Popup WhyPopover(
        FrameworkElement anchor, FileTree tree, long compressedBytes, long cloudOnlyBytes)
    {
        var body = new StackPanel { Width = 340 };
        body.Children.Add(Ui.MonoLabel("Why the numbers differ", Ui.Brush("AppSubtle")));
        var rec = Model.Snapshot?.Reconciliation;
        if (rec is { } r)
        {
            string detail;
            if (r.ScannedExceedsUsed)
            {
                detail = $"This scan counts {ByteFormat.Format(r.ScannedBytes)} across names — more than the " +
                    $"{ByteFormat.Format(r.UsedBytes)} in use, because hard-linked files share the same physical blocks.";
            }
            else
            {
                bool svi = Model.DeniedDirectories.Any(id =>
                    tree.NameOf(id).Equals("System Volume Information", StringComparison.OrdinalIgnoreCase));
                detail = $"{ByteFormat.Format(r.UnaccountedBytes)} sits outside the scan: " +
                    (svi ? "restore points and VSS shadow copies in System Volume Information (which Windows won't let us read), plus "
                        : "restore points and ") +
                    "system state, other volumes mounted under this folder, folders Windows " +
                    "wouldn't let us read, and filesystem metadata itself.";
            }
            var text = Ui.Subtle(detail, 12);
            text.TextWrapping = TextWrapping.Wrap;
            text.Margin = new Thickness(0, 8, 0, 0);
            body.Children.Add(text);
        }
        var correction = Model.Snapshot?.HardLinkCorrection;
        if (correction is { IsEmpty: false } c)
        {
            var t = Ui.Subtle($"{c.DuplicateNameCount:N0} names of hard-linked files are counted once — " +
                $"{ByteFormat.Format(c.AllocatedBytes)} of shared blocks.", 12);
            t.TextWrapping = TextWrapping.Wrap;
            t.Margin = new Thickness(0, 8, 0, 0);
            body.Children.Add(t);
        }
        if (Model.Volume is { DriveFormat: "ReFS" })
        {
            var clone = Model.CloneCorrection;
            var t = Ui.Subtle(clone.CloneCount > 0
                ? $"{clone.CloneCount:N0} cloned copies share {ByteFormat.Format(clone.Bytes)} — counted once."
                : "Block-cloned copies are counted per copy — turn on clone accounting in Settings (Ctrl+,) to count clones once.");
            t.FontSize = 12;
            t.TextWrapping = TextWrapping.Wrap;
            t.Margin = new Thickness(0, 8, 0, 0);
            body.Children.Add(t);
        }
        if (compressedBytes > 256L * 1024 * 1024 || cloudOnlyBytes > 0)
        {
            string extra = compressedBytes > 256L * 1024 * 1024
                ? $"{ByteFormat.Format(compressedBytes)} of the scanned data is already compressed or sparse on disk."
                : "";
            if (cloudOnlyBytes > 0)
                extra += (extra.Length > 0 ? " " : "") +
                    $"{ByteFormat.Format(cloudOnlyBytes)} lives only in the cloud — evicting it in Explorer frees space without deleting.";
            var t = Ui.Subtle(extra, 12);
            t.TextWrapping = TextWrapping.Wrap;
            t.Margin = new Thickness(0, 8, 0, 0);
            body.Children.Add(t);
        }
        return new System.Windows.Controls.Primitives.Popup
        {
            PlacementTarget = anchor,
            Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom,
            StaysOpen = false,
            AllowsTransparency = true,
            Child = new Border
            {
                Background = Ui.Brush("AppCard"),
                BorderBrush = Ui.Brush("AppBorder"),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(10),
                Padding = new Thickness(16),
                Margin = new Thickness(0, 6, 0, 0),
                Child = body,
            },
        };
    }

    // ---- Where it's going (§17.3): SectionHeader + segmented bar +
    // §14.4 category rows ----

    private FrameworkElement WhereGoing(FileTree tree, long[] totals)
    {
        var section = new StackPanel();
        var open = Ui.LinkText("Open in Visualize →", () => Model.Visualize(0));
        open.VerticalAlignment = VerticalAlignment.Bottom;
        section.Children.Add(Ui.SectionHeader(
            Model.Snapshot?.Mode == CategoryMode.Folder ? "Where it's going · by type" : "Where it's going",
            trailing: open));
        section.Children.Add(new Border { Height = 12 });

        var cats = Model.Snapshot?.Categories;
        List<(string Name, long Bytes, Brush Brush, Action? Go)> rows = [];
        if (cats is { Count: > 0 })
        {
            foreach (var cat in cats.Take(8))
            {
                Action? go = cat.NodeId is { } nodeId
                    ? () => Model.Visualize(nodeId)
                    : cat.FileKind is { } kind
                        ? () => { Model.SearchQuery = $"kind:{kind}"; Model.ShowPage("Find"); }
                        : null;
                rows.Add((cat.Title, cat.Bytes, CategoryBrush(cat), go));
            }
        }
        else
        {
            int i = 0;
            foreach (var (id, size) in tree.ChildrenOf(0, totals).OrderByDescending(c => c.Size).Take(7))
            {
                int captured = id;
                rows.Add((tree.NameOf(id), size, Ui.Data(i++), () => Model.Visualize(captured)));
            }
        }
        long sum = Math.Max(1, rows.Sum(r => r.Bytes));

        // The 6 pt composition bar — segments in the data palette.
        var parts = rows.Take(6).Select(r => ((double)r.Bytes / sum, r.Brush)).ToList();
        double rest = Math.Max(0, 1 - parts.Sum(p => p.Item1));
        if (rest > 0.005) parts.Add((rest, Ui.Data(6)));
        var bar = Ui.SegBar(parts);
        bar.Margin = new Thickness(0, 0, 0, 12);
        section.Children.Add(bar);

        // §14.4 rows: dot · name · 3 pt bar · mono size · mono %.
        foreach (var (name, bytes, brush, go) in rows)
        {
            var row = new Grid();
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(150) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(76) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(40) });
            var dot = Ui.Dot(brush, 8);
            Grid.SetColumn(dot, 0);
            row.Children.Add(dot);
            var nameText = Ui.T(name, 13, FontWeights.Medium);
            nameText.TextTrimming = TextTrimming.CharacterEllipsis;
            nameText.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(nameText, 1);
            row.Children.Add(nameText);
            var prop = Ui.CapacityBar((double)bytes / Math.Max(1, rows[0].Bytes), brush, double.NaN);
            prop.Height = 3;
            prop.VerticalAlignment = VerticalAlignment.Center;
            prop.Margin = new Thickness(0, 0, 12, 0);
            Grid.SetColumn(prop, 2);
            row.Children.Add(prop);
            var sizeText = Ui.Mono(ByteFormat.Format(bytes), 12, FontWeights.Medium);
            sizeText.HorizontalAlignment = HorizontalAlignment.Right;
            sizeText.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(sizeText, 3);
            row.Children.Add(sizeText);
            var pctText = Ui.Mono($"{100.0 * bytes / sum:0}%", 11, null, Ui.Brush("AppSubtle"));
            pctText.HorizontalAlignment = HorizontalAlignment.Right;
            pctText.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(pctText, 4);
            row.Children.Add(pctText);
            section.Children.Add(Ui.HoverRow(row, go));
        }
        if (rows.Count == 0)
            section.Children.Add(Ui.Subtle("The scan is empty.", 12));
        return section;
    }

    private static Brush CategoryBrush(StorageCategory cat) =>
        cat.FileKind is { } kind ? Ui.KindColor(kind)
        : cat.Key switch
        {
            "downloads" => Ui.Data(2),
            "applications" or "apps" => Ui.Data(4),
            "documents" => Ui.Data(5),
            "developer" => Ui.Data(0),
            "caches" or "appdata" => Ui.Data(3),
            _ => cat.ColorHex is { } hex ? Ui.Hex(hex) : Ui.Data(6),
        };

    // ---- Two columns (§17.4): worth reviewing | what grew / biggest ----

    private FrameworkElement TwoColumns(FileTree tree, long[] totals, List<int> topFiles)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var left = WorthReviewing(totals);
        Grid.SetColumn(left, 0);
        grid.Children.Add(left);

        FrameworkElement right = Model.HistoryComparison is { } growth && growth.Growers.Count > 0
            ? WhatGrew(tree, growth)
            : BiggestFiles(tree, totals, topFiles);
        Grid.SetColumn(right, 2);
        grid.Children.Add(right);
        return grid;
    }

    private FrameworkElement WorthReviewing(long[] totals)
    {
        var section = new StackPanel();
        var hits = Model.QuickWins ?? [];
        var groups = hits.GroupBy(h => h.Category)
            .Select(g => (Category: g.Key, Bytes: g.Sum(h => totals[h.Id]), Count: g.Count()))
            .OrderByDescending(g => g.Bytes).Take(6).ToList();
        long reclaimable = groups.Sum(g => g.Bytes);
        section.Children.Add(Ui.SectionHeader("Worth reviewing",
            reclaimable > 0 ? $"~{ByteFormat.Format(reclaimable)}" : null));

        // The narrator's ranked recommendations lead — each row is a
        // safety dot, a name, a tail-truncated detail, a mono size (§17.4).
        if (Model.Snapshot is { } snap)
        {
            foreach (var r in StorageNarrator.Recommendations(snap, 3))
            {
                var color = r.Safety switch
                {
                    StorySafety.Safe => Ui.Brush("AppSuccess"),
                    StorySafety.Protected => Ui.Brush("AppDanger"),
                    _ => Ui.Brush("AppWarning"),
                };
                section.Children.Add(LinkRow(color, r.Title, r.Detail,
                    ByteFormat.Format(r.Bytes), () => Model.ShowPage("Safe to Review")));
            }
        }
        foreach (var g in groups)
        {
            section.Children.Add(LinkRow(Ui.Brush("AppSuccess"), g.Category,
                $"{g.Count:N0} location{(g.Count == 1 ? "" : "s")} — regenerable data",
                ByteFormat.Format(g.Bytes), () => Model.ShowPage("Safe to Review")));
        }
        if (groups.Count == 0 && Model.Snapshot is null)
            section.Children.Add(Ui.Subtle("Nothing flagged — this scan looks clean.", 12));
        return section;
    }

    /// <summary>§17.4 link row: safety dot · name · detail · mono size · ›.</summary>
    private FrameworkElement LinkRow(Brush dot, string name, string detail, string size, Action go)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(14) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(14) });
        grid.Children.Add(Ui.Dot(dot, 6));
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(Ui.T(name, 13, FontWeights.Medium));
        var d = Ui.Faint(detail, 11.5);
        d.TextTrimming = TextTrimming.CharacterEllipsis;
        text.Children.Add(d);
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        var sizeText = Ui.Mono(size, 12, FontWeights.Medium);
        sizeText.VerticalAlignment = VerticalAlignment.Center;
        sizeText.Margin = new Thickness(8, 0, 4, 0);
        Grid.SetColumn(sizeText, 2);
        grid.Children.Add(sizeText);
        var chevron = Ui.T("›", 12, FontWeights.SemiBold, Ui.Brush("AppFaint"));
        chevron.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(chevron, 3);
        grid.Children.Add(chevron);
        return Ui.HoverRow(grid, go);
    }

    private FrameworkElement WhatGrew(FileTree tree, StorageHistory.Comparison growth)
    {
        var section = new StackPanel();
        string span = growth.IsWeek ? "this week" : $"since {growth.Since.LocalDateTime:MMM d}";
        string delta = $"{(growth.ScannedDelta >= 0 ? "+" : "−")}{ByteFormat.Format(Math.Abs(growth.ScannedDelta))}";
        section.Children.Add(Ui.SectionHeader($"What grew {span}", delta));

        if (growth.DeniedChanged)
            section.Children.Add(Ui.Subtle(
                "The two scans read different folders — small deltas may be the reading, not the disk.", 11.5));
        foreach (var g in growth.Growers.Take(6))
        {
            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var name = Ui.T(g.Path.Replace('/', '\\'), 13, FontWeights.Medium);
            name.TextTrimming = TextTrimming.CharacterEllipsis;
            name.VerticalAlignment = VerticalAlignment.Center;
            grid.Children.Add(name);
            var d = Ui.Mono($"+{ByteFormat.Format(g.Delta)}", 12, FontWeights.Medium);
            d.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(d, 1);
            grid.Children.Add(d);
            string captured = g.Path;
            section.Children.Add(Ui.HoverRow(grid, () =>
            {
                if (Model.RootPath is { } root && Model.Tree is { } t)
                {
                    string full = root.TrimEnd('\\') + "\\" + captured.Replace('/', '\\');
                    var lookup = FileQuery.NodeAt(full, t, root);
                    if (lookup.Kind == FileQuery.NodeLookupKind.Found)
                        Model.Select(lookup.Id);
                }
            }));
        }
        return section;
    }

    private FrameworkElement BiggestFiles(FileTree tree, long[] totals, List<int> topFiles)
    {
        var section = new StackPanel();
        section.Children.Add(Ui.SectionHeader("Biggest files"));
        foreach (var id in topFiles)
        {
            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(28) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(14) });
            string kind = FileTypes.KindOfFile(tree.NameOf(id));
            var icon = Ui.IconTile(Icons.ForKind(kind), 20,
                Ui.Tint(((SolidColorBrush)Ui.KindColor(kind)).Color, 40),
                Ui.KindColor(kind), 5);
            icon.VerticalAlignment = VerticalAlignment.Center;
            grid.Children.Add(icon);
            var name = Ui.T(tree.NameOf(id), 13, FontWeights.Medium);
            name.TextTrimming = TextTrimming.CharacterEllipsis;
            name.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(name, 1);
            grid.Children.Add(name);
            var size = Ui.Mono(ByteFormat.Format(totals[id]), 12, FontWeights.Medium);
            size.VerticalAlignment = VerticalAlignment.Center;
            size.Margin = new Thickness(8, 0, 4, 0);
            Grid.SetColumn(size, 2);
            grid.Children.Add(size);
            var chevron = Ui.T("›", 12, FontWeights.SemiBold, Ui.Brush("AppFaint"));
            chevron.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(chevron, 3);
            grid.Children.Add(chevron);
            int captured = id;
            section.Children.Add(Ui.HoverRow(grid, () => Model.Select(captured)));
        }
        if (topFiles.Count == 0)
            section.Children.Add(Ui.Subtle("No files in this scan.", 12));
        return section;
    }

    // ---- Mono footer (§17.5): scan kind + time, rescan links ----

    private FrameworkElement Footer()
    {
        var section = new StackPanel();
        section.Children.Add(Ui.Hairline());
        var row = new DockPanel { Margin = new Thickness(0, 10, 0, 0) };
        var links = new StackPanel { Orientation = Orientation.Horizontal };
        DockPanel.SetDock(links, Dock.Right);
        links.Children.Add(Ui.LinkText("Rescan", async () => await Model.RescanAsync(), 11));
        if (Model.Backend == "incremental" && Model.RootPath is not null)
        {
            var sep = Ui.Mono("  ·  ", 11, null, Ui.Brush("AppFaint"));
            links.Children.Add(sep);
            links.Children.Add(Ui.LinkText("Full Rescan", async () =>
            {
                if (Model.RootPath is { } rp) ScanCache.Remove(rp);
                await Model.RescanAsync();
            }, 11));
        }
        row.Children.Add(links);
        string kind = Model.Backend == "incremental" ? "Quick update" : "Full scan";
        row.Children.Add(Ui.Mono(
            $"{kind} — {Model.ItemCount:N0} items in {Model.Elapsed:0.0}s · {Model.Backend}",
            11, null, Ui.Brush("AppFaint")));
        section.Children.Add(row);
        return section;
    }

    // ---- First-run hero (§17): the mark, eyebrow, headline, buttons,
    // dashed hairline, four numbered mono hints ----

    private FrameworkElement FirstRunHero()
    {
        var hero = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 60, 0, 0) };

        // The treemap mark — five data-palette tiles, 220 × 132.
        var mark = new Grid { Width = 220, Height = 132 };
        mark.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(2, GridUnitType.Star) });
        mark.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.2, GridUnitType.Star) });
        mark.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0.8, GridUnitType.Star) });
        mark.RowDefinitions.Add(new RowDefinition { Height = new GridLength(3, GridUnitType.Star) });
        mark.RowDefinitions.Add(new RowDefinition { Height = new GridLength(2, GridUnitType.Star) });
        void Tile(int row, int col, int rowSpan, Brush fill)
        {
            var tile = new Border
            {
                Background = fill,
                CornerRadius = new CornerRadius(6),
                Margin = new Thickness(1.5),
            };
            if (rowSpan > 1) Grid.SetRowSpan(tile, rowSpan);
            Grid.SetRow(tile, row);
            Grid.SetColumn(tile, col);
            mark.Children.Add(tile);
        }
        Tile(0, 0, 1, Ui.Data(0));   // slate
        Tile(0, 1, 1, Ui.Data(2));   // rose
        Tile(0, 2, 2, Ui.Data(3));   // sage
        Tile(1, 0, 1, Ui.Data(1));   // violet
        Tile(1, 1, 1, Ui.Data(4));   // sand
        hero.Children.Add(mark);

        var eyebrow = Ui.MonoLabel("LOCAL · FAST · PRIVATE");
        eyebrow.HorizontalAlignment = HorizontalAlignment.Center;
        eyebrow.Margin = new Thickness(0, 28, 0, 10);
        hero.Children.Add(eyebrow);

        var headline = Ui.T("See where your space went.", 30, FontWeights.SemiBold);
        headline.HorizontalAlignment = HorizontalAlignment.Center;
        hero.Children.Add(headline);

        var paragraph = Ui.Subtle(
            "DiskMap reads your disk's own map — a full scan takes seconds, not minutes. " +
            "Then it shows what's using the space, what's safe to remove, and what to do next.", 13);
        paragraph.TextAlignment = TextAlignment.Center;
        paragraph.TextWrapping = TextWrapping.Wrap;
        paragraph.MaxWidth = 520;
        paragraph.Margin = new Thickness(0, 10, 0, 24);
        hero.Children.Add(paragraph);

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
        var scan = Ui.Button("Scan this PC", null, Ui.ButtonStyle.Dark, () =>
        {
            string root = System.IO.Path.GetPathRoot(
                Environment.GetFolderPath(Environment.SpecialFolder.System)) ?? "C:\\";
            _ = Model.ScanAsync(root);
        });
        var choose = Ui.Button("Choose Folder…", null, Ui.ButtonStyle.Outline, () => Model.RequestScan());
        choose.Margin = new Thickness(10, 0, 0, 0);
        buttons.Children.Add(scan);
        buttons.Children.Add(choose);
        hero.Children.Add(buttons);

        var dash = Ui.DashedHairline();
        dash.Margin = new Thickness(0, 36, 0, 24);
        hero.Children.Add(dash);

        var hints = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
        foreach (var hint in new[]
        {
            "01 — Pick a drive", "02 — See the map",
            "03 — Review what's safe", "04 — Send to Recycle Bin",
        })
        {
            var h = Ui.MonoLabel(hint);
            h.Margin = new Thickness(10, 0, 10, 0);
            hints.Children.Add(h);
        }
        hero.Children.Add(hints);
        return hero;
    }
}
