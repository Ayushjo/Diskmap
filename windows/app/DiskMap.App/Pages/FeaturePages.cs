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
        if (Model.Tree is not { } tree || Model.RootPath is not { } rootPath)
        {
            Root.Children.Add(new TextBlock { Text = "Scan a folder first." });
            return;
        }
        var run = SmallButton(_running ? "Scanning…" : "Find duplicates", async () =>
        {
            _running = true;
            Refresh();
            try
            {
                // Paths only for files sharing a size, then hashing — all off the UI thread.
                Model.Duplicates = await Task.Run(() =>
                    DuplicateFinder.FindDuplicatesAsync(DuplicateFinder.SizeCollidingCandidates(tree, rootPath)));
            }
            finally
            {
                _running = false;
                Refresh();
            }
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
            int? keeper = group.DefaultKeeperId(id => tree.ModifiedDay[id]);
            var checks = new List<(int Id, CheckBox Check)>();
            foreach (var id in group.FileIDs)
            {
                var row = new DockPanel();
                var check = new CheckBox { IsChecked = id != keeper, VerticalAlignment = VerticalAlignment.Center };
                var path = new TextBlock { Text = Model.PathOf(id), Margin = new Thickness(8, 0, 0, 0), TextTrimming = TextTrimming.CharacterEllipsis };
                if (id == keeper) path.Text += "  (keeps — oldest)";
                DockPanel.SetDock(check, Dock.Left);
                row.Children.Add(check); row.Children.Add(path);
                checks.Add((id, check));
                panel.Children.Add(row);
            }
            var stageAll = SmallButton("Stage checked", () =>
            {
                foreach (var (id, check) in checks)
                    if (check.IsChecked == true)
                        Model.Stage(id, "duplicate", group.Hash, group.FileIDs.Count);
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
    private const int MaxRows = 400;

    protected override void Refresh()
    {
        Root.Children.Clear();
        Root.Children.Add(Title("Quick Wins"));
        if (Model.Tree is not { } tree || Model.RootPath is not { } rootPath || Model.Totals.Length == 0)
        {
            Root.Children.Add(new TextBlock { Text = "Scan a folder first." });
            return;
        }
        var totals = Model.Totals;
        Root.Children.Add(Working("Looking for regenerable folders…"));
        Compute(() =>
        {
            var hits = QuickWins.Find(tree, rootPath, QuickWins.BundledPatterns());
            return hits
                .GroupBy(h => h.Category)
                .Select(g => (Category: g.Key,
                              Size: g.Sum(h => totals[h.Id]),
                              Hits: g.OrderByDescending(h => totals[h.Id]).Select(h => (h.Id, Path: tree.PathOf(h.Id, rootPath))).ToList()))
                .OrderByDescending(g => g.Size)
                .ToList();
        }, groups => Show(totals, groups));
    }

    private void Show(long[] totals, List<(string Category, long Size, List<(int Id, string Path)> Hits)> groups)
    {
        Root.Children.RemoveAt(Root.Children.Count - 1);
        int hitCount = groups.Sum(g => g.Hits.Count);
        if (hitCount == 0)
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
        void UpdateSummary()
        {
            summary.Text = $"{hitCount:N0} regenerable folders · {ByteFormat.Format(checkedIds.Sum(id => totals[id]))} selected";
            stageBtn.IsEnabled = checkedIds.Count > 0;
        }

        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };
        DockPanel.SetDock(stageBtn, Dock.Right);
        header.Children.Add(stageBtn);
        header.Children.Add(summary);
        Root.Children.Add(header);
        UpdateSummary();

        int rows = 0;
        foreach (var (category, size, hits) in groups)
        {
            Root.Children.Add(new TextBlock
            {
                Text = $"{category} · {ByteFormat.Format(size)}",
                FontWeight = FontWeights.SemiBold, Foreground = Subtle, Margin = new Thickness(0, 10, 0, 2),
            });
            foreach (var (id, fullPath) in hits)
            {
                // Thousands of rows in a non-virtualized panel is what made this page crawl.
                if (rows++ == MaxRows)
                {
                    Root.Children.Add(new TextBlock { Text = $"… {hitCount - MaxRows:N0} smaller folders not shown", Foreground = Subtle });
                    break;
                }
                var row = new DockPanel { Margin = new Thickness(0, 2, 0, 2) };
                var check = new CheckBox { VerticalAlignment = VerticalAlignment.Center };
                int captured = id;
                check.Checked += (_, _) => { checkedIds.Add(captured); UpdateSummary(); };
                check.Unchecked += (_, _) => { checkedIds.Remove(captured); UpdateSummary(); };
                var path = new TextBlock { Text = fullPath, TextTrimming = TextTrimming.CharacterEllipsis };
                var sizeText = new TextBlock { Text = ByteFormat.Format(totals[id]), Width = 90, Foreground = Subtle };
                DockPanel.SetDock(check, Dock.Left);
                DockPanel.SetDock(sizeText, Dock.Right);
                row.Children.Add(check); row.Children.Add(sizeText); row.Children.Add(path);
                Root.Children.Add(row);
            }
            if (rows > MaxRows) break;
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
    private List<InstalledApp>? _apps;
    private readonly TextBox _filter = new() { Width = 240, Margin = new Thickness(0, 0, 0, 10) };
    private readonly StackPanel _list = new();

    public AppsPage()
    {
        _filter.TextChanged += (_, _) => RenderList();
        var hint = new TextBlock { Text = "Filter:", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
        var top = new DockPanel();
        DockPanel.SetDock(hint, Dock.Left);
        top.Children.Add(hint); top.Children.Add(_filter);
        Root.Children.Add(Title("Apps"));
        Root.Children.Add(top);
        Root.Children.Add(_list);
    }

    /// <summary>The app list doesn't depend on the scan: read the registry once, off the UI thread.</summary>
    protected override void Refresh()
    {
        if (_apps is not null) return;
        _list.Children.Add(Working("Reading installed apps…"));
        Compute(AppLeftoverFinder.InstalledApplications, apps =>
        {
            _apps = apps;
            RenderList();
        });
    }

    private void RenderList()
    {
        if (_apps is null) return;
        _list.Children.Clear();
        string q = _filter.Text.Trim();
        foreach (var app in _apps.Where(a => q.Length == 0 || a.Name.Contains(q, StringComparison.OrdinalIgnoreCase)).Take(200))
        {
            var expander = new Expander { Header = app.Name, Margin = new Thickness(0, 2, 0, 2) };
            var details = new StackPanel { Margin = new Thickness(16, 4, 0, 4) };
            expander.Content = details; // was never attached, so expanding showed nothing
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
                    var stage = SmallButton("Stage", async () =>
                    {
                        long size = await Task.Run(() => AppLeftoverFinder.AllocatedSize(path));
                        if (Model.Cleanup.Stage(path, size, $"leftover: {captured.Name}"))
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
}

/// <summary>Save snapshots of the current scan, list prior ones, diff two.</summary>
public sealed class SnapshotsPage : ListPage
{
    private readonly ListBox _list = new() { MinHeight = 160, Margin = new Thickness(0, 8, 0, 8) };
    private readonly StackPanel _diff = new();
    private readonly TextBlock _status = new() { Margin = new Thickness(0, 4, 0, 0) };

    public SnapshotsPage()
    {
        Root.Children.Add(Title("Snapshots"));
        Root.Children.Add(SmallButton("Save snapshot of current scan", SaveSnapshot));
        Root.Children.Add(_status);
        Root.Children.Add(_list);
        Root.Children.Add(SmallButton("Compare selected with current", CompareSelected));
        Root.Children.Add(_diff);
    }

    protected override void Refresh()
    {
        _list.Items.Clear();
        if (Model.RootPath is null) return;
        foreach (var (path, header) in SnapshotStore.Summaries(SnapshotStore.DefaultDirectory(), Model.RootPath))
        {
            _list.Items.Add(new ListBoxItem { Content = $"{header.CapturedAt.LocalDateTime:g}", Tag = path });
        }
    }

    private async void SaveSnapshot()
    {
        if (Model.Tree is not { } tree || Model.RootPath is not { } rootPath) return;
        _status.Text = "Saving…";
        try
        {
            // Encoding a multi-million-node tree takes seconds: never on the UI thread.
            await Task.Run(() => SnapshotStore.Save(new DiskSnapshot(rootPath, DateTimeOffset.Now, tree), SnapshotStore.DefaultDirectory()));
            _status.Text = "Saved.";
        }
        catch (Exception ex)
        {
            _status.Text = $"Save failed: {ex.Message}";
        }
        Refresh();
    }

    private async void CompareSelected()
    {
        _diff.Children.Clear();
        if (_list.SelectedItem is not ListBoxItem { Tag: string path } || Model.Tree is not { } tree || Model.RootPath is not { } rootPath)
        {
            _diff.Children.Add(new TextBlock { Text = "Select a snapshot to compare." });
            return;
        }
        var basis = Model.SizeBasis;
        _diff.Children.Add(Working("Comparing…"));
        List<SnapshotChange> changes;
        try
        {
            changes = await Task.Run(() => SnapshotDiff.Changes(
                SnapshotStore.Load(path), new DiskSnapshot(rootPath, DateTimeOffset.Now, tree), basis));
        }
        catch (Exception ex)
        {
            _diff.Children.Clear();
            _diff.Children.Add(new TextBlock { Text = $"Compare failed: {ex.Message}" });
            return;
        }
        _diff.Children.Clear();
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
                var unstage = SmallButton("Unstage", () =>
                {
                    Model.Unstage(item.Id);
                    Refresh();
                });
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
            commit.IsEnabled = false;
            var results = await Task.Run(() => Model.Cleanup.Commit());
            int failed = results.Count(r => r.Error is not null);
            Model.RefreshStaged();
            Refresh();
            MessageBox.Show(
                failed == 0 ? $"Done. {results.Count} items moved to the Recycle Bin."
                            : $"{results.Count - failed} recycled, {failed} failed (left staged).",
                "Cleanup", MessageBoxButton.OK,
                failed == 0 ? MessageBoxImage.Information : MessageBoxImage.Warning);
        };
        Root.Children.Add(commit);
    }
}
