using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using DiskMap.Core;

namespace DiskMap.App.Pages;

/// <summary>
/// Content-based duplicate groups. "Shared extents" groups (block clones /
/// hardlinks) show reclaimable-bytes that only materialize when every copy
/// is staged — same rule as the macOS build.
/// </summary>
public sealed class DuplicatesPage : ListPage
{
    private bool _running;

    protected override void Refresh()
    {
        Root.Children.Clear();
        Root.Children.Add(Title("Duplicates"));
        if (Model.Tree is null)
        {
            Root.Children.Add(new TextBlock { Text = "Scan a folder first." });
            return;
        }
        var run = SmallButton(_running ? "Scanning…" : "Find duplicates", async () =>
        {
            _running = true; Refresh();
            var candidates = DuplicateFinder.Candidates(Model.Tree, Model.RootPath!);
            Model.Duplicates = await DuplicateFinder.FindDuplicatesAsync(candidates);
            _running = false; Refresh();
        });
        run.IsEnabled = !_running;
        Root.Children.Add(Row(run, new TextBlock { Text = $"{Model.Duplicates.Count} groups", VerticalAlignment = VerticalAlignment.Center }));

        int shown = 0;
        foreach (var group in Model.Duplicates)
        {
            if (shown++ > 50) { Root.Children.Add(new TextBlock { Text = $"… and {Model.Duplicates.Count - shown} more" }); break; }
            var border = new Border { BorderBrush = (Brush)Application.Current.Resources["AppBorder"], BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(4), Padding = new Thickness(8), Margin = new Thickness(0, 6, 0, 6) };
            var panel = new StackPanel();
            string kind = group.SharesStorage ? "shared storage (clone/hardlink)" : "content duplicates";
            panel.Children.Add(new TextBlock { Text = $"{group.FileIDs.Count} copies · {ByteFormat.Format(group.SizeEach)} each · {kind}", FontWeight = FontWeights.SemiBold });
            int? keeper = group.DefaultKeeperId(id => Model.Tree!.ModifiedDay[id]);
            foreach (var id in group.FileIDs)
            {
                var row = new DockPanel();
                var check = new CheckBox { IsChecked = id != keeper, VerticalAlignment = VerticalAlignment.Center };
                int capturedId = id;
                check.Checked += (_, _) => { };
                var path = new TextBlock { Text = Model.PathOf(id), Margin = new Thickness(8, 0, 0, 0), TextTrimming = TextTrimming.CharacterEllipsis };
                if (id == keeper) path.Text += "  (keeps — oldest)";
                DockPanel.SetDock(check, Dock.Left);
                row.Children.Add(check); row.Children.Add(path);
                row.Tag = (capturedId, check);
                panel.Children.Add(row);
            }
            var stageAll = SmallButton("Stage checked", () =>
            {
                var rows = panel.Children.OfType<DockPanel>();
                foreach (var r in rows)
                {
                    var (id, check) = ((int, CheckBox))r.Tag;
                    if (check.IsChecked == true)
                        Model.Stage(id, "duplicate", group.Hash, group.FileIDs.Count);
                }
            });
            panel.Children.Add(stageAll);
            border.Child = panel;
            Root.Children.Add(border);
        }
    }
}

/// <summary>Regenerable directories matched against the bundled pattern list.</summary>
public sealed class QuickWinsPage : ListPage
{
    protected override void Refresh()
    {
        Root.Children.Clear();
        Root.Children.Add(Title("Quick Wins"));
        if (Model.Tree is null)
        {
            Root.Children.Add(new TextBlock { Text = "Scan a folder first." });
            return;
        }
        var hits = QuickWins.Find(Model.Tree, Model.RootPath!, QuickWins.BundledPatterns());
        Model.QuickWinsHits = hits;
        if (hits.Count == 0)
        {
            Root.Children.Add(new TextBlock
            {
                Text = "No Quick Wins in this scan. The list is quick-wins-patterns.json — " +
                       "directory names like node_modules, plus cache paths.",
                Foreground = Subtle, TextWrapping = TextWrapping.Wrap,
            });
            return;
        }

        var checkedIds = new HashSet<int>();
        var summary = new TextBlock { Foreground = Subtle, VerticalAlignment = VerticalAlignment.Center };
        var stageBtn = new Button { Content = "Stage Selected", Padding = new Thickness(10, 4, 10, 4), IsEnabled = false };
        long CheckedSize() => checkedIds.Sum(id => Model.Totals[id]);
        void UpdateSummary()
        {
            summary.Text = $"{hits.Count} regenerable folders · {ByteFormat.Format(CheckedSize())} selected";
            stageBtn.IsEnabled = checkedIds.Count > 0;
        }

        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };
        DockPanel.SetDock(stageBtn, Dock.Right);
        header.Children.Add(stageBtn);
        header.Children.Add(summary);
        Root.Children.Add(header);
        UpdateSummary();

        foreach (var group in hits.GroupBy(h => h.Category).OrderByDescending(g => g.Sum(h => Model.Totals[h.Id])))
        {
            Root.Children.Add(new TextBlock
            {
                Text = $"{group.Key} · {ByteFormat.Format(group.Sum(h => Model.Totals[h.Id]))}",
                FontWeight = FontWeights.SemiBold, Foreground = Subtle, Margin = new Thickness(0, 10, 0, 2),
            });
            foreach (var hit in group)
            {
                var row = new DockPanel { Margin = new Thickness(0, 2, 0, 2) };
                var check = new CheckBox { VerticalAlignment = VerticalAlignment.Center };
                int captured = hit.Id;
                check.Checked += (_, _) => { checkedIds.Add(captured); UpdateSummary(); };
                check.Unchecked += (_, _) => { checkedIds.Remove(captured); UpdateSummary(); };
                var path = new TextBlock { Text = Model.PathOf(hit.Id), TextTrimming = TextTrimming.CharacterEllipsis };
                var size = new TextBlock { Text = ByteFormat.Format(Model.Totals[hit.Id]), Width = 90, Foreground = Subtle };
                DockPanel.SetDock(check, Dock.Left);
                DockPanel.SetDock(size, Dock.Right);
                row.Children.Add(check); row.Children.Add(size); row.Children.Add(path);
                Root.Children.Add(row);
            }
        }

        stageBtn.Click += (_, _) =>
        {
            foreach (var id in checkedIds) Model.Stage(id, "quick win");
        };
    }
}

/// <summary>Installed apps (registry Uninstall hives) + heuristic leftovers.</summary>
public sealed class AppsPage : ListPage
{
    private readonly List<InstalledApp> _apps = AppLeftoverFinder.InstalledApplications();
    private readonly TextBox _filter = new() { Width = 240, Margin = new Thickness(0, 0, 0, 10) };
    private readonly StackPanel _list = new();

    public AppsPage()
    {
        _filter.TextChanged += (_, _) => RenderList();
        _filter.SetValue(System.Windows.Controls.Primitives.TextBoxBase.TagProperty, "Filter apps…");
        var hint = new TextBlock { Text = "Filter:", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
        var top = new DockPanel();
        DockPanel.SetDock(hint, Dock.Left);
        top.Children.Add(hint); top.Children.Add(_filter);
        Root.Children.Add(Title("Apps"));
        Root.Children.Add(top);
        Root.Children.Add(_list);
        RenderList();
    }

    private void RenderList()
    {
        _list.Children.Clear();
        string q = _filter.Text.Trim();
        foreach (var app in _apps.Where(a => q.Length == 0 || a.Name.Contains(q, StringComparison.OrdinalIgnoreCase)).Take(200))
        {
            var expander = new Expander { Header = app.Name, Margin = new Thickness(0, 2, 0, 2) };
            var details = new StackPanel { Margin = new Thickness(16, 4, 0, 4) };
            var captured = app;
            expander.Expanded += async (_, _) =>
            {
                details.Children.Clear();
                details.Children.Add(new TextBlock { Text = "Searching for leftovers…" });
                var leftovers = await Task.Run(() => AppLeftoverFinder.FindLeftovers(captured));
                details.Children.Clear();
                details.Children.Add(new TextBlock { Text = $"Install: {(captured.InstallLocation is { Length: >0 } l ? l : "unknown")} · {ByteFormat.Format(leftovers.InstallSize)}" });
                if (leftovers.LeftoverPaths.Count == 0)
                {
                    details.Children.Add(new TextBlock { Text = "No leftovers found.", Foreground = Subtle });
                }
                foreach (var path in leftovers.LeftoverPaths.Take(30))
                {
                    var row = new DockPanel { Margin = new Thickness(0, 2, 0, 2) };
                    var name = new TextBlock { Text = path, TextTrimming = TextTrimming.CharacterEllipsis };
                    var stage = SmallButton("Stage", () =>
                    {
                        if (Model.Cleanup.Stage(path, AppLeftoverFinder.AllocatedSize(path), $"leftover: {captured.Name}"))
                            Model.RefreshStaged();
                    });
                    var reveal = SmallButton("Reveal", () => Explorer.Reveal(path));
                    var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
                    buttons.Children.Add(reveal);
                    buttons.Children.Add(new Border { Width = 6 });
                    buttons.Children.Add(stage);
                    DockPanel.SetDock(buttons, Dock.Right);
                    row.Children.Add(buttons); row.Children.Add(name);
                    details.Children.Add(row);
                }
            };
            _list.Children.Add(expander);
        }
    }

    protected override void Refresh() { /* list renders on expand/filter, not per scan */ }
}

/// <summary>Save snapshots of the current scan, list prior ones, diff two.</summary>
public sealed class SnapshotsPage : ListPage
{
    private readonly ListBox _list = new() { MinHeight = 160, Margin = new Thickness(0, 8, 0, 8) };
    private readonly StackPanel _diff = new();

    public SnapshotsPage()
    {
        Root.Children.Add(Title("Snapshots"));
        var save = SmallButton("Save snapshot of current scan", SaveSnapshot);
        Root.Children.Add(save);
        Root.Children.Add(_list);
        var compare = SmallButton("Compare selected with current", CompareSelected);
        Root.Children.Add(compare);
        Root.Children.Add(_diff);
        Model.StateChanged += (_, _) => Dispatcher.InvokeAsync(RefreshList);
        Loaded += (_, _) => RefreshList();
    }

    protected override void Refresh() => RefreshList();

    private void RefreshList()
    {
        _list.Items.Clear();
        if (Model.RootPath is null) return;
        foreach (var (path, header) in SnapshotStore.Summaries(SnapshotStore.DefaultDirectory(), Model.RootPath))
        {
            _list.Items.Add(new ListBoxItem { Content = $"{header.CapturedAt.LocalDateTime:g}", Tag = path });
        }
    }

    private void SaveSnapshot()
    {
        if (Model.Tree is null || Model.RootPath is null) return;
        var snap = new DiskSnapshot(Model.RootPath, DateTimeOffset.Now, Model.Tree);
        SnapshotStore.Save(snap, SnapshotStore.DefaultDirectory());
        RefreshList();
    }

    private void CompareSelected()
    {
        _diff.Children.Clear();
        if (_list.SelectedItem is not ListBoxItem { Tag: string path } || Model.Tree is null || Model.RootPath is null)
        {
            _diff.Children.Add(new TextBlock { Text = "Select a snapshot to compare." });
            return;
        }
        var before = SnapshotStore.Load(path);
        var after = new DiskSnapshot(Model.RootPath, DateTimeOffset.Now, Model.Tree);
        var changes = SnapshotDiff.Changes(before, after, Model.SizeBasis);
        if (changes.Count == 0)
        {
            _diff.Children.Add(new TextBlock { Text = "No folder size changes." });
            return;
        }
        foreach (var c in changes.Take(100))
        {
            string sign = c.Delta >= 0 ? "+" : "";
            _diff.Children.Add(Row(
                new TextBlock { Text = $"{sign}{ByteFormat.Format(Math.Abs(c.Delta))}", Width = 90, Foreground = c.Delta > 0 ? Brushes.DarkRed : Brushes.DarkGreen },
                new TextBlock { Text = c.Path, TextTrimming = TextTrimming.CharacterEllipsis }));
        }
    }
}

/// <summary>The staged cleanup queue — review before Recycle Bin commit.</summary>
public sealed class CleanupQueuePage : ListPage
{
    protected override void Refresh()
    {
        Root.Children.Clear();
        Root.Children.Add(Title("Cleanup Queue"));
        var items = Model.StagedItems;
        if (items.Count == 0)
        {
            Root.Children.Add(new TextBlock { Text = "Nothing staged. Right-click items in any view to stage them." });
            return;
        }
        Root.Children.Add(new TextBlock
        {
            Text = $"{items.Count} items staged · {ByteFormat.Format(Model.Cleanup.TotalSize())} would be freed",
            FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 8),
        });
        // Grouped by staging reason, like the macOS CleanupQueueView.
        foreach (var group in items.GroupBy(i => i.Reason).OrderByDescending(g => g.Sum(i => i.Size)))
        {
            Root.Children.Add(new TextBlock
            {
                Text = $"{group.Key} · {ByteFormat.Format(group.Sum(i => i.Size))}",
                FontWeight = FontWeights.SemiBold, Foreground = Subtle, Margin = new Thickness(0, 10, 0, 2),
            });
            foreach (var item in group)
            {
                var row = new DockPanel { Margin = new Thickness(0, 3, 0, 3) };
                var name = new TextBlock { Text = item.Path, TextTrimming = TextTrimming.CharacterEllipsis };
                var meta = new TextBlock { Text = ByteFormat.Format(item.Size), Width = 90, Foreground = Subtle };
                var unstage = SmallButton("Unstage", () => Model.Unstage(item.Id));
                var reveal = SmallButton("Reveal", () => Explorer.Reveal(item.Path));
                var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
                buttons.Children.Add(reveal);
                buttons.Children.Add(new Border { Width = 6 });
                buttons.Children.Add(unstage);
                DockPanel.SetDock(buttons, Dock.Right);
                DockPanel.SetDock(meta, Dock.Right);
                row.Children.Add(buttons); row.Children.Add(meta); row.Children.Add(name);
                Root.Children.Add(row);
            }
        }
        var commit = new Button
        {
            Content = "Commit to Recycle Bin",
            Margin = new Thickness(0, 12, 0, 0), Padding = new Thickness(12, 6, 12, 6),
            FontWeight = FontWeights.SemiBold,
        };
        commit.Click += async (_, _) =>
        {
            var confirm = MessageBox.Show(
                $"Move {items.Count} staged items to the Recycle Bin?\n\nThis is recoverable — items stay in the Recycle Bin until emptied.",
                "Confirm cleanup", MessageBoxButton.YesNo, MessageBoxImage.Warning);
            if (confirm != MessageBoxResult.Yes) return;
            var results = await Task.Run(() => Model.Cleanup.Commit());
            int failed = results.Count(r => r.Error is not null);
            Model.RefreshStaged();
            MessageBox.Show(
                failed == 0 ? $"Done. {results.Count} items moved to the Recycle Bin."
                            : $"{results.Count - failed} recycled, {failed} failed (left staged).",
                "Cleanup", MessageBoxButton.OK,
                failed == 0 ? MessageBoxImage.Information : MessageBoxImage.Warning);
        };
        Root.Children.Add(commit);
    }
}
