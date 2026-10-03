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

    /// <summary>Page header: icon tile + title + subtitle left, optional stat right.</summary>
    protected DockPanel Header(string title, string subtitle, string? rightStat = null,
        string? glyph = null, Brush? iconBg = null, Brush? iconFg = null)
    {
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 14) };
        if (rightStat is not null)
        {
            var stat = Ui.Subtle(rightStat, 12);
            stat.VerticalAlignment = VerticalAlignment.Center;
            DockPanel.SetDock(stat, Dock.Right);
            header.Children.Add(stat);
        }
        if (glyph is not null)
        {
            var tile = Ui.IconTile(glyph, 44, iconBg ?? Ui.Brush("AppAccentSoft"),
                iconFg ?? Ui.Brush("AppAccent"), 10);
            DockPanel.SetDock(tile, Dock.Left);
            tile.Margin = new Thickness(0, 0, 12, 0);
            header.Children.Add(tile);
        }
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        titles.Children.Add(Ui.PageTitle(title));
        titles.Children.Add(Ui.PageSubtitle(subtitle));
        header.Children.Add(titles);
        return header;
    }

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

    /// <summary>The mockup's bottom bar: "N selected · X | Add to Cleanup Review | M files · Y".</summary>
    protected void PaintBottomBar()
    {
        var totals = Model.Totals;
        var selected = _filtered.Where(_checked.Contains).ToList();
        long selBytes = selected.Sum(id => totals[id]);
        long allBytes = _filtered.Sum(id => totals[id]);

        _bottomHost.Content = Ui.BottomBar(
            Ui.T($"{selected.Count} selected · {ByteFormat.Format(selBytes)}", 12.5, FontWeights.Medium),
            new StackPanel
            {
                Orientation = Orientation.Horizontal,
                VerticalAlignment = VerticalAlignment.Center,
                Children =
                {
                    Ui.T($"{_filtered.Count:N0} {Noun} · {ByteFormat.Format(allBytes)}", 12, null, Ui.Brush("AppSubtle")),
                    new Border { Width = 14 },
                    RescanLink(),
                },
            },
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
        Ui.Cell(headerRow, Ui.Faint("#"), 1);
        Ui.Cell(headerRow, Ui.TableHead("Name"), 2);
        Ui.Cell(headerRow, Ui.TableHead("Type"), 3);
        Ui.Cell(headerRow, Ui.TableHead("Modified"), 4);
        Ui.Cell(headerRow, Ui.TableHead("Size"), 5, right: true);
        table.Children.Add(headerRow);

        _rowsHost = new StackPanel();
        for (int i = 0; i < ids.Count; i++)
        {
            _rowsHost.Children.Add(FileRow(tree, totals, ids[i], i + 1, rootPath));
        }
        if (ids.Count == 0)
            _rowsHost.Children.Add(Ui.Subtle("Nothing matches these filters."));
        _rowsHost.Tag = (tree, ids, rootPath);
        table.Children.Add(_rowsHost);
        return Ui.Card(table, 12);
    }

    private StackPanel? _rowsHost;

    /// <summary>Re-render the row stack in place — used when select-all toggles.</summary>
    private void RebuildRows()
    {
        if (_rowsHost?.Tag is not (FileTree tree, List<int> ids, string rootPath)) return;
        var totals = Model.Totals;
        _rowsHost.Children.Clear();
        for (int i = 0; i < ids.Count; i++)
            _rowsHost.Children.Add(FileRow(tree, totals, ids[i], i + 1, rootPath));
    }

    private UIElement FileRow(FileTree tree, long[] totals, int id, int rank, string rootPath)
    {
        string kind = FileTypes.KindOf(tree, id);
        var cat = FileTypes.Categories.FirstOrDefault(c => c.Id == kind);
        bool isDir = tree.IsDirectory[id];

        var outer = new Border { CornerRadius = new CornerRadius(6), Background = Brushes.Transparent };
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
        Ui.Cell(row, Ui.Faint(rank.ToString()), 1);
        Ui.Cell(row, Ui.NameCell(
            Icons.ForKind(kind),
            isDir ? Ui.Brush("AppAccentSoft") : Ui.Hex(cat?.BadgeBackground ?? "#F1F5F9"),
            isDir ? Ui.Brush("AppAccent") : Ui.Hex(cat?.BadgeForeground ?? "#475569"),
            tree.NameOf(id), Model.DisplayPath(id), 26), 2);
        Ui.Cell(row, Ui.KindBadge(kind), 3);
        Ui.Cell(row, Ui.Subtle(Ui.RelativeDay(tree.ModifiedDay[id]), 11.5), 4);
        Ui.Cell(row, Ui.T(ByteFormat.Format(totals[id]), 12), 5, right: true);
        Ui.Cell(row, Ui.MoreButton(() => OpenRowMenu(outer, tree, id)), 6, right: true);

        outer.Cursor = System.Windows.Input.Cursors.Hand;
        outer.MouseLeftButtonDown += (_, e) =>
        {
            if (e.ClickCount >= 2 && isDir) { Model.DrillTo(id); Model.ShowPage("File Browser"); }
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
    protected override List<int> Collect(FileTree tree, long[] totals, string rootPath) =>
        AgeMap.Untouched(tree, totals, AgeMap.Today(), limit: 1000);

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
        var legend = new WrapPanel();
        foreach (var b in present)
            legend.Children.Add(Ui.LegendDot(colors[b],
                $"{AgeMap.Title(b)}  {ByteFormat.Format(bucketBytes[b])} ({bucketBytes[b] * 100 / barTotal}%)"));
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

/// <summary>Search — global name search from the top bar.</summary>
public sealed class SearchPage : FileListPage
{
    protected override string PageName => "Search";
    protected override string PageIcon => Icons.Search;
    protected override Brush PageIconBg => Ui.Brush("AppHover");
    protected override Brush PageIconFg => Ui.Brush("AppSubtle");
    protected override string PageBlurb =>
        $"Results for \"{Model.SearchQuery}\" — type in the top bar (Ctrl+K) to search again.";
    protected override List<int> Collect(FileTree tree, long[] totals, string rootPath) =>
        FileSearch.Search(tree, totals, Model.SearchQuery, limit: 500);
}

/// <summary>
/// Overview — the "why is my disk full" dashboard: storage health,
/// where the space went, largest opportunities, top files.
/// </summary>
public sealed class OverviewPage : ListPage
{
    protected override void Refresh()
    {
        Root.Children.Clear();
        Root.Children.Add(Header("Overview", "Your disk at a glance — what's using the space and what to review."));
        var tree = Model.Tree;
        if (tree is null || Model.Totals.Length != tree.Count)
        {
            Root.Children.Add(Ui.EmptyState(Icons.Overview, "Scan your drive to understand where your storage is going",
                "DiskMap maps every file in seconds, then shows what's using the space, what's safe to remove, and what to do next.",
                Ui.Button("Scan Folder…", Icons.Add, Ui.ButtonStyle.Primary, () => Model.RequestScan())));
            return;
        }

        var totals = Model.Totals;
        var volume = Model.Volume;
        Root.Children.Add(Working("Summarizing…"));
        Compute(() => new
        {
            Children = tree.ChildrenOf(0, totals).OrderByDescending(c => c.Size).ToList(),
            TopFiles = TopSizes.Largest(1, tree.Count, 8, id => totals[id],
                id => !tree.IsDirectory[id] && totals[id] > 0),
            TypeBreakdown = FileTypes.TypeBreakdown(tree, totals, 0),
        }, data => Show(tree, totals, volume, data.Children, data.TopFiles, data.TypeBreakdown));
    }

    private void Show(FileTree tree, long[] totals, VolumeInfo? volume,
        List<(int Id, long Size)> children, List<int> topFiles,
        Dictionary<string, long> typeBreakdown)
    {
        Root.Children.RemoveAt(Root.Children.Count - 1); // the Working() line

        // Storage health card.
        var healthBody = new StackPanel();
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
        double frac = total > 0 ? (double)used / total : 0;
        var headline = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        var big = Ui.T($"{ByteFormat.Format(used)} used", 20, FontWeights.Bold);
        DockPanel.SetDock(big, Dock.Left);
        var pct = Ui.T($"{frac * 100:0}% full", 13, FontWeights.SemiBold,
            frac > 0.9 ? Ui.Brush("AppDanger") : frac > 0.75 ? Ui.Brush("AppWarning") : Ui.Brush("AppSuccess"));
        pct.VerticalAlignment = VerticalAlignment.Bottom;
        pct.Margin = new Thickness(10, 0, 0, 3);
        DockPanel.SetDock(pct, Dock.Left);
        headline.Children.Add(big);
        headline.Children.Add(pct);
        healthBody.Children.Add(headline);
        var bar = Ui.Bar(frac, frac > 0.9 ? Ui.Brush("AppDanger") : Ui.Brush("AppAccent"), 8, 0);
        bar.Width = double.NaN;
        healthBody.Children.Add(bar);
        healthBody.Children.Add(new Border { Height = 6 });
        healthBody.Children.Add(Ui.Subtle(
            $"{ByteFormat.Format(total)} total · {ByteFormat.Format(free)} free" +
            $" · scanned {Model.ItemCount:N0} items in {Model.Elapsed:0.0}s via {Model.Backend}", 11.5));
        Root.Children.Add(Ui.HeadedCard(Icons.Drive, Ui.Brush("AppAccentSoft"), Ui.Brush("AppAccent"),
            driveName, "Storage health", healthBody));

        // Two columns: where the space goes | largest opportunities.
        var columns = new Grid { Margin = new Thickness(0, 0, 0, 12) };
        columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) });
        columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var going = WhereGoing(tree, totals, children);
        var opportunities = Opportunities(tree, totals);
        Grid.SetColumn(going, 0);
        Grid.SetColumn(opportunities, 2);
        columns.Children.Add(going);
        columns.Children.Add(opportunities);
        Root.Children.Add(columns);

        // Biggest files preview.
        var filesBody = new StackPanel();
        foreach (var id in topFiles.Take(6))
        {
            string kind = FileTypes.KindOfFile(tree.NameOf(id));
            var cat = FileTypes.Categories.FirstOrDefault(c => c.Id == kind);
            var row = Ui.NameCell(Icons.ForKind(kind),
                Ui.Hex(cat?.BadgeBackground ?? "#F1F5F9"), Ui.Hex(cat?.BadgeForeground ?? "#475569"),
                tree.NameOf(id), ByteFormat.Format(totals[id]), 26);
            row.Margin = new Thickness(0, 4, 0, 4);
            int captured = id;
            row.Cursor = System.Windows.Input.Cursors.Hand;
            row.MouseLeftButtonDown += (_, _) => Model.Select(captured);
            filesBody.Children.Add(row);
        }
        var link = Ui.T("See all in Biggest Files →", 12, null, Ui.Brush("AppAccent"));
        link.Cursor = System.Windows.Input.Cursors.Hand;
        link.Margin = new Thickness(0, 10, 0, 0);
        link.MouseLeftButtonDown += (_, _) => Model.ShowPage("Biggest Files");
        filesBody.Children.Add(link);
        Root.Children.Add(Ui.HeadedCard(Icons.BiggestFiles, Ui.Hex("#F3E8FF"), Ui.Hex("#7C3AED"),
            "Largest files", "The individual files using the most space", filesBody));
    }

    private Border WhereGoing(FileTree tree, long[] totals, List<(int Id, long Size)> children)
    {
        var body = new StackPanel();
        long max = children.Count > 0 ? Math.Max(1, children[0].Size) : 1;
        foreach (var (id, size) in children.Take(7))
        {
            var row = new StackPanel { Margin = new Thickness(0, 0, 0, 10) };
            var top = new DockPanel { Margin = new Thickness(0, 0, 0, 4) };
            var sizeText = Ui.T(ByteFormat.Format(size), 11.5, FontWeights.Medium);
            DockPanel.SetDock(sizeText, Dock.Right);
            top.Children.Add(sizeText);
            var name = Ui.T(tree.NameOf(id), 12.5, FontWeights.Medium);
            name.Cursor = System.Windows.Input.Cursors.Hand;
            int captured = id;
            name.MouseLeftButtonDown += (_, _) => Model.Visualize(captured);
            top.Children.Add(name);
            row.Children.Add(top);
            var bar = Ui.Bar((double)size / max, Ui.Hex(FileTypes.BadgeForegroundOf(
                FileTypes.DominantKind(tree, totals, id))), 8, 0);
            bar.Width = double.NaN;
            row.Children.Add(bar);
            body.Children.Add(row);
        }
        if (children.Count == 0) body.Children.Add(Ui.Subtle("The scan is empty."));
        return Ui.HeadedCard(Icons.BiggestFolders, Ui.Brush("AppAccentSoft"), Ui.Brush("AppAccent"),
            "Where is your storage going?", "Largest folders in this scan", body,
            new Thickness(0));
    }

    private Border Opportunities(FileTree tree, long[] totals)
    {
        var body = new StackPanel();
        var hits = Model.QuickWins ?? [];
        var groups = hits.GroupBy(h => h.Category)
            .Select(g => (Category: g.Key, Bytes: g.Sum(h => totals[h.Id]), Count: g.Count()))
            .OrderByDescending(g => g.Bytes).Take(6).ToList();
        if (groups.Count == 0)
        {
            body.Children.Add(Ui.Subtle("No easy wins found — this scan looks clean."));
        }
        foreach (var g in groups)
        {
            var row = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
            var review = Ui.T("Review →", 11.5, FontWeights.Medium, Ui.Brush("AppAccent"));
            review.Cursor = System.Windows.Input.Cursors.Hand;
            DockPanel.SetDock(review, Dock.Right);
            review.MouseLeftButtonDown += (_, _) => Model.ShowPage("Safe to Review");
            row.Children.Add(review);
            var text = new StackPanel();
            text.Children.Add(Ui.T(g.Category, 12.5, FontWeights.Medium));
            text.Children.Add(Ui.Faint($"{g.Count:N0} locations"));
            row.Children.Add(text);
            var sizeText = Ui.T(ByteFormat.Format(g.Bytes), 12, FontWeights.SemiBold);
            DockPanel.SetDock(sizeText, Dock.Right);
            row.Children.Add(sizeText);
            body.Children.Add(row);
        }
        return Ui.HeadedCard(Icons.SafeReview, Ui.Brush("AppSuccessBg"), Ui.Brush("AppSuccess"),
            "Largest opportunities", "Regenerable data you can usually remove", body,
            new Thickness(0));
    }
}
