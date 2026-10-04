using System.Collections.Concurrent;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using DiskMap.Core;
using Microsoft.Win32;

namespace DiskMap.App.Pages;

/// <summary>
/// Safe to Review — the landing for the Clean section: how much is
/// reviewable overall, and a card per review category that drills into
/// its own page.
/// </summary>
public sealed class SafeToReviewPage : ListPage
{
    protected override void Refresh()
    {
        Root.Children.Clear();
        Root.Children.Add(Header("Safe to Review",
            "Data that's usually fine to remove — review it, select what to clear, send it to the Recycle Bin.",
            glyph: Icons.SafeReview, iconBg: Ui.Brush("AppSuccessBg"), iconFg: Ui.Brush("AppSuccess")));
        if (Model.Tree is not { } tree || Model.Totals.Length != tree.Count)
        {
            Root.Children.Add(NeedsScan("Safe-to-review candidates come from the scan."));
            return;
        }
        var totals = Model.Totals;
        Root.Children.Add(Working("Measuring…"));
        Compute(() =>
        {
            var hits = Model.QuickWins ?? [];
            var byCategory = hits.GroupBy(h => h.Category)
                .Select(g => (Category: g.Key, Bytes: g.Sum(h => totals[h.Id]), Count: g.Count()))
                .ToList();
            return (byCategory, total: byCategory.Sum(g => g.Bytes));
        }, data =>
        {
            Root.Children.RemoveAt(Root.Children.Count - 1);

            Root.Children.Add(Ui.StatRow(
                Ui.StatCard(Icons.Caches, Ui.DataTint(3), Ui.Data(3),
                    ByteFormat.Format(data.total), "Reviewable",
                    $"across {data.byCategory.Sum(g => g.Count):N0} locations")));

            var section = new StackPanel();
            section.Children.Add(Ui.SectionHeader("Review a category"));
            section.Children.Add(Ui.Gap(8));
            var grid = new UniformGrid { Columns = 2, Margin = new Thickness(0, 0, 0, Ui.ZoneGap) };
            foreach (var (title, blurb, page, glyph, color) in new (string, string, string, string, int)[]
            {
                ("Caches", "App and system caches — recreated on demand", "Caches", Icons.Caches, 3),
                ("Old Downloads", "Installers and archives you already used", "Old Downloads", Icons.Downloads, 2),
                ("Large Media", "Videos, images and audio over 100 MB", "Large Media", Icons.Media, 2),
                ("Developer Storage", "Dependencies, build outputs and tool caches", "Developer Storage", Icons.Developer, 0),
            })
            {
                var row = new DockPanel { MinHeight = 56 };
                var arrow = Ui.Glyph(Icons.Forward, 16, Ui.Brush("AppFaint"));
                DockPanel.SetDock(arrow, Dock.Right);
                row.Children.Add(arrow);
                var tile = Ui.IconTile(glyph, 32, Ui.DataTint(color), Ui.Data(color), 7);
                tile.Margin = new Thickness(0, 0, 12, 0);
                DockPanel.SetDock(tile, Dock.Left);
                row.Children.Add(tile);
                var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
                text.Children.Add(Ui.T(title, 13, FontWeights.Medium));
                text.Children.Add(Ui.Faint(blurb));
                row.Children.Add(text);
                string captured = page;
                var nav = Ui.HoverRow(row, () => Model.ShowPage(captured));
                nav.Margin = new Thickness(0, 0, 8, 4);
                grid.Children.Add(nav);
            }
            section.Children.Add(grid);
            Root.Children.Add(section);

            // Everything else the scanner flagged, listed inline.
            var other = new StackPanel();
            foreach (var g in data.byCategory.OrderByDescending(g => g.Bytes))
            {
                var row = new DockPanel { Margin = new Thickness(0, 4, 0, 4) };
                var size = Ui.T(ByteFormat.Format(g.Bytes), 12, FontWeights.SemiBold);
                DockPanel.SetDock(size, Dock.Right);
                row.Children.Add(size);
                var text = new StackPanel();
                text.Children.Add(Ui.T(g.Category, 12.5, FontWeights.Medium));
                text.Children.Add(Ui.Faint($"{g.Count:N0} locations"));
                row.Children.Add(text);
                other.Children.Add(row);
            }
            if (data.byCategory.Count > 0)
                Root.Children.Add(Ui.HeadedCard(Icons.List, Ui.Brush("AppHover"), Ui.Brush("AppSubtle"),
                    "Regenerable by category", "Grouped quick-win findings", other));
        });
    }
}

/// <summary>
/// Caches — the "usually safe" slice of the scan: quick-win hits whose
/// category is a cache. Checkboxes + a bottom selection bar, mirroring
/// the reference layout.
/// </summary>
public sealed class CachesPage : ListPage
{
    private static readonly HashSet<string> CacheCategories = new(StringComparer.Ordinal)
        { "System caches", "Development caches" };

    private readonly HashSet<int> _checked = [];

    protected override void Refresh()
    {
        Root.Children.Clear();
        Root.Children.Add(Header("Caches",
            "Temporary application data that can usually be cleared. Apps recreate these files when needed.",
            glyph: Icons.Caches, iconBg: Ui.Hex("#F3E8FF"), iconFg: Ui.Hex("#7C3AED")));
        if (Model.Tree is not { } tree || Model.Totals.Length != tree.Count)
        {
            Root.Children.Add(NeedsScan("Cache findings come from the scan."));
            return;
        }
        var totals = Model.Totals;
        Root.Children.Add(Working("Measuring…"));
        Compute(() =>
            (Model.QuickWins ?? [])
                .Where(h => CacheCategories.Contains(h.Category))
                .OrderByDescending(h => totals[h.Id])
                .ToList(), hits =>
        {
            Root.Children.RemoveAt(Root.Children.Count - 1);
            if (hits.Count == 0)
            {
                Root.Children.Add(Ui.Subtle("No cache locations found in this scan."));
                return;
            }

            // Summary card: total + per-category bar.
            long total = hits.Sum(h => totals[h.Id]);
            var parts = hits.GroupBy(h => h.Category)
                .Select((g, i) => (g.Key, g.Sum(h => totals[h.Id]), Ui.Data(i + 3)))
                .ToList();
            var summary = new DockPanel();
            var left = new StackPanel { Margin = new Thickness(0, 0, 24, 0), VerticalAlignment = VerticalAlignment.Center };
            left.Children.Add(Ui.IconTile(Icons.Caches, 44, Ui.DataTint(3), Ui.Data(3), 10));
            var lt = new StackPanel { Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            lt.Children.Add(Ui.T(ByteFormat.Format(total), 20, FontWeights.Bold));
            lt.Children.Add(Ui.Subtle($"across {hits.Count:N0} locations", 11.5));
            left.Children.Add(lt);
            DockPanel.SetDock(left, Dock.Left);
            summary.Children.Add(left);
            var legendWrap = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            legendWrap.Children.Add(Ui.TypeBarWithLegend(
                parts.Select(p => (p.Key == "System caches" ? "System" : "Developer caches", p.Item2, p.Item3)).ToList(),
                total));
            summary.Children.Add(legendWrap);
            Root.Children.Add(Ui.Card(summary, 16));

            // Table.
            var table = new StackPanel();
            table.Children.Add(Ui.TableHeader(
                ("", new GridLength(28), false),
                ("Location", new GridLength(1, GridUnitType.Star), false),
                ("Category", new GridLength(150), false),
                ("Size", new GridLength(90), true),
                ("Safety", new GridLength(120), false),
                ("", new GridLength(36), false)));
            foreach (var hit in hits.Take(300))
                table.Children.Add(CacheRow(tree, totals, hit));
            Root.Children.Add(Ui.Card(table, 12));
            Root.Children.Add(SelectionBar(hits, totals));
        });
    }

    private UIElement CacheRow(FileTree tree, long[] totals, QuickWins.Hit hit)
    {
        var outer = new Border { CornerRadius = new CornerRadius(6), Background = Brushes.Transparent };
        var row = Ui.TableRowGrid(
            new GridLength(28), new GridLength(1, GridUnitType.Star), new GridLength(150),
            new GridLength(90), new GridLength(120), new GridLength(36));
        outer.Child = row;
        var check = new CheckBox { IsChecked = _checked.Contains(hit.Id), VerticalAlignment = VerticalAlignment.Center };
        check.Checked += (_, _) => { _checked.Add(hit.Id); _repaintBar?.Invoke(); };
        check.Unchecked += (_, _) => { _checked.Remove(hit.Id); _repaintBar?.Invoke(); };
        Ui.Cell(row, check, 0);
        Ui.Cell(row, Ui.NameCell(Icons.Caches, Ui.DataTint(3), Ui.Data(3),
            hit.Name, Model.DisplayPath(hit.Id), 26), 1);
        Ui.Cell(row, Ui.Subtle(hit.Category, 11.5), 2);
        Ui.Cell(row, Ui.T(ByteFormat.Format(totals[hit.Id]), 12), 3, right: true);
        Ui.Cell(row, Ui.SafetyBadge(true), 4);
        Ui.Cell(row, Ui.MoreButton(() =>
        {
            Model.Select(hit.Id);
            Explorer.Reveal(Model.PathOf(hit.Id));
        }), 5, right: true);
        outer.MouseLeftButtonDown += (_, _) => Model.Select(hit.Id);
        outer.Cursor = System.Windows.Input.Cursors.Hand;
        return outer;
    }

    /// <summary>"1 selected · 6.82 GB — Reveal / Add to Cleanup" bar.</summary>
    private Border SelectionBar(List<QuickWins.Hit> hits, long[] totals)
    {
        var bar = new DockPanel();
        bar.Children.Add(Ui.Subtle("", 12));
        void Repaint()
        {
            var selected = hits.Where(h => _checked.Contains(h.Id)).ToList();
            long bytes = selected.Sum(h => totals[h.Id]);
            ((DockPanel)bar).Children.Clear();
            var left = Ui.T($"{selected.Count} selected · {ByteFormat.Format(bytes)}", 12.5, FontWeights.Medium);
            left.VerticalAlignment = VerticalAlignment.Center;
            DockPanel.SetDock(left, Dock.Left);
            bar.Children.Add(left);
            var right = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
            DockPanel.SetDock(right, Dock.Right);
            var reveal = Ui.Button("Reveal in Explorer", Icons.Open, Ui.ButtonStyle.Outline,
                () => { if (selected.Count > 0) Explorer.Reveal(Model.PathOf(selected[0].Id)); });
            reveal.IsEnabled = selected.Count > 0;
            right.Children.Add(reveal);
            right.Children.Add(new Border { Width = 8 });
            var add = Ui.Button("Add to Cleanup", null, Ui.ButtonStyle.Primary,
                () =>
                {
                    int added = 0;
                    foreach (var h in selected)
                        if (Model.Stage(h.Id, "caches", notify: false)) added++;
                    _checked.Clear();
                    Repaint();
                    if (added > 0) Model.ToastAdded(added);
                });
            add.IsEnabled = selected.Count > 0;
            right.Children.Add(add);
            bar.Children.Add(right);
        }
        Repaint();
        // Refresh the bar whenever a checkbox flips — piggyback the model's
        // staged-changed event is wrong; hook each row's checkbox via the
        // page's own refresh: simplest is a lightweight timer-free repaint
        // invoked from row toggles — so stash Repaint for the rows.
        _repaintBar = Repaint;
        return Ui.Card(bar, 12, new Thickness(0));
    }

    private Action? _repaintBar;
}

/// <summary>
/// Developer Storage — the dev-shaped slice of quick wins (dependencies,
/// build outputs, caches, toolchains), grouped by ecosystem with a "why
/// it's safe" note, matching the reference page.
/// </summary>
public sealed class DeveloperStoragePage : ListPage
{
    protected override void Refresh()
    {
        Root.Children.Clear();
        Root.Children.Add(Header("Developer Storage",
            "Dependencies, build outputs and tool caches — grouped by project, priced by rebuild cost.",
            glyph: Icons.Developer, iconBg: Ui.Hex("#E0F2FE"), iconFg: Ui.Hex("#0284C7")));
        if (Model.Tree is not { } tree || Model.Totals.Length != tree.Count || Model.RootPath is not { } root)
        {
            Root.Children.Add(NeedsScan("Developer storage comes from the scan."));
            return;
        }
        var totals = Model.Totals;
        Root.Children.Add(Working("Analyzing projects…"));
        Compute(() => DeveloperCatalog.Build(tree, root, totals), result =>
        {
            Root.Children.RemoveAt(Root.Children.Count - 1);
            var summary = result.Summary;
            if (result.Items.Count == 0)
            {
                Root.Children.Add(Ui.Subtle("No developer storage found in this scan."));
                return;
            }

            // Hero stats — the decision numbers, not just bytes.
            var stats = Ui.StatRow(
                Ui.StatCard(Icons.Developer, Ui.DataTint(0), Ui.Data(0),
                    ByteFormat.Format(summary.TotalBytes),
                    "Developer storage", $"{summary.ItemCount:N0} locations"),
                Ui.StatCard(Icons.SafeReview, Ui.Brush("AppSuccessBg"), Ui.Brush("AppSuccess"),
                    ByteFormat.Format(summary.ReclaimableBytes),
                    "Reclaimable or reviewable", $"{summary.ReclaimableFraction * 100:0}% of the total"),
                Ui.StatCard(Icons.Forgotten, Ui.Hex("#FEF3DE"), Ui.Hex("#B45309"),
                    ByteFormat.Format(summary.StaleReclaimableBytes),
                    $"{summary.StaleProjectCount:N0} stale projects", "no source change in 6+ months"),
                Ui.StatCard(Icons.Warning, Ui.Hex("#FDECEC"), Ui.Hex("#DC2626"),
                    ByteFormat.Format(summary.UnpinnedBytes),
                    "Unpinned dependencies", "no lockfile — may not reinstall the same"));
            Root.Children.Add(stats);

            // Category strip.
            if (summary.Categories.Count > 0)
            {
                var strip = new StackPanel();
                strip.Children.Add(Ui.TypeBarWithLegend(
                    summary.Categories
                        .Select((c, i) => (c.Category.Title(), c.Bytes, Ui.Data(i) as Brush)).ToList(),
                    Math.Max(1, summary.TotalBytes)));
                Root.Children.Add(Ui.Card(strip, 14));
            }

            // Projects — the unit a developer actually reasons about.
            if (result.Projects.Count > 0)
            {
                var body = new StackPanel();
                foreach (var project in result.Projects.Take(20))
                {
                    var panel = new StackPanel { Margin = new Thickness(0, 0, 0, 10) };
                    var top = new DockPanel { Margin = new Thickness(0, 0, 0, 3) };
                    var sizeText = Ui.T(ByteFormat.Format(project.Bytes), 12, FontWeights.Medium);
                    DockPanel.SetDock(sizeText, Dock.Right);
                    top.Children.Add(sizeText);
                    var name = Ui.T(project.Name, 12.5, FontWeights.Medium);
                    if (project.NodeIDs.Count > 0)
                    {
                        int focusId = project.NodeIDs[0];
                        name.Cursor = System.Windows.Input.Cursors.Hand;
                        name.MouseLeftButtonDown += (_, _) => Model.Select(focusId);
                    }
                    top.Children.Add(name);
                    panel.Children.Add(top);

                    var meta = new WrapPanel();
                    if (project.Manifest is { } manifest)
                        meta.Children.Add(Ui.Badge(manifest, Ui.Brush("AppSubtle"), Ui.Brush("AppHover")));
                    meta.Children.Add(Ui.Badge(project.RebuildCost.Title(),
                        Ui.Brush("AppSubtle"), Ui.Brush("AppHover")));
                    meta.Children.Add(Ui.Badge(project.Status, Ui.Brush("AppSubtle"), Ui.Brush("AppHover")));
                    if (project.Lockfile is { } lf)
                        meta.Children.Add(Ui.Badge(lf, Ui.Brush("AppSubtle"), Ui.Brush("AppHover")));
                    foreach (var badge in meta.Children.Cast<UIElement>())
                        ((Border)badge).Margin = new Thickness(0, 0, 6, 0);
                    panel.Children.Add(meta);

                    var detail = new WrapPanel { Margin = new Thickness(0, 4, 0, 0) };
                    detail.Children.Add(Ui.Faint($"{project.Ecosystem.Title()} · {project.ItemCount} folders · {ByteFormat.Format(project.ReclaimableBytes)} reclaimable"));
                    if (project.IgnoredBytes is { } ignored && ignored > 0)
                        detail.Children.Add(Ui.Faint($"  ·  {ByteFormat.Format(ignored)} git-ignored"));
                    panel.Children.Add(detail);

                    var git = new WrapPanel { Margin = new Thickness(0, 2, 0, 0) };
                    git.Children.Add(Ui.Faint(project.Git.Title));
                    panel.Children.Add(git);

                    if (project.ReclaimableBytes > 0)
                    {
                        var stageAll = Ui.Button(
                            $"Add reclaimable ({ByteFormat.Format(project.ReclaimableBytes)}) to Cleanup",
                            Icons.Cleanup, Ui.ButtonStyle.Outline,
                            () =>
                            {
                                int added = 0;
                                foreach (var item in result.Items.Where(i =>
                                    i.ProjectKey == project.Key
                                    && i.Reclaimability != DeveloperReclaimability.Keep
                                    && !i.IsProtected))
                                    if (Model.Stage(item.NodeID, "developer storage", notify: false)) added++;
                                if (added > 0) Model.ToastAdded(added);
                            });
                        stageAll.Margin = new Thickness(0, 6, 0, 0);
                        stageAll.HorizontalAlignment = HorizontalAlignment.Left;
                        stageAll.Padding = new Thickness(10, 3, 10, 3);
                        panel.Children.Add(stageAll);
                    }
                    body.Children.Add(panel);
                }
                if (result.Projects.Count > 20)
                    body.Children.Add(Ui.Faint($"… and {result.Projects.Count - 20:N0} smaller projects"));
                Root.Children.Add(Ui.HeadedCard(Icons.Code, Ui.DataTint(0), Ui.Data(0),
                    "Projects", "Folders that own dependencies or build output", body));
            }

            // All locations, largest first — with recipes where a tool owns one.
            var itemsBody = new StackPanel();
            foreach (var item in result.Items.Take(40))
                itemsBody.Children.Add(ItemRow(tree, totals, item));
            if (result.Items.Count > 40)
                itemsBody.Children.Add(Ui.Faint($"… and {result.Items.Count - 40:N0} smaller locations"));
            Root.Children.Add(Ui.HeadedCard(Icons.Developer, Ui.DataTint(0), Ui.Data(0),
                "All locations", "Every developer-owned folder in the scan", itemsBody));
        });
    }

    private UIElement ItemRow(FileTree tree, long[] totals, DeveloperItem item)
    {
        var outer = new Border
        {
            CornerRadius = new CornerRadius(6), Margin = new Thickness(0, 2, 0, 2),
            Background = Brushes.Transparent,
        };
        var row = Ui.TableRowGrid(
            new GridLength(1, GridUnitType.Star), new GridLength(150),
            new GridLength(80), new GridLength(110));
        outer.Child = row;
        Ui.Cell(row, Ui.NameCell(Icons.Developer, Ui.DataTint(0), Ui.Data(0),
            item.DisplayName, Model.DisplayPath(item.NodeID), 26), 0);
        Ui.Cell(row, Ui.Subtle(item.RebuildCost.Title(), 11), 1);
        Ui.Cell(row, Ui.T(ByteFormat.Format(item.Bytes), 12, FontWeights.Medium), 2, right: true);

        if (item.Recipe is { TrashIsUnsafe: true } recipe)
        {
            // The tool owns this state — steer to its command, not the bin.
            var steer = Ui.T(recipe.Command, 11, null, Ui.Brush("AppAccent"));
            steer.ToolTip = new ToolTip { Content = $"{recipe.Title}: {recipe.Why}\n\nRun: {recipe.Command}" };
            steer.Cursor = System.Windows.Input.Cursors.Hand;
            steer.MouseLeftButtonDown += (_, _) =>
            {
                try { System.Windows.Clipboard.SetText(recipe.Command); } catch { }
                steer.Text = "Copied ✓";
            };
            Ui.Cell(row, steer, 3, right: true);
        }
        else if (!item.IsProtected && item.Reclaimability != DeveloperReclaimability.Keep)
        {
            var stage = Ui.Button("Add to Cleanup", null, Ui.ButtonStyle.Outline,
                () => { Model.Stage(item.NodeID, "developer storage"); });
            stage.Padding = new Thickness(10, 3, 10, 3);
            stage.VerticalAlignment = VerticalAlignment.Center;
            Ui.Cell(row, stage, 3, right: true);
        }
        else
        {
            Ui.Cell(row, Ui.Badge("keep", Ui.Brush("AppSubtle"), Ui.Brush("AppHover")), 3, right: true);
        }

        outer.Cursor = System.Windows.Input.Cursors.Hand;
        outer.MouseLeftButtonDown += (_, e) =>
        {
            if (e.ClickCount >= 2) Model.DrillTo(item.NodeID);
            else Model.Select(item.NodeID);
        };
        return outer;
    }
}

/// <summary>
/// Duplicates — the recoverable-space dashboard and per-group review,
/// same flow as before with the new chrome.
/// </summary>
public sealed class DuplicatesPage : ListPage
{
    protected override void Refresh()
    {
        Root.Children.Clear();
        Root.Children.Add(Header("Duplicates",
            "Files whose content is byte-for-byte identical — keep one copy, review the rest.",
            glyph: Icons.Duplicates, iconBg: Ui.Brush("AppSuccessBg"), iconFg: Ui.Brush("AppSuccess")));
        if (Model.Tree is not { } tree)
        {
            Root.Children.Add(NeedsScan("Duplicate detection needs a scanned tree."));
            return;
        }
        var totals = Model.Totals;
        Root.Children.Add(Working("Finding duplicates… (content hashing runs in the background)"));
        var existing = Model.Duplicates;
        var rootPath = Model.RootPath ?? "";
        Compute(() => existing.Count > 0
            ? existing
            : DuplicateFinder.FindDuplicatesAsync(
                DuplicateFinder.SizeCollidingCandidates(tree, rootPath)).GetAwaiter().GetResult(), groups =>
        {
            Model.Duplicates = groups;
            Model.MarkDuplicatesSearched();
            Root.Children.RemoveAt(Root.Children.Count - 1);
            if (groups.Count == 0)
            {
                Root.Children.Add(Ui.Subtle("No duplicates found — nothing byte-identical above the size floor."));
                return;
            }
            // Every group's recoverable space assumes "keep one, remove rest".
            long recoverable = groups.Sum(g =>
                g.ReclaimableBytes(g.FileIDs.Skip(1).ToHashSet()));
            Root.Children.Add(Ui.StatRow(
                Ui.StatCard(Icons.Duplicates, Ui.Brush("AppHover"), Ui.Brush("AppSubtle"),
                    ByteFormat.Format(recoverable), "Extra copies free",
                    $"{groups.Count:N0} groups · {groups.Sum(g => g.FileIDs.Count):N0} copies")));

            foreach (var group in groups.Take(60))
            {
                var body = new StackPanel();
                int? keeper = group.DefaultKeeperId(id => tree.ModifiedDay[id]);
                var members = group.FileIDs
                    .OrderByDescending(id => tree.ModifiedDay[id]).ToList();
                foreach (var (id, i) in members.Select((m, i) => (m, i)))
                {
                    string path = Model.PathOf(id);
                    bool isKeeper = id == keeper;
                    var rowOuter = new Border
                    {
                        CornerRadius = new CornerRadius(6),
                        Background = Brushes.Transparent,
                        Margin = new Thickness(0, 1, 0, 1),
                    };
                    var row = Ui.TableRowGrid(
                        new GridLength(28), new GridLength(84),
                        new GridLength(1, GridUnitType.Star), new GridLength(110));
                    rowOuter.Child = row;
                    var check = new CheckBox
                    {
                        IsChecked = !isKeeper,
                        IsEnabled = !isKeeper,
                        VerticalAlignment = VerticalAlignment.Center,
                    };
                    Ui.Cell(row, check, 0);
                    UIElement tag = isKeeper
                        ? Ui.SafetyLabel(Ui.Brush("AppSuccess"), "Keeper", 11)
                        : Ui.Subtle("Extra copy", 11);
                    Ui.Cell(row, tag, 1);
                    Ui.Cell(row, Ui.NameCell(Icons.File, Ui.Brush("AppHover"), Ui.Brush("AppSubtle"),
                        Path.GetFileName(path), Path.GetDirectoryName(path), 24), 2);
                    var stage = Ui.Button("Add to Cleanup", null, Ui.ButtonStyle.Outline,
                        () => Model.Stage(id, "duplicate", group.Hash, group.FileIDs.Count));
                    stage.IsEnabled = !isKeeper;
                    stage.Padding = new Thickness(10, 3, 10, 3);
                    stage.VerticalAlignment = VerticalAlignment.Center;
                    Ui.Cell(row, stage, 3, right: true);
                    int capturedId = id;
                    CheckBox capturedCheck = check;
                    rowOuter.Cursor = System.Windows.Input.Cursors.Hand;
                    rowOuter.MouseLeftButtonDown += (_, _) =>
                    {
                        capturedCheck.IsChecked = !(capturedCheck.IsChecked ?? false);
                        Model.Select(capturedId);
                    };
                    body.Children.Add(rowOuter);
                }
                var stageChecked = Ui.Button("Add extra copies to Cleanup", Icons.Cleanup, Ui.ButtonStyle.Primary,
                    () =>
                    {
                        int added = 0;
                        foreach (var memberId in group.FileIDs.Where(m => m != keeper))
                            if (Model.Stage(memberId, "duplicate", group.Hash, group.FileIDs.Count, notify: false)) added++;
                        if (added > 0) Model.ToastAdded(added);
                    });
                stageChecked.Margin = new Thickness(0, 10, 0, 0);
                stageChecked.HorizontalAlignment = HorizontalAlignment.Left;
                body.Children.Add(stageChecked);
                long reclaimable = group.ReclaimableBytes(
                    group.FileIDs.Where(m => m != keeper).ToHashSet());
                Root.Children.Add(Ui.HeadedCard(Icons.File, Ui.Brush("AppHover"), Ui.Brush("AppSubtle"),
                    Path.GetFileName(Model.PathOf(group.FileIDs[0])) ?? "Group",
                    $"{group.FileIDs.Count} identical copies · {ByteFormat.Format(reclaimable)} recoverable" +
                    (group.SharesStorage ? " · shares storage (clone/hard link)" : ""),
                    body));
            }
        });
    }
}

/// <summary>
/// Applications — installed apps with removable leftovers.
/// Same data as before, new chrome.
/// </summary>
public sealed class ApplicationsPage : ListPage
{
    protected override void Refresh()
    {
        Root.Children.Clear();
        Root.Children.Add(Header("Applications",
            "Installed apps and the data they leave behind — expand an app to review its leftovers.",
            glyph: Icons.Applications, iconBg: Ui.Brush("AppAccentSoft"), iconFg: Ui.Brush("AppAccent")));
        _body.Children.Clear();
        _body.Children.Add(Working("Scanning installed apps…"));
        Root.Children.Add(_body);
        // Phase 1: registry list + cheap name-matched leftover paths (no
        // recursive walks) — renders the table almost immediately.
        Compute(() =>
        {
            var installed = AppLeftoverFinder.InstalledApplications();
            var uninstallByKey = installed
                .GroupBy(a => a.RegistryKeyName ?? a.Name, StringComparer.OrdinalIgnoreCase)
                .ToDictionary(g => g.Key, g => g.First().UninstallString,
                    StringComparer.OrdinalIgnoreCase);
            var listed = installed
                .Select(a => AppLeftoverFinder.FindLeftovers(a, measureSizes: false))
                .ToList();
            var store = AppLeftoverFinder.StoreApplications();
            return (listed, uninstallByKey, store);
        }, result =>
        {
            var (apps, uninstallByKey, store) = result;
            var withLeftovers = apps.Where(a => a.LeftoverPaths.Count > 0).ToList();
            RenderAppsTable(apps, withLeftovers, null, uninstallByKey, store);
            // Phase 2: real sizes, measured only for apps with leftovers.
            Compute(() =>
            {
                var leftoverSizes = new ConcurrentDictionary<string, List<(string, long)>>();
                var installSizes = new ConcurrentDictionary<string, long>();
                Parallel.ForEach(withLeftovers,
                    new ParallelOptions { MaxDegreeOfParallelism = 4 },
                    app =>
                    {
                        leftoverSizes[app.AppName] = app.LeftoverPaths
                            .Select(p => (p, AppLeftoverFinder.AllocatedSize(p)))
                            .ToList();
                        installSizes[app.AppName] =
                            !string.IsNullOrWhiteSpace(app.InstallPath) && Directory.Exists(app.InstallPath)
                                ? AppLeftoverFinder.AllocatedSize(app.InstallPath)
                                : 0;
                    });
                // Store apps: measure their package roots too — that is
                // the per-app footprint figure the table lacks for MSIX.
                foreach (var pkg in store)
                {
                    if (!string.IsNullOrWhiteSpace(pkg.InstallLocation)
                        && Directory.Exists(pkg.InstallLocation))
                        installSizes[pkg.RegistryKeyName ?? pkg.Name] =
                            AppLeftoverFinder.AllocatedSize(pkg.InstallLocation);
                }
                return (leftoverSizes, installSizes);
            }, sizes => RenderAppsTable(apps, withLeftovers, sizes, uninstallByKey, store));
        });
    }

    private readonly StackPanel _body = new();

    private void RenderAppsTable(List<AppLeftovers> apps, List<AppLeftovers> withLeftovers,
        (ConcurrentDictionary<string, List<(string, long)>> leftoverSizes,
         ConcurrentDictionary<string, long> installSizes)? data,
        Dictionary<string, string?>? uninstallByKey = null,
        List<InstalledApp>? store = null)
    {
        _body.Children.Clear();
        var leftoverSizes = data?.leftoverSizes ?? new ConcurrentDictionary<string, List<(string, long)>>();
        var installSizes = data?.installSizes ?? new ConcurrentDictionary<string, long>();
        {
            long installBytes = installSizes.Values.Sum();
            long leftoverBytes = leftoverSizes.Values.Sum(v => v.Sum(p => p.Item2));

            _body.Children.Add(Ui.StatRow(
                Ui.StatCard(Icons.Applications, Ui.Brush("AppAccentSoft"), Ui.Brush("AppAccent"),
                    $"{apps.Count:N0}", "Applications", "installed"),
                Ui.StatCard(Icons.Drive, Ui.DataTint(3), Ui.Data(3),
                    ByteFormat.Format(installBytes), "Size of apps with leftovers"),
                Ui.StatCard(Icons.Cleanup, Ui.Brush("AppSuccessBg"), Ui.Brush("AppSuccess"),
                    ByteFormat.Format(leftoverBytes), "Potentially removable",
                    $"{withLeftovers.Count} apps have leftovers")));
            _body.Children.Add(Ui.InfoCard("Leftovers only",
                "freedisk.space never uninstalls apps — it stages their caches, logs and support files for your review. The list comes from the Windows uninstall registry."));

            // App table: checkbox | # | app | size | leftovers | status | ⋯
            var table = new StackPanel();
            var headerRow = Ui.TableRowGrid(
                new GridLength(30), new GridLength(30), new GridLength(1, GridUnitType.Star),
                new GridLength(90), new GridLength(110), new GridLength(110), new GridLength(36));
            headerRow.Margin = new Thickness(0, 0, 0, 8);
            Ui.Cell(headerRow, new CheckBox { IsEnabled = false, VerticalAlignment = VerticalAlignment.Center }, 0);
            Ui.Cell(headerRow, Ui.Faint("#"), 1);
            Ui.Cell(headerRow, Ui.TableHead("Application"), 2);
            Ui.Cell(headerRow, Ui.TableHead("Footprint"), 3, right: true);
            Ui.Cell(headerRow, Ui.TableHead("Leftovers"), 4, right: true);
            Ui.Cell(headerRow, Ui.TableHead("Status"), 5);
            table.Children.Add(headerRow);
            // Apps with leftovers first, then the rest — mockup ordering.
            var ordered = apps.OrderByDescending(a => a.LeftoverPaths.Count)
                .ThenBy(a => a.AppName, StringComparer.OrdinalIgnoreCase).ToList();
            foreach (var (app, i) in ordered.Take(200).Select((a, i) => (a, i)))
            {
                long leftover = leftoverSizes.TryGetValue(app.AppName, out var ls)
                    ? ls.Sum(p => p.Item2) : 0;
                long install = installSizes.TryGetValue(app.AppName, out var ins) ? ins : 0;
                var outer = new Border { CornerRadius = new CornerRadius(6), Background = Brushes.Transparent };
                var row = Ui.TableRowGrid(
                    new GridLength(30), new GridLength(30), new GridLength(1, GridUnitType.Star),
                    new GridLength(90), new GridLength(110), new GridLength(110), new GridLength(36));
                outer.Child = row;
                var check = new CheckBox { VerticalAlignment = VerticalAlignment.Center };
                Ui.Cell(row, check, 0);
                Ui.Cell(row, Ui.Faint((i + 1).ToString()), 1);
                Ui.Cell(row, Ui.NameCell(Icons.Applications, Ui.DataTint(5),
                    Ui.Data(5), app.AppName,
                    app.InstallPath.Length > 0 ? app.InstallPath : "—", 26), 2);
                // Footprint = install dir + its leftovers — the per-app
                // total the macOS page shows.
                Ui.Cell(row, Ui.T(install > 0 || leftover > 0
                    ? ByteFormat.Format(install + leftover) : "—", 12), 3, right: true);
                Ui.Cell(row, Ui.T(leftover > 0 ? ByteFormat.Format(leftover)
                    : app.LeftoverPaths.Count > 0 ? $"{app.LeftoverPaths.Count} items" : "—", 12), 4, right: true);
                Ui.Cell(row, leftover > 0 || app.LeftoverPaths.Count > 0
                    ? Ui.SafetyLabel(Ui.Brush("AppWarning"), "Review first", 11)
                    : Ui.SafetyLabel(Ui.Brush("AppFaint"), "Keep", 11), 5);
                var captured = app;
                Ui.Cell(row, Ui.MoreButton(() =>
                {
                    var menu = new ContextMenu();
                    if (Directory.Exists(captured.InstallPath))
                    {
                        var open = new MenuItem { Header = "Open install folder" };
                        open.Click += (_, _) => Explorer.Reveal(captured.InstallPath);
                        menu.Items.Add(open);
                    }
                    foreach (var p in captured.LeftoverPaths.Take(5))
                    {
                        var reveal = new MenuItem { Header = $"Reveal {Path.GetFileName(p.TrimEnd('\\'))}" };
                        string cp = p;
                        reveal.Click += (_, _) => Explorer.Reveal(cp);
                        menu.Items.Add(reveal);
                    }
                    // The registry's own uninstall command — copied, never
                    // executed: freedisk.space never uninstalls apps itself.
                    if (uninstallByKey is not null
                        && uninstallByKey.TryGetValue(captured.AppId ?? captured.AppName, out var cmd)
                        && !string.IsNullOrWhiteSpace(cmd))
                    {
                        menu.Items.Add(new Separator());
                        var un = new MenuItem { Header = "Copy uninstall command" };
                        un.Click += (_, _) =>
                        {
                            try { Clipboard.SetText(cmd); } catch { }
                        };
                        menu.Items.Add(un);
                    }
                    menu.IsOpen = true;
                }), 6, right: true);
                table.Children.Add(outer);
            }
            _body.Children.Add(Ui.Card(table, 12));

            // Leftover detail cards for the biggest offenders.
            foreach (var app in withLeftovers.OrderByDescending(
                a => leftoverSizes.TryGetValue(a.AppName, out var l) ? l.Sum(p => p.Item2) : 0).Take(15))
            {
                var items = leftoverSizes.TryGetValue(app.AppName, out var ls) ? ls : [];
                var body = new StackPanel();
                foreach (var (path, size) in items.Take(12))
                {
                    var row = Ui.TableRowGrid(
                        new GridLength(1, GridUnitType.Star), new GridLength(80), new GridLength(110));
                    row.Margin = new Thickness(0, 3, 0, 3);
                    var capturedPath = path;
                    var capturedSize = size;
                    var appName = app.AppName;
                    var stage = Ui.Button("Add to Cleanup", null, Ui.ButtonStyle.Outline,
                        () => Model.StagePath(capturedPath, capturedSize, $"leftover of {appName}"));
                    stage.Padding = new Thickness(10, 3, 10, 3);
                    stage.VerticalAlignment = VerticalAlignment.Center;
                    Ui.Cell(row, Ui.NameCell(Icons.File, Ui.Brush("AppHover"), Ui.Brush("AppSubtle"),
                        Path.GetFileName(path.TrimEnd('\\')), path, 24), 0);
                    Ui.Cell(row, Ui.T(ByteFormat.Format(size), 12, FontWeights.Medium), 1, right: true);
                    Ui.Cell(row, stage, 2, right: true);
                    body.Children.Add(row);
                }
                var stageAll = Ui.Button("Add all leftovers to Cleanup", Icons.Cleanup, Ui.ButtonStyle.Primary,
                    () =>
                    {
                        int added = 0;
                        foreach (var (p, s) in items)
                            if (Model.StagePath(p, s, $"leftover of {app.AppName}", notify: false)) added++;
                        if (added > 0) Model.ToastAdded(added);
                    });
                stageAll.Margin = new Thickness(0, 10, 0, 0);
                stageAll.HorizontalAlignment = HorizontalAlignment.Left;
                body.Children.Add(stageAll);
                _body.Children.Add(Ui.HeadedCard(Icons.Applications, Ui.Brush("AppAccentSoft"), Ui.Brush("AppAccent"),
                    app.AppName,
                    $"{items.Count} leftovers · {ByteFormat.Format(items.Sum(p => p.Item2))}", body));
            }
            // MSIX / Microsoft Store packages — the AppModel hive, no WinRT.
            if (store is { Count: > 0 })
            {
                var storeBody = new StackPanel();
                foreach (var pkg in store.OrderByDescending(p =>
                    installSizes.TryGetValue(p.RegistryKeyName ?? p.Name, out var s) ? s : 0).Take(40))
                {
                    var row = Ui.TableRowGrid(
                        new GridLength(1, GridUnitType.Star), new GridLength(90));
                    row.Margin = new Thickness(0, 3, 0, 3);
                    long sz = installSizes.TryGetValue(pkg.RegistryKeyName ?? pkg.Name, out var v) ? v : 0;
                    Ui.Cell(row, Ui.NameCell(Icons.Applications, Ui.DataTint(5), Ui.Data(5),
                        pkg.Name, pkg.InstallLocation ?? "", 24), 0);
                    Ui.Cell(row, Ui.T(sz > 0 ? ByteFormat.Format(sz) : "—", 12, FontWeights.Medium), 1, right: true);
                    storeBody.Children.Add(row);
                }
                if (store.Count > 40)
                    storeBody.Children.Add(Ui.Faint($"… and {store.Count - 40:N0} more packages"));
                _body.Children.Add(Ui.HeadedCard(Icons.Applications, Ui.DataTint(3), Ui.Data(3),
                    "Store apps", $"{store.Count:N0} MSIX packages — managed by Windows; uninstall from Settings", storeBody));
            }
            if (apps.Count == 0)
                _body.Children.Add(Ui.Subtle("No installed apps found in the registry."));
        }
    }
}

/// <summary>Snapshots — saved scans, saved/loaded/compared.</summary>
public sealed class SnapshotsPage : ListPage
{
    private readonly StackPanel _list = new();
    private readonly StackPanel _compareHost = new();

    protected override void Refresh()
    {
        Root.Children.Clear();
        var head = Header("Snapshots",
            "Track how your storage changes over time. Save a snapshot after important changes and compare it later.",
            glyph: Icons.Snapshots, iconBg: Ui.Brush("AppHover"), iconFg: Ui.Brush("AppSubtle"));
        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (Model.Tree is not null)
        {
            var save = Ui.Button("Save Snapshot", Icons.Add, Ui.ButtonStyle.Dark, SaveCurrent);
            save.Margin = new Thickness(8, 0, 0, 0);
            actions.Children.Add(save);
            // WIN-054: export the live tree to JSON / NDJSON / CSV / ncdu.
            var export = Ui.Button("Export Scan…", Icons.Downloads, Ui.ButtonStyle.Outline, ExportScan);
            export.Margin = new Thickness(8, 0, 0, 0);
            actions.Children.Add(export);
        }
        var load = Ui.Button("Load…", Icons.Open, Ui.ButtonStyle.Outline, LoadDialog);
        load.Margin = new Thickness(8, 0, 0, 0);
        actions.Children.Add(load);
        DockPanel.SetDock(actions, Dock.Right);
        // Insert first: the title stack stays the fill-last child, so the
        // subtitle gives up space instead of pushing the buttons out.
        head.Children.Insert(0, actions);
        Root.Children.Add(head);

        // Two columns when there is room; one stack at large text / narrow windows.
        var columns = new Grid();
        columns.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        columns.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _list.Children.Clear();
        columns.Children.Add(_list);
        columns.Children.Add(_compareHost);
        void LayoutColumns(double width)
        {
            bool compact = width > 0 && width < 720;
            columns.ColumnDefinitions.Clear();
            if (compact)
            {
                columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                Grid.SetColumn(_list, 0); Grid.SetRow(_list, 0);
                Grid.SetColumn(_compareHost, 0); Grid.SetRow(_compareHost, 1);
                _compareHost.Margin = new Thickness(0, Ui.ZoneGap, 0, 0);
            }
            else
            {
                columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(300) });
                columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Ui.GroupGap) });
                columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                Grid.SetColumn(_list, 0); Grid.SetRow(_list, 0);
                Grid.SetColumn(_compareHost, 2); Grid.SetRow(_compareHost, 0);
                _compareHost.Margin = new Thickness(0);
            }
        }
        columns.SizeChanged += (_, e) => LayoutColumns(e.NewSize.Width);
        LayoutColumns(ActualWidth);
        Root.Children.Add(columns);
        RefreshList();
        RefreshCompare();
    }

    private void ExportScan()
    {
        if (Model.Tree is not { } tree || Model.RootPath is not { } root) return;
        var dlg = new Microsoft.Win32.SaveFileDialog
        {
            Title = "Export scan",
            FileName = "diskmap-scan",
            Filter = "JSON (nested)|*.json|NDJSON|*.ndjson|CSV|*.csv|ncdu|*.ncdu",
            FilterIndex = 1,
        };
        if (dlg.ShowDialog() != true) return;
        var format = dlg.FilterIndex switch
        {
            2 => TreeExporter.Format.Ndjson,
            3 => TreeExporter.Format.Csv,
            4 => TreeExporter.Format.Ncdu,
            _ => TreeExporter.Format.Json,
        };
        try
        {
            File.WriteAllText(dlg.FileName,
                TreeExporter.Export(tree, Model.Totals, root, format));
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Couldn't write the export: {ex.Message}",
                "freedisk.space", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private static string SnapshotDir => SnapshotStore.DefaultDirectory();

    private List<(string Path, SnapshotHeader Header)> SnapshotFiles()
    {
        var result = new List<(string, SnapshotHeader)>();
        if (!Directory.Exists(SnapshotDir)) return result;
        foreach (var file in Directory.EnumerateFiles(SnapshotDir, "*.snapshot"))
        {
            try { result.Add((file, SnapshotStore.ReadHeader(file))); }
            catch { /* skip unreadable entries */ }
        }
        return result.OrderByDescending(t => t.Item2.CapturedAt).ToList();
    }

    private void RefreshList()
    {
        _list.Children.Clear();
        var files = SnapshotFiles();
        var cardBody = new StackPanel();
        if (files.Count == 0)
        {
            cardBody.Children.Add(Ui.Subtle("No snapshots yet — save a scan and it shows up here."));
        }
        foreach (var (file, header) in files)
        {
            string captured = file;
            var row = new DockPanel { Margin = new Thickness(0, 5, 0, 5), Background = Brushes.Transparent };
            var more = Ui.MoreButton(() =>
            {
                var menu = new ContextMenu();
                var open = new MenuItem { Header = "Open" };
                open.Click += (_, _) => Load(captured);
                menu.Items.Add(open);
                var del = new MenuItem { Header = "Add snapshot to Cleanup" };
                del.Click += (_, _) =>
                {
                    long size = new FileInfo(captured).Length;
                    Model.StagePath(captured, size, "snapshot");
                };
                menu.Items.Add(del);
                menu.IsOpen = true;
            });
            DockPanel.SetDock(more, Dock.Right);
            row.Children.Add(more);
            row.Children.Add(Ui.NameCell(Icons.Drive, Ui.Brush("AppHover"), Ui.Brush("AppSubtle"),
                header.RootPath,
                $"{header.CapturedAt.LocalDateTime:MMM d, yyyy · h:mm tt}", 30));
            row.Cursor = System.Windows.Input.Cursors.Hand;
            row.MouseLeftButtonDown += (_, _) => Load(captured);
            cardBody.Children.Add(row);
        }
        _list.Children.Add(Ui.HeadedCard(Icons.Snapshots, Ui.Brush("AppHover"), Ui.Brush("AppSubtle"),
            "All snapshots", $"{files.Count} saved", cardBody, new Thickness(0)));
    }

    private ComboBox? _beforeBox, _afterBox;

    private void RefreshCompare()
    {
        _compareHost.Children.Clear();
        var files = SnapshotFiles();
        var body = new StackPanel();
        body.Children.Add(Ui.Subtle("Select two snapshots to see what changed between them.", 12));

        _beforeBox = SnapshotPicker(files, files.ElementAtOrDefault(1).Path);
        _afterBox = SnapshotPicker(files, files.FirstOrDefault().Path);
        var boxes = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 10, 0, 6) };
        boxes.Children.Add(_beforeBox);
        boxes.Children.Add(new TextBlock { Text = "  →  ", VerticalAlignment = VerticalAlignment.Center });
        boxes.Children.Add(_afterBox);
        body.Children.Add(boxes);
        var compare = Ui.Button("Compare", null, Ui.ButtonStyle.Dark, async () => await CompareSelected());
        compare.HorizontalAlignment = HorizontalAlignment.Left;
        compare.Margin = new Thickness(0, 0, 0, 10);
        body.Children.Add(compare);
        body.Children.Add(_compareResult);
        _compareHost.Children.Add(Ui.HeadedCard(Icons.Duplicates, Ui.Brush("AppHover"), Ui.Brush("AppSubtle"),
            "Compare Snapshots", "Pick a before and after", body, new Thickness(0)));
    }

    private readonly StackPanel _compareResult = new();

    private static ComboBox SnapshotPicker(List<(string Path, SnapshotHeader Header)> files, string? selected)
    {
        var box = new ComboBox
        {
            MinWidth = 120, MaxWidth = 180, Width = 150,
            Height = 32, FontSize = Ui.Scaled(12),
        };
        foreach (var (path, header) in files)
        {
            var item = new ComboBoxItem
            {
                Content = $"{header.CapturedAt.LocalDateTime:MMM d · h:mm tt} — {Path.GetFileName(header.RootPath.TrimEnd('\\', '/'))}",
                Tag = path,
            };
            box.Items.Add(item);
            if (path == selected) box.SelectedItem = item;
        }
        if (box.SelectedItem is null && box.Items.Count > 0) box.SelectedIndex = 0;
        return box;
    }

    private SnapshotComparison? _comparison;
    private SnapshotComparison.Entry? _drill;

    private async Task CompareSelected()
    {
        string? before = (_beforeBox?.SelectedItem as ComboBoxItem)?.Tag as string;
        string? after = (_afterBox?.SelectedItem as ComboBoxItem)?.Tag as string;
        if (before is null || after is null) return;
        _compareResult.Children.Clear();
        _compareResult.Children.Add(Ui.Subtle("Comparing…"));
        try
        {
            var basis = Model.SizeBasis;
            var (a, b) = await Task.Run(() =>
                (SnapshotStore.Load(before), SnapshotStore.Load(after)));
            _comparison = await Task.Run(() => new SnapshotComparison(a, b, basis));
            _drill = null;
            RenderCompare();
        }
        catch (Exception ex)
        {
            _compareResult.Children.Clear();
            _compareResult.Children.Add(Ui.Subtle($"Compare failed: {ex.Message}"));
        }
    }

    /// <summary>
    /// WIN-044: name-aligned drill-down — each level's rows sum to their
    /// folder; the hotspot story names where change actually happened.
    /// </summary>
    private void RenderCompare()
    {
        _compareResult.Children.Clear();
        if (_comparison is not { } cmp) return;

        if (!cmp.RootsMatch)
            _compareResult.Children.Add(Ui.WarningCard("Different scan roots",
                "These snapshots used different scan roots, so some paths may not align."));

        var root = cmp.Root;
        long delta = root.Delta;
        var summary = new StackPanel { Margin = new Thickness(0, 4, 0, 10) };
        summary.Children.Add(Ui.Mono(
            $"{(delta >= 0 ? "+" : "−")}{ByteFormat.Format(Math.Abs(delta))}", 28, FontWeights.SemiBold));
        var (grew, shrank) = cmp.SplitOf(_drill ?? root);
        summary.Children.Add(Ui.Faint(
            $"net change · +{ByteFormat.Format(grew)} grew · −{ByteFormat.Format(Math.Abs(shrank))} freed here"));
        _compareResult.Children.Add(summary);

        // The story: where the change actually happened, not every
        // ancestor of it.
        var spots = cmp.Hotspots(cmp.DefaultMinimumChange);
        if (spots.Count > 0)
        {
            var story = new WrapPanel { Margin = new Thickness(0, 0, 0, 8) };
            story.Children.Add(Ui.T("Where it happened: ", 11.5, null, Ui.Brush("AppSubtle")));
            foreach (var spot in spots.Take(5))
            {
                var link = Ui.T(
                    $"{(spot.Delta >= 0 ? "+" : "−")}{ByteFormat.Format(Math.Abs(spot.Delta))} {spot.Path.Replace('/', '›')}   ",
                    11.5, FontWeights.Medium, Ui.Brush("AppAccent"));
                link.Cursor = System.Windows.Input.Cursors.Hand;
                string capturedPath = spot.Path;
                link.MouseLeftButtonDown += (_, _) =>
                {
                    _drill = cmp.EntryAt(capturedPath) ?? _drill;
                    RenderCompare();
                };
                story.Children.Add(link);
            }
            _compareResult.Children.Add(story);
        }

        // Breadcrumb: root › folder › … — rows below always sum to the
        // last crumb.
        var crumbs = new WrapPanel { Margin = new Thickness(0, 0, 0, 6) };
        var here = _drill ?? root;
        var crumbPath = here.Path;
        var crumbRoot = Ui.T(cmp.After.RootPath.TrimEnd('\\', '/'), 11.5, FontWeights.Medium,
            Ui.Brush("AppAccent"));
        crumbRoot.Cursor = System.Windows.Input.Cursors.Hand;
        crumbRoot.MouseLeftButtonDown += (_, _) => { _drill = null; RenderCompare(); };
        crumbs.Children.Add(crumbRoot);
        if (crumbPath.Length > 0)
        {
            string built = "";
            foreach (var component in crumbPath.Split('/'))
            {
                built = built.Length == 0 ? component : built + "/" + component;
                crumbs.Children.Add(Ui.T("  ›  ", 11.5, null, Ui.Brush("AppSubtle")));
                var crumb = Ui.T(component, 11.5, FontWeights.Medium, Ui.Brush("AppAccent"));
                crumb.Cursor = System.Windows.Input.Cursors.Hand;
                string target = built;
                crumb.MouseLeftButtonDown += (_, _) =>
                {
                    _drill = cmp.EntryAt(target) ?? _drill;
                    RenderCompare();
                };
                crumbs.Children.Add(crumb);
            }
        }
        _compareResult.Children.Add(crumbs);

        var table = new StackPanel();
        var rows = cmp.ChildrenOf(here);
        foreach (var c in rows.Take(60))
        {
            var row = Ui.TableRowGrid(
                new GridLength(1, GridUnitType.Star), new GridLength(70),
                new GridLength(70), new GridLength(80));
            row.Margin = new Thickness(0, 3, 0, 3);
            var name = Ui.NameCell(
                c.IsDirectory ? Icons.Folder : Icons.File,
                Ui.Brush("AppHover"), Ui.Brush("AppSubtle"), c.Name,
                c.Kind switch
                {
                    SnapshotChangeKind.Added => "added",
                    SnapshotChangeKind.Removed => "removed",
                    _ => null,
                }, 24);
            if (c.IsDirectory)
            {
                name.Cursor = System.Windows.Input.Cursors.Hand;
                var captured = c;
                name.MouseLeftButtonDown += (_, _) => { _drill = captured; RenderCompare(); };
            }
            Ui.Cell(row, name, 0);
            Ui.Cell(row, Ui.T(c.Before > 0 ? ByteFormat.Format(c.Before) : "—", 11.5,
                null, Ui.Brush("AppSubtle")), 1, right: true);
            Ui.Cell(row, Ui.T(c.After > 0 ? ByteFormat.Format(c.After) : "—", 11.5,
                null, Ui.Brush("AppSubtle")), 2, right: true);
            Ui.Cell(row, Ui.T($"{(c.Delta >= 0 ? "+" : "−")}{ByteFormat.Format(Math.Abs(c.Delta))}",
                12, FontWeights.Medium,
                c.Delta >= 0 ? Ui.Brush("AppDanger") : Ui.Brush("AppSuccess")), 3, right: true);
            table.Children.Add(row);
        }
        if (rows.Count == 0)
            table.Children.Add(Ui.Subtle("Nothing changed at this level."));
        else if (rows.Count > 60)
            table.Children.Add(Ui.Faint($"… and {rows.Count - 60:N0} smaller changes"));
        _compareResult.Children.Add(table);
    }

    private async void SaveCurrent()
    {
        if (Model.Tree is not { } tree || Model.RootPath is not { } rootPath) return;
        await Task.Run(() =>
            SnapshotStore.Save(new DiskSnapshot(rootPath, DateTimeOffset.Now, tree), SnapshotDir));
        RefreshList();
    }

    private async void LoadDialog()
    {
        var dlg = new OpenFileDialog { Filter = "freedisk.space snapshots (*.snapshot)|*.snapshot" };
        if (dlg.ShowDialog() == true) await LoadAsync(dlg.FileName);
    }

    private async void Load(string path) => await LoadAsync(path);

    private async Task LoadAsync(string path)
    {
        try
        {
            var snap = await Task.Run(() => SnapshotStore.Load(path));
            await Model.LoadSnapshot(snap);
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Load failed", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }
}

/// <summary>
/// The staged-cleanup queue — second step of the two-step safety model:
/// everything lands here first, the user reviews, then commit sends it
/// all to the Recycle Bin.
/// </summary>
public sealed class CleanupQueuePage : ListPage
{
    private CleanupQueue.StagedItem? _lastRemoved;
    private System.Windows.Threading.DispatcherTimer? _removeUndoTimer;
    private CommitSuccess? _success;
    private sealed record CommitSuccess(int Count, long FreedBytes, bool IsLowerBound, List<string> Paths);

    protected override void Refresh()
    {
        Root.Children.Clear();
        Root.Children.Add(Header("Cleanup",
            "Everything you've added, waiting for review. Nothing moves to the Recycle Bin until you confirm.",
            glyph: Icons.Cleanup, iconBg: Ui.Brush("AppDangerBg"), iconFg: Ui.Brush("AppDanger")));
        var items = Model.Cleanup.AllItems();
        if (_success is { } success)
        {
            Root.Children.Add(SuccessView(success));
            return;
        }

        // WIN-012: the last commit's items can come back from the Recycle
        // Bin — even after a relaunch, since the record is on disk.
        var record = CleanupRecord.Load();
        if (record is { Items.Count: > 0 })
        {
            var undo = new DockPanel();
            var info = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            info.Children.Add(Ui.T(
                $"Last cleanup — {record.Items.Count} items · {ByteFormat.Format(record.Items.Sum(i => i.Bytes))}",
                12.5, FontWeights.Medium));
            info.Children.Add(Ui.Faint(
                $"{record.Date.LocalDateTime:MMM d · h:mm tt} · sitting in the Recycle Bin"));
            DockPanel.SetDock(info, Dock.Left);
            undo.Children.Add(info);
            var putBack = Ui.Button("Put back", Icons.Back, Ui.ButtonStyle.Outline, () => PutBackNow(record));
            DockPanel.SetDock(putBack, Dock.Right);
            putBack.VerticalAlignment = VerticalAlignment.Center;
            undo.Children.Add(putBack);
            Root.Children.Add(Ui.HeadedCard(Icons.Back, Ui.Brush("AppSuccessBg"), Ui.Brush("AppSuccess"),
                "Undo the last cleanup", "Moves items back out of the Recycle Bin", undo));
        }
        if (_lastRemoved is { } removed)
            Root.Children.Add(RemoveUndoRow(removed));

        if (items.Count == 0)
        {
            Root.Children.Add(Ui.EmptyState(Icons.Cleanup, "Nothing in Cleanup",
                "Add items from the map, file lists or review pages, then confirm them here.",
                Ui.Button("Find things to clean", Icons.SafeReview, Ui.ButtonStyle.Outline,
                    () => Model.ShowPage("Safe to Review"))));
            return;
        }

        var estimate = Model.Cleanup.Estimate();
        string reclaimable = estimate.IsCalculating ? $"~{ByteFormat.Format(estimate.Bytes)}"
            : estimate.IsLowerBound ? $"≥{ByteFormat.Format(estimate.Bytes)}"
            : ByteFormat.Format(estimate.Bytes);
        var subline = $"{items.Count} items in Cleanup · freed when the Recycle Bin is emptied";
        if (estimate.IsCalculating)
            subline = "Measuring sizes… · " + subline;
        else if (estimate.HeldByUnqueuedCopies > 0)
            subline += $" · {ByteFormat.Format(estimate.HeldByUnqueuedCopies)} stays in use (hard-linked elsewhere)";
        Root.Children.Add(Ui.StatRow(
            Ui.StatCard(Icons.Cleanup, Ui.Brush("AppHover"), Ui.Brush("AppSubtle"),
                reclaimable, "Reclaimable", subline)));

        foreach (var group in items.GroupBy(i => i.Reason).OrderByDescending(g => g.Sum(i => i.Size)))
        {
            var body = new StackPanel();
            foreach (var item in group.OrderByDescending(i => i.Size))
            {
                var row = Ui.TableRowGrid(
                    new GridLength(1, GridUnitType.Star), new GridLength(80),
                    new GridLength(60), new GridLength(120));
                row.Margin = new Thickness(0, 3, 0, 3);
                var captured = item;
                Ui.Cell(row, Ui.NameCell(Icons.File, Ui.Brush("AppHover"), Ui.Brush("AppSubtle"),
                    Path.GetFileName(item.Path.TrimEnd('\\')),
                    item.IsMeasuring ? item.Path + "  · measuring…" : item.Path, 24), 0);
                long share = estimate.PerItem.GetValueOrDefault(item.Id);
                Ui.Cell(row, Ui.T(
                    item.IsMeasuring ? "…" : share != item.Size && share >= 0
                        ? $"{ByteFormat.Format(share)} ↓" : ByteFormat.Format(share),
                    12, FontWeights.Medium), 1, right: true);
                var reveal = Ui.T("Reveal", 11.5, FontWeights.Medium, Ui.Brush("AppAccent"));
                reveal.Cursor = System.Windows.Input.Cursors.Hand;
                reveal.VerticalAlignment = VerticalAlignment.Center;
                reveal.MouseLeftButtonDown += (_, _) => Explorer.Reveal(captured.Path);
                Ui.Cell(row, reveal, 2, right: true);
                var remove = Ui.T("Remove from Cleanup", 11.5, FontWeights.Medium, Ui.Brush("AppAccent"));
                remove.Cursor = System.Windows.Input.Cursors.Hand;
                remove.VerticalAlignment = VerticalAlignment.Center;
                remove.MouseLeftButtonDown += (_, _) => RemoveWithUndo(captured);
                Ui.Cell(row, remove, 3, right: true);
                body.Children.Add(row);
            }
            Root.Children.Add(Ui.HeadedCard(Icons.List, Ui.Brush("AppHover"), Ui.Brush("AppSubtle"),
                ReasonLabel(group.Key), $"{group.Count()} items · {ByteFormat.Format(group.Sum(i => i.Size))}", body));
        }

        // The destructive action is never offered on a provisional figure.
        var commit = Ui.Button(
            estimate.IsCalculating ? "Measuring sizes…" : $"Move {items.Count} items to the Recycle Bin…",
            Icons.Trash, Ui.ButtonStyle.Primary, Commit);
        commit.HorizontalAlignment = HorizontalAlignment.Left;
        commit.IsEnabled = !estimate.IsCalculating;
        commit.Margin = new Thickness(0, 12, 0, 0);
        Root.Children.Add(commit);
    }

    private FrameworkElement RemoveUndoRow(CleanupQueue.StagedItem item)
    {
        var row = new DockPanel { MinHeight = 40 };
        var undo = Ui.LinkText("Undo", () => UndoRemove(item), 12);
        DockPanel.SetDock(undo, Dock.Right);
        row.Children.Add(undo);
        var text = Ui.Subtle($"Removed “{Path.GetFileName(item.Path)}” — it stays on disk", 12);
        text.TextTrimming = TextTrimming.CharacterEllipsis;
        row.Children.Add(text);
        return new Border
        {
            BorderBrush = Ui.Brush("AppBorder"), BorderThickness = new Thickness(0, 1, 0, 1),
            Padding = new Thickness(10, 0, 10, 0), Margin = new Thickness(0, 0, 0, Ui.GroupGap),
            Child = row,
        };
    }

    private void RemoveWithUndo(CleanupQueue.StagedItem item)
    {
        Model.Unstage(item.Id);
        _lastRemoved = item;
        _removeUndoTimer?.Stop();
        _removeUndoTimer = new System.Windows.Threading.DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(6),
        };
        _removeUndoTimer.Tick += (_, _) =>
        {
            _removeUndoTimer?.Stop();
            _lastRemoved = null;
            Refresh();
        };
        _removeUndoTimer.Start();
        Refresh();
    }

    private void UndoRemove(CleanupQueue.StagedItem item)
    {
        _removeUndoTimer?.Stop();
        _lastRemoved = null;
        Model.Cleanup.Stage(item.Path, item.Size, item.Reason,
            item.SharesStorageGroup, item.GroupCopyCount);
        Model.RefreshStaged();
        Refresh();
    }

    private FrameworkElement SuccessView(CommitSuccess success)
    {
        var stack = new StackPanel
        {
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 24, 0, 0),
            MaxWidth = 520,
        };
        var icon = AppSettings.Load().ShowDusty
            ? Ui.BrandIcon(104)
            : Ui.Glyph(Icons.Check, 28, Ui.Brush("AppAccent"));
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        stack.Children.Add(icon);
        var title = Ui.T($"{success.Count:N0} {(success.Count == 1 ? "item" : "items")} moved to the Recycle Bin",
            15, FontWeights.SemiBold);
        title.HorizontalAlignment = HorizontalAlignment.Center;
        title.Margin = new Thickness(0, 12, 0, 6);
        stack.Children.Add(title);
        var freed = Ui.Mono(
            $"{(success.IsLowerBound ? "At least " : "")}{ByteFormat.Format(success.FreedBytes)} is freed when you empty it.",
            12, null, Ui.Brush("AppSubtle"));
        freed.HorizontalAlignment = HorizontalAlignment.Center;
        stack.Children.Add(freed);
        var note = Ui.Faint("Changed your mind? Put Back returns the items exactly where they were.", 12);
        note.TextAlignment = TextAlignment.Center;
        note.Margin = new Thickness(0, 8, 0, 14);
        stack.Children.Add(note);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
        var record = CleanupRecord.Load();
        var putBack = Ui.Button("Put Back", Icons.Back, Ui.ButtonStyle.Outline, () =>
        {
            _success = null;
            if (record is { Items.Count: > 0 }) PutBackNow(record);
        });
        putBack.IsEnabled = record is { Items.Count: > 0 };
        actions.Children.Add(putBack);
        var done = Ui.Button("Done", null, Ui.ButtonStyle.Primary, () => { _success = null; Refresh(); });
        done.Margin = new Thickness(Ui.InlineGap, 0, 0, 0);
        actions.Children.Add(done);
        stack.Children.Add(actions);
        if (success.Paths.Count > 0)
        {
            var details = Ui.Mono(string.Join(Environment.NewLine, success.Paths), 11, null, Ui.Brush("AppSubtle"));
            details.TextWrapping = TextWrapping.Wrap;
            details.MaxWidth = 500;
            stack.Children.Add(new Expander
            {
                Header = "Show what moved",
                Content = details,
                Margin = new Thickness(0, 14, 0, 0),
            });
        }
        return stack;
    }

    private static string ReasonLabel(string reason) => reason switch
    {
        "duplicate" => "Duplicates",
        "caches" => "Caches",
        "developer storage" => "Developer storage",
        var r when r.StartsWith("leftover of ") => "App leftovers",
        var r when r.StartsWith("from treemap") => "Added from the map",
        _ => "Cleanup items",
    };

    private async void Commit()
    {
        var items = Model.Cleanup.AllItems();
        if (items.Count == 0) return;
        var estimate = Model.Cleanup.Estimate();
        var confirm = MessageBox.Show(
            $"Move {items.Count} items to the Recycle Bin?\n\n" +
            $"That frees {(estimate.IsLowerBound ? "at least " : "")}{ByteFormat.Format(estimate.Bytes)} " +
            "once the bin is emptied.\n\nThey stay recoverable until then.",
            "Commit cleanup", MessageBoxButton.YesNo, MessageBoxImage.Question);
        if (confirm != MessageBoxResult.Yes) return;
        // Folders recycle first; their staged children report "moved with
        // the folder" instead of failing. Failures stay staged for retry.
        var report = await Task.Run(() => Model.Cleanup.Commit());
        Model.RefreshStaged();
        var moved = report.Entries.Where(entry => entry.Error is null).ToList();
        if (moved.Count == 0)
        {
            Refresh();
            MessageBox.Show("Nothing could be moved. The items may be in use.",
                "Cleanup", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        _success = new CommitSuccess(
            moved.Count,
            report.FreedWhenEmptied,
            report.IsLowerBound,
            moved.Select(entry => entry.Item.Path).ToList());
        Refresh();
        int failed = report.Entries.Count - moved.Count;
        Model.Toast($"Moved {moved.Count} items to the Recycle Bin" +
            (failed > 0 ? $" · {failed} couldn't be moved" : ""));
    }

    private async void PutBackNow(CleanupRecord record)
    {
        var confirm = MessageBox.Show(
            $"Put {record.Items.Count} item(s) back where they were?\n\n" +
            "Anything that already returned, or whose spot is taken, is left alone.",
            "Put back", MessageBoxButton.YesNo, MessageBoxImage.Question);
        if (confirm != MessageBoxResult.Yes) return;
        var report = await Task.Run(() => DiskMap.Core.PutBack.Run(record));
        Model.Toast($"Put back {report.Restored.Count} item(s)"
            + (report.Skipped.Count > 0 ? $" · {report.Skipped.Count} skipped" : ""));
        string message = $"Put back {report.Restored.Count} item(s).";
        if (report.Skipped.Count > 0)
            message += $"\n\n{report.Skipped.Count} skipped:\n" +
                string.Join("\n", report.Skipped.Take(6).Select(s => $"· {s.Reason}"));
        if (report.Restored.Count == record.Items.Count)
        {
            // Fully restored — clear the record so the card disappears.
            new CleanupRecord(record.Date, []).Save();
        }
        else
        {
            // Keep the unreclaimed remainder for a later try.
            new CleanupRecord(record.Date,
                record.Items.Where(i => report.Restored.All(r => r.OriginalPath != i.OriginalPath)).ToList()).Save();
        }
        MessageBox.Show(message, "Put back", MessageBoxButton.OK, MessageBoxImage.Information);
        Model.RefreshStaged();
        Refresh();
    }
}
