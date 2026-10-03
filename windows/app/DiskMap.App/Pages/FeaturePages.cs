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

            var totalPanel = new StackPanel { Orientation = Orientation.Horizontal };
            totalPanel.Children.Add(Ui.IconTile(Icons.Caches, 44, Ui.Hex("#F3E8FF"), Ui.Hex("#7C3AED"), 10));
            var tt = new StackPanel { Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            tt.Children.Add(Ui.T(ByteFormat.Format(data.total), 22, FontWeights.Bold));
            tt.Children.Add(Ui.Subtle($"across {data.byCategory.Sum(g => g.Count):N0} locations", 12));
            totalPanel.Children.Add(tt);
            Root.Children.Add(Ui.Card(totalPanel, 16));

            var grid = new UniformGrid { Columns = 2 };
            foreach (var (title, blurb, page, glyph) in new (string, string, string, string)[]
            {
                ("Caches", "App and system caches — recreated on demand", "Caches", Icons.Caches),
                ("Old Downloads", "Installers and zips you already opened", "Old Downloads", Icons.Downloads),
                ("Large Media", "Videos and images over 100 MB", "Large Media", Icons.Media),
                ("Developer Storage", "Dependencies, build outputs, tool caches", "Developer Storage", Icons.Developer),
            })
            {
                var card = new StackPanel { Margin = new Thickness(0, 0, 8, 12) };
                var head = new DockPanel { Margin = new Thickness(0, 0, 0, 6) };
                var tile = Ui.IconTile(glyph, 30, Ui.Brush("AppAccentSoft"), Ui.Brush("AppAccent"), 7);
                DockPanel.SetDock(tile, Dock.Left);
                head.Children.Add(tile);
                head.Children.Add(new StackPanel
                {
                    Margin = new Thickness(10, 0, 0, 0),
                    VerticalAlignment = VerticalAlignment.Center,
                    Children =
                    {
                        Ui.T(title, 13, FontWeights.SemiBold),
                        Ui.Faint(blurb),
                    },
                });
                card.Children.Add(head);
                var review = Ui.T("Review →", 12, FontWeights.Medium, Ui.Brush("AppAccent"));
                review.Cursor = System.Windows.Input.Cursors.Hand;
                string captured = page;
                review.MouseLeftButtonDown += (_, _) => Model.ShowPage(captured);
                card.Children.Add(review);
                grid.Children.Add(Ui.Card(card, 14, new Thickness(0)));
            }
            Root.Children.Add(grid);

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
                .Select((g, i) => (g.Key, g.Sum(h => totals[h.Id]),
                    i == 0 ? Ui.Brush("AppAccent") : Ui.Hex("#F0A95F")))
                .ToList();
            var summary = new DockPanel();
            var left = new StackPanel { Margin = new Thickness(0, 0, 24, 0), VerticalAlignment = VerticalAlignment.Center };
            left.Children.Add(Ui.IconTile(Icons.Caches, 44, Ui.Hex("#F3E8FF"), Ui.Hex("#7C3AED"), 10));
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
        Ui.Cell(row, Ui.NameCell(Icons.Caches, Ui.Hex("#F3E8FF"), Ui.Hex("#7C3AED"),
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
            right.Children.Add(Ui.Button("Reveal in Explorer", Icons.Open, Ui.ButtonStyle.Outline,
                () => { if (selected.Count > 0) Explorer.Reveal(Model.PathOf(selected[0].Id)); }));
            right.Children.Add(new Border { Width = 8 });
            right.Children.Add(Ui.Button("Add to Cleanup →", null, Ui.ButtonStyle.Dark,
                () =>
                {
                    foreach (var h in selected) Model.Stage(h.Id, "caches");
                    _checked.Clear();
                    Repaint();
                }));
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
    private static readonly (string Category, string Blurb)[] GroupOrder =
    [
        ("Development dependencies", "Packages your tools reinstall on demand — node_modules, venv, gradle."),
        ("Build outputs", "Folders your build recreates — target, dist, .next, DerivedData."),
        ("Development caches", "Package-manager and compiler caches — re-downloaded when needed."),
        ("Development toolchains", "Rust toolchains and SDK caches."),
        ("Diagnostics", "Crash dumps — safe to clear once reviewed."),
    ];

    protected override void Refresh()
    {
        Root.Children.Clear();
        Root.Children.Add(Header("Developer Storage",
            "Dependencies, build outputs and tool caches — regenerable by design, safe to review.",
            glyph: Icons.Developer, iconBg: Ui.Hex("#E0F2FE"), iconFg: Ui.Hex("#0284C7")));
        if (Model.Tree is not { } tree || Model.Totals.Length != tree.Count)
        {
            Root.Children.Add(NeedsScan("Developer storage comes from the scan."));
            return;
        }
        var totals = Model.Totals;
        Root.Children.Add(Working("Grouping…"));
        Compute(() =>
            (Model.QuickWins ?? [])
                .GroupBy(h => h.Category)
                .Select(g => (Category: g.Key, Items: g.OrderByDescending(h => totals[h.Id]).ToList(),
                    Bytes: g.Sum(h => totals[h.Id])))
                .OrderByDescending(g => g.Bytes).ToList(), groups =>
        {
            Root.Children.RemoveAt(Root.Children.Count - 1);
            if (groups.Count == 0)
            {
                Root.Children.Add(Ui.Subtle("No developer storage found in this scan."));
                return;
            }
            long total = groups.Sum(g => g.Bytes);
            var summary = new StackPanel { Orientation = Orientation.Horizontal };
            summary.Children.Add(Ui.IconTile(Icons.Developer, 44, Ui.Hex("#E0F2FE"), Ui.Hex("#0284C7"), 10));
            var st = new StackPanel { Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            st.Children.Add(Ui.T(ByteFormat.Format(total), 22, FontWeights.Bold));
            st.Children.Add(Ui.Subtle($"across {groups.Count} categories · {groups.Sum(g => g.Items.Count):N0} locations", 12));
            summary.Children.Add(st);
            Root.Children.Add(Ui.Card(summary, 16));

            foreach (var group in groups)
            {
                var blurb = GroupOrder.FirstOrDefault(g => g.Category == group.Category).Blurb
                    ?? "Regenerable data — recreated by your tools.";
                var body = new StackPanel();
                body.Children.Add(Ui.InfoCard("Why is this safe?", blurb, new Thickness(0, 0, 0, 10)));
                foreach (var hit in group.Items.Take(25))
                    body.Children.Add(DevRow(tree, totals, hit));
                if (group.Items.Count > 25)
                    body.Children.Add(Ui.Faint($"… and {group.Items.Count - 25:N0} smaller locations"));
                var stageAll = Ui.Button($"Stage all in {group.Category}", Icons.Cleanup, Ui.ButtonStyle.Dark,
                    () =>
                    {
                        foreach (var h in group.Items) Model.Stage(h.Id, "developer storage");
                        Model.ShowPage("Cleanup");
                    });
                stageAll.Margin = new Thickness(0, 10, 0, 0);
                stageAll.HorizontalAlignment = HorizontalAlignment.Left;
                body.Children.Add(stageAll);
                var catIcon = group.Category switch
                {
                    "Development dependencies" => Icons.Code,
                    "Build outputs" => Icons.Folder,
                    "Development caches" => Icons.Caches,
                    "Development toolchains" => Icons.Settings,
                    _ => Icons.List,
                };
                Root.Children.Add(Ui.HeadedCard(catIcon, Ui.Hex("#E0F2FE"), Ui.Hex("#0284C7"),
                    group.Category, $"{group.Items.Count:N0} locations · {ByteFormat.Format(group.Bytes)}", body));
            }
        });
    }

    private UIElement DevRow(FileTree tree, long[] totals, QuickWins.Hit hit)
    {
        var outer = new Border
        {
            CornerRadius = new CornerRadius(6), Margin = new Thickness(0, 2, 0, 2),
            Background = Brushes.Transparent,
        };
        var row = Ui.TableRowGrid(
            new GridLength(1, GridUnitType.Star), new GridLength(80), new GridLength(80));
        outer.Child = row;
        var stage = Ui.Button("Stage", null, Ui.ButtonStyle.Outline,
            () => { Model.Stage(hit.Id, "developer storage"); });
        stage.Padding = new Thickness(10, 3, 10, 3);
        stage.VerticalAlignment = VerticalAlignment.Center;
        Ui.Cell(row, Ui.NameCell(Icons.Developer, Ui.Hex("#E0F2FE"), Ui.Hex("#0284C7"),
            hit.Name, Model.DisplayPath(hit.Id), 26), 0);
        Ui.Cell(row, Ui.T(ByteFormat.Format(totals[hit.Id]), 12, FontWeights.Medium), 1, right: true);
        Ui.Cell(row, stage, 2, right: true);
        outer.Cursor = System.Windows.Input.Cursors.Hand;
        outer.MouseLeftButtonDown += (_, e) =>
        {
            if (e.ClickCount >= 2) Model.DrillTo(hit.Id);
            else Model.Select(hit.Id);
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
            Root.Children.RemoveAt(Root.Children.Count - 1);
            if (groups.Count == 0)
            {
                Root.Children.Add(Ui.Subtle("No duplicates found — nothing byte-identical above the size floor."));
                return;
            }
            // Every group's recoverable space assumes "keep one, remove rest".
            long recoverable = groups.Sum(g =>
                g.ReclaimableBytes(g.FileIDs.Skip(1).ToHashSet()));
            var summary = new StackPanel { Orientation = Orientation.Horizontal };
            summary.Children.Add(Ui.IconTile(Icons.Duplicates, 44, Ui.Brush("AppSuccessBg"), Ui.Brush("AppSuccess"), 10));
            var st = new StackPanel { Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            st.Children.Add(Ui.T(ByteFormat.Format(recoverable), 22, FontWeights.Bold));
            st.Children.Add(Ui.Subtle($"potentially recoverable · {groups.Count:N0} groups · {groups.Sum(g => g.FileIDs.Count):N0} copies", 12));
            summary.Children.Add(st);
            Root.Children.Add(Ui.Card(summary, 16));

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
                        new GridLength(1, GridUnitType.Star), new GridLength(80));
                    rowOuter.Child = row;
                    var check = new CheckBox
                    {
                        IsChecked = !isKeeper,
                        VerticalAlignment = VerticalAlignment.Center,
                    };
                    Ui.Cell(row, check, 0);
                    var tag = isKeeper
                        ? Ui.Badge("keeps", Ui.Brush("AppSuccess"), Ui.Brush("AppSuccessBg"))
                        : Ui.Badge("older copy", Ui.Brush("AppSubtle"), Ui.Brush("AppHover"));
                    Ui.Cell(row, tag, 1);
                    Ui.Cell(row, Ui.NameCell(Icons.File, Ui.Brush("AppHover"), Ui.Brush("AppSubtle"),
                        Path.GetFileName(path), Path.GetDirectoryName(path), 24), 2);
                    var stage = Ui.Button("Stage", null, Ui.ButtonStyle.Outline,
                        () => Model.Stage(id, "duplicate", group.Hash, group.FileIDs.Count));
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
                var stageChecked = Ui.Button("Stage copies except keeper", Icons.Cleanup, Ui.ButtonStyle.Dark,
                    () =>
                    {
                        foreach (var memberId in group.FileIDs.Where(m => m != keeper))
                            Model.Stage(memberId, "duplicate", group.Hash, group.FileIDs.Count);
                        Model.ShowPage("Cleanup");
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
            var listed = installed
                .Select(a => AppLeftoverFinder.FindLeftovers(a, measureSizes: false))
                .ToList();
            return listed;
        }, apps =>
        {
            var withLeftovers = apps.Where(a => a.LeftoverPaths.Count > 0).ToList();
            RenderAppsTable(apps, withLeftovers, null);
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
                return (leftoverSizes, installSizes);
            }, sizes => RenderAppsTable(apps, withLeftovers, sizes));
        });
    }

    private readonly StackPanel _body = new();

    private void RenderAppsTable(List<AppLeftovers> apps, List<AppLeftovers> withLeftovers,
        (ConcurrentDictionary<string, List<(string, long)>> leftoverSizes,
         ConcurrentDictionary<string, long> installSizes)? data)
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
                Ui.StatCard(Icons.Drive, Ui.Hex("#F3E8FF"), Ui.Hex("#7C3AED"),
                    ByteFormat.Format(installBytes), "Size of apps with leftovers"),
                Ui.StatCard(Icons.Cleanup, Ui.Brush("AppSuccessBg"), Ui.Brush("AppSuccess"),
                    ByteFormat.Format(leftoverBytes), "Potentially removable",
                    $"{withLeftovers.Count} apps have leftovers")));
            _body.Children.Add(Ui.InfoCard("Leftovers only",
                "DiskMap never uninstalls apps — it stages their caches, logs and support files for your review. The list comes from the Windows uninstall registry."));

            // App table: checkbox | # | app | size | leftovers | status | ⋯
            var table = new StackPanel();
            var headerRow = Ui.TableRowGrid(
                new GridLength(30), new GridLength(30), new GridLength(1, GridUnitType.Star),
                new GridLength(90), new GridLength(110), new GridLength(110), new GridLength(36));
            headerRow.Margin = new Thickness(0, 0, 0, 8);
            Ui.Cell(headerRow, new CheckBox { IsEnabled = false, VerticalAlignment = VerticalAlignment.Center }, 0);
            Ui.Cell(headerRow, Ui.Faint("#"), 1);
            Ui.Cell(headerRow, Ui.TableHead("Application"), 2);
            Ui.Cell(headerRow, Ui.TableHead("Size"), 3, right: true);
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
                Ui.Cell(row, Ui.NameCell(Icons.Applications, Ui.Brush("AppAccentSoft"),
                    Ui.Brush("AppAccent"), app.AppName,
                    app.InstallPath.Length > 0 ? app.InstallPath : "—", 26), 2);
                Ui.Cell(row, Ui.T(install > 0 ? ByteFormat.Format(install) : "—", 12), 3, right: true);
                Ui.Cell(row, Ui.T(leftover > 0 ? ByteFormat.Format(leftover)
                    : app.LeftoverPaths.Count > 0 ? $"{app.LeftoverPaths.Count} items" : "—", 12), 4, right: true);
                Ui.Cell(row, leftover > 0 || app.LeftoverPaths.Count > 0
                    ? Ui.Badge("Review first", Ui.Brush("AppWarning"), Ui.Brush("AppWarningBg"))
                    : Ui.Badge("Keep", Ui.Brush("AppSuccess"), Ui.Brush("AppSuccessBg")), 5);
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
                        new GridLength(1, GridUnitType.Star), new GridLength(80), new GridLength(80));
                    row.Margin = new Thickness(0, 3, 0, 3);
                    var capturedPath = path;
                    var capturedSize = size;
                    var appName = app.AppName;
                    var stage = Ui.Button("Stage", null, Ui.ButtonStyle.Outline,
                        () => Model.StagePath(capturedPath, capturedSize, $"leftover of {appName}"));
                    stage.Padding = new Thickness(10, 3, 10, 3);
                    stage.VerticalAlignment = VerticalAlignment.Center;
                    Ui.Cell(row, Ui.NameCell(Icons.File, Ui.Brush("AppHover"), Ui.Brush("AppSubtle"),
                        Path.GetFileName(path.TrimEnd('\\')), path, 24), 0);
                    Ui.Cell(row, Ui.T(ByteFormat.Format(size), 12, FontWeights.Medium), 1, right: true);
                    Ui.Cell(row, stage, 2, right: true);
                    body.Children.Add(row);
                }
                var stageAll = Ui.Button("Stage all leftovers", Icons.Cleanup, Ui.ButtonStyle.Dark,
                    () =>
                    {
                        foreach (var (p, s) in items)
                            Model.StagePath(p, s, $"leftover of {app.AppName}");
                        Model.ShowPage("Cleanup");
                    });
                stageAll.Margin = new Thickness(0, 10, 0, 0);
                stageAll.HorizontalAlignment = HorizontalAlignment.Left;
                body.Children.Add(stageAll);
                _body.Children.Add(Ui.HeadedCard(Icons.Applications, Ui.Brush("AppAccentSoft"), Ui.Brush("AppAccent"),
                    app.AppName,
                    $"{items.Count} leftovers · {ByteFormat.Format(items.Sum(p => p.Item2))}", body));
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
        }
        var load = Ui.Button("Load…", Icons.Open, Ui.ButtonStyle.Outline, LoadDialog);
        load.Margin = new Thickness(8, 0, 0, 0);
        actions.Children.Add(load);
        DockPanel.SetDock(actions, Dock.Right);
        // Insert before the fill-last title so the buttons keep their width.
        head.Children.Insert(1, actions);
        Root.Children.Add(head);

        // Two columns: snapshot list | compare.
        var columns = new Grid();
        columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(340) });
        columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(14) });
        columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _list.Children.Clear();
        Grid.SetColumn(_list, 0);
        Grid.SetColumn(_compareHost, 2);
        columns.Children.Add(_list);
        columns.Children.Add(_compareHost);
        Root.Children.Add(columns);
        RefreshList();
        RefreshCompare();
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
                var del = new MenuItem { Header = "Delete snapshot" };
                del.Click += (_, _) =>
                {
                    if (MessageBox.Show("Delete this snapshot file?", "Snapshots",
                            MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
                    {
                        File.Delete(captured);
                        RefreshList();
                        RefreshCompare();
                    }
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
        var box = new ComboBox { Width = 150 };
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
            var changes = await Task.Run(() => SnapshotDiff.Changes(a, b, basis));
            _compareResult.Children.Clear();
            long delta = changes.Sum(c => c.Delta);
            var summary = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 10) };
            summary.Children.Add(Ui.IconTile(Icons.Drive,
                36, delta >= 0 ? Ui.Brush("AppDangerBg") : Ui.Brush("AppSuccessBg"),
                delta >= 0 ? Ui.Brush("AppDanger") : Ui.Brush("AppSuccess"), 8));
            var st = new StackPanel { Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            st.Children.Add(Ui.T($"{(delta >= 0 ? "+" : "−")}{ByteFormat.Format(Math.Abs(delta))}", 18, FontWeights.Bold,
                delta >= 0 ? Ui.Brush("AppDanger") : Ui.Brush("AppSuccess")));
            st.Children.Add(Ui.Faint("storage change between snapshots"));
            summary.Children.Add(st);
            _compareResult.Children.Add(summary);

            var table = new StackPanel();
            foreach (var c in changes.Take(25))
            {
                var row = new DockPanel { Margin = new Thickness(0, 3, 0, 3) };
                var d = Ui.T($"{(c.Delta >= 0 ? "+" : "−")}{ByteFormat.Format(Math.Abs(c.Delta))}",
                    12, FontWeights.Medium,
                    c.Delta >= 0 ? Ui.Brush("AppDanger") : Ui.Brush("AppSuccess"));
                DockPanel.SetDock(d, Dock.Right);
                row.Children.Add(d);
                row.Children.Add(Ui.T(c.Path, 11.5));
                table.Children.Add(row);
            }
            if (changes.Count == 0)
                table.Children.Add(Ui.Subtle("No folder size changed between the two snapshots."));
            _compareResult.Children.Add(table);
        }
        catch (Exception ex)
        {
            _compareResult.Children.Clear();
            _compareResult.Children.Add(Ui.Subtle($"Compare failed: {ex.Message}"));
        }
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
        var dlg = new OpenFileDialog { Filter = "DiskMap snapshots (*.snapshot)|*.snapshot" };
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
    protected override void Refresh()
    {
        Root.Children.Clear();
        Root.Children.Add(Header("Cleanup",
            "Everything you staged, waiting for review. Commit moves it to the Recycle Bin — recoverable until you empty it.",
            glyph: Icons.Cleanup, iconBg: Ui.Brush("AppDangerBg"), iconFg: Ui.Brush("AppDanger")));
        var items = Model.Cleanup.AllItems();
        if (items.Count == 0)
        {
            Root.Children.Add(Ui.EmptyState(Icons.Cleanup, "Nothing staged",
                "Stage items from any page — the treemap, file lists, quick wins — and they'll wait here for review.",
                Ui.Button("Find things to clean", Icons.SafeReview, Ui.ButtonStyle.Outline,
                    () => Model.ShowPage("Safe to Review"))));
            return;
        }

        long total = items.Sum(i => i.Size);
        var summary = new StackPanel { Orientation = Orientation.Horizontal };
        summary.Children.Add(Ui.IconTile(Icons.Cleanup, 44, Ui.Brush("AppDangerBg"), Ui.Brush("AppDanger"), 10));
        var st = new StackPanel { Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        st.Children.Add(Ui.T(ByteFormat.Format(total), 22, FontWeights.Bold));
        st.Children.Add(Ui.Subtle($"staged across {items.Count} items · moves to the Recycle Bin, recoverable", 12));
        summary.Children.Add(st);
        Root.Children.Add(Ui.Card(summary, 16));

        foreach (var group in items.GroupBy(i => i.Reason).OrderByDescending(g => g.Sum(i => i.Size)))
        {
            var body = new StackPanel();
            foreach (var item in group.OrderByDescending(i => i.Size))
            {
                var row = Ui.TableRowGrid(
                    new GridLength(1, GridUnitType.Star), new GridLength(80),
                    new GridLength(60), new GridLength(60));
                row.Margin = new Thickness(0, 3, 0, 3);
                var captured = item;
                Ui.Cell(row, Ui.NameCell(Icons.File, Ui.Brush("AppHover"), Ui.Brush("AppSubtle"),
                    Path.GetFileName(item.Path.TrimEnd('\\')), item.Path, 24), 0);
                Ui.Cell(row, Ui.T(ByteFormat.Format(item.Size), 12, FontWeights.Medium), 1, right: true);
                var reveal = Ui.T("Reveal", 11.5, FontWeights.Medium, Ui.Brush("AppAccent"));
                reveal.Cursor = System.Windows.Input.Cursors.Hand;
                reveal.VerticalAlignment = VerticalAlignment.Center;
                reveal.MouseLeftButtonDown += (_, _) => Explorer.Reveal(captured.Path);
                Ui.Cell(row, reveal, 2, right: true);
                var remove = Ui.T("Remove", 11.5, FontWeights.Medium, Ui.Brush("AppDanger"));
                remove.Cursor = System.Windows.Input.Cursors.Hand;
                remove.VerticalAlignment = VerticalAlignment.Center;
                remove.MouseLeftButtonDown += (_, _) => { Model.Unstage(captured.Id); Refresh(); };
                Ui.Cell(row, remove, 3, right: true);
                body.Children.Add(row);
            }
            Root.Children.Add(Ui.HeadedCard(Icons.List, Ui.Brush("AppHover"), Ui.Brush("AppSubtle"),
                ReasonLabel(group.Key), $"{group.Count()} items · {ByteFormat.Format(group.Sum(i => i.Size))}", body));
        }

        var commit = Ui.Button($"Move {items.Count} items to the Recycle Bin", Icons.Trash, Ui.ButtonStyle.Danger,
            Commit);
        commit.Padding = new Thickness(18, 9, 18, 9);
        commit.HorizontalAlignment = HorizontalAlignment.Left;
        Root.Children.Add(Ui.Card(commit, 12, new Thickness(0)));
    }

    private static string ReasonLabel(string reason) => reason switch
    {
        "duplicate" => "Duplicates",
        "caches" => "Caches",
        "developer storage" => "Developer storage",
        var r when r.StartsWith("leftover of ") => "App leftovers",
        var r when r.StartsWith("from treemap") => "Staged from the map",
        _ => "Staged items",
    };

    private async void Commit()
    {
        var items = Model.Cleanup.AllItems();
        if (items.Count == 0) return;
        var confirm = MessageBox.Show(
            $"Move {items.Count} items ({ByteFormat.Format(items.Sum(i => i.Size))}) to the Recycle Bin?\n\n" +
            "They stay recoverable until the bin is emptied.",
            "Commit cleanup", MessageBoxButton.YesNo, MessageBoxImage.Question);
        if (confirm != MessageBoxResult.Yes) return;
        var results = await Task.Run(() => Model.Cleanup.Commit());
        Model.RefreshStaged();
        Refresh();
        var moved = results.Where(r => r.Error is null).ToList();
        string failed = results.Count - moved.Count > 0
            ? $"\n{results.Count - moved.Count} item(s) couldn't be moved — they may be in use."
            : "";
        MessageBox.Show(
            $"Moved {moved.Count} items to the Recycle Bin ({ByteFormat.Format(moved.Sum(r => r.Item.Size))}).{failed}",
            "Cleanup complete", MessageBoxButton.OK, MessageBoxImage.Information);
    }
}
