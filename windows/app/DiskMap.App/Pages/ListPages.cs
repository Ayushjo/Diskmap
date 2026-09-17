using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using DiskMap.Core;

namespace DiskMap.App.Pages;

/// <summary>
/// Shared helper for the list-style pages: a vertical stack with a header
/// row, content area, and refresh on state changes.
/// </summary>
public abstract class ListPage : UserControl
{
    protected ScanModel Model => ScanModel.Shared;
    protected readonly StackPanel Root = new() { Margin = new Thickness(16) };

    /// <summary>Secondary-text brush, follows the theme palette.</summary>
    protected static Brush Subtle =>
        (Brush)Application.Current.Resources["AppSubtle"];

    protected ListPage()
    {
        Content = new ScrollViewer { Content = Root, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Model.StateChanged += (_, _) => Dispatcher.InvokeAsync(Refresh);
        Loaded += (_, _) => Refresh();
    }

    protected abstract void Refresh();

    protected TextBlock Title(string text) => new()
    {
        Text = text, FontSize = 18, FontWeight = FontWeights.SemiBold,
        Margin = new Thickness(0, 0, 0, 12),
    };

    protected static StackPanel Row(UIElement left, UIElement? right = null)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 2, 0, 2) };
        panel.Children.Add(left);
        if (right is not null)
        {
            right.SetValue(FrameworkElement.MarginProperty, new Thickness(12, 0, 0, 0));
            panel.Children.Add(right);
        }
        return panel;
    }

    protected Button SmallButton(string text, Action onClick)
    {
        var b = new Button { Content = text, Padding = new Thickness(8, 3, 8, 3) };
        b.Click += (_, _) => onClick();
        return b;
    }
}

/// <summary>Biggest items in the scan, directories included (subtree totals).</summary>
public sealed class TopSizesPage : ListPage
{
    protected override void Refresh()
    {
        Root.Children.Clear();
        Root.Children.Add(Title("Top Sizes"));
        if (Model.Tree is not { } tree || Model.Totals.Length == 0)
        {
            Root.Children.Add(new TextBlock { Text = "Scan a folder to see the largest items." });
            return;
        }
        var ranked = TopSizes.Ranked(Model.Totals, 300);
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(60) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(90) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(90) });
        foreach (var (id, index) in ranked.Select((id, i) => (id, i)))
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            int row = index;
            var rank = new TextBlock { Text = $"{index + 1}", Foreground = Subtle, Margin = new Thickness(0, 1, 0, 1) };
            var size = new TextBlock { Text = ByteFormat.Format(Model.Totals[id]), Margin = new Thickness(0, 1, 8, 1) };
            var path = new TextBlock { Text = Model.PathOf(id), Margin = new Thickness(0, 1, 8, 1), TextTrimming = TextTrimming.CharacterEllipsis };
            var reveal = SmallButton("Reveal", () => Explorer.Reveal(Model.PathOf(id)));
            if (tree.IsDirectory[id])
            {
                path.Cursor = System.Windows.Input.Cursors.Hand;
                path.MouseLeftButtonDown += (_, e) =>
                {
                    if (e.ClickCount == 2) Model.DrillTo(id);
                };
                path.ToolTip = "Double-click to view in Map";
            }
            Grid.SetRow(rank, row); Grid.SetColumn(rank, 0);
            Grid.SetRow(size, row); Grid.SetColumn(size, 1);
            Grid.SetRow(path, row); Grid.SetColumn(path, 2);
            Grid.SetRow(reveal, row); Grid.SetColumn(reveal, 3);
            grid.Children.Add(rank); grid.Children.Add(size); grid.Children.Add(path); grid.Children.Add(reveal);
        }
        Root.Children.Add(grid);
    }
}

/// <summary>Immediate child folders of the zoomed node, sized bars.</summary>
public sealed class FoldersPage : ListPage
{
    protected override void Refresh()
    {
        Root.Children.Clear();
        Root.Children.Add(Title("Folders"));
        if (Model.Tree is not { } tree || Model.Totals.Length == 0)
        {
            Root.Children.Add(new TextBlock { Text = "Scan a folder to browse its folders." });
            return;
        }
        var children = tree.ChildrenOf(Model.ZoomedNode, Model.Totals)
            .Where(c => tree.IsDirectory[c.Id])
            .OrderByDescending(c => c.Size)
            .ToList();
        if (children.Count == 0)
        {
            Root.Children.Add(new TextBlock { Text = "No folders at this level." });
            return;
        }
        long max = children.Max(c => c.Size);
        foreach (var (id, size) in children)
        {
            var panel = new DockPanel { Margin = new Thickness(0, 3, 0, 3) };
            var name = new TextBlock { Text = tree.NameOf(id), Width = 220, TextTrimming = TextTrimming.CharacterEllipsis, Cursor = System.Windows.Input.Cursors.Hand };
            name.MouseLeftButtonDown += (_, e) =>
            {
                if (e.ClickCount == 2) Model.DrillTo(id);
            };
            var bar = new Border
            {
                Width = Math.Max(2, 300.0 * size / Math.Max(1, max)),
                Height = 14, Background = NodeColors.BrushFor(id),
                HorizontalAlignment = HorizontalAlignment.Left, CornerRadius = new CornerRadius(2),
            };
            var sizeText = new TextBlock { Text = ByteFormat.Format(size), Margin = new Thickness(8, 0, 0, 0), Foreground = Subtle };
            DockPanel.SetDock(name, Dock.Left);
            DockPanel.SetDock(sizeText, Dock.Right);
            panel.Children.Add(name);
            panel.Children.Add(sizeText);
            panel.Children.Add(bar);
            Root.Children.Add(panel);
        }
    }
}

/// <summary>Age buckets + largest untouched files (older than a year).</summary>
public sealed class AgeMapPage : ListPage
{
    protected override void Refresh()
    {
        Root.Children.Clear();
        Root.Children.Add(Title("Age Map"));
        if (Model.Tree is not { } tree || Model.Totals.Length == 0)
        {
            Root.Children.Add(new TextBlock { Text = "Scan a folder to see file ages." });
            return;
        }
        int today = AgeMap.Today();
        var buckets = AgeMap.BucketSizes(tree, Model.Totals, today);
        long max = buckets.Count > 0 ? buckets.Values.Max() : 1;
        foreach (var bucket in Enum.GetValues<AgeBucket>())
        {
            if (!buckets.TryGetValue(bucket, out long size) || size <= 0) continue;
            var panel = new DockPanel { Margin = new Thickness(0, 3, 0, 3) };
            var label = new TextBlock { Text = AgeMap.Title(bucket), Width = 140 };
            var bar = new Border { Width = Math.Max(2, 300.0 * size / max), Height = 14, Background = NodeColors.AgeBucket(bucket), HorizontalAlignment = HorizontalAlignment.Left, CornerRadius = new CornerRadius(2) };
            var sizeText = new TextBlock { Text = ByteFormat.Format(size), Margin = new Thickness(8, 0, 0, 0), Foreground = Subtle };
            DockPanel.SetDock(label, Dock.Left);
            DockPanel.SetDock(sizeText, Dock.Right);
            panel.Children.Add(label); panel.Children.Add(sizeText); panel.Children.Add(bar);
            Root.Children.Add(panel);
        }

        var untouched = AgeMap.Untouched(tree, Model.Totals, today);
        if (untouched.Count > 0)
        {
            var header = new DockPanel { Margin = new Thickness(0, 18, 0, 8) };
            var stageBtn = new Button { Content = "Stage Selected", Padding = new Thickness(8, 3, 8, 3) };
            header.Children.Add(new TextBlock { Text = "Untouched over a year", FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
            DockPanel.SetDock(stageBtn, Dock.Right);
            header.Children.Add(stageBtn);
            Root.Children.Add(header);

            var checkedIds = new HashSet<int>();
            foreach (var id in untouched.Take(50))
            {
                var check = new CheckBox { VerticalAlignment = VerticalAlignment.Center };
                int captured = id;
                check.Checked += (_, _) => checkedIds.Add(captured);
                check.Unchecked += (_, _) => checkedIds.Remove(captured);
                var row = new DockPanel { Margin = new Thickness(0, 2, 0, 2) };
                var path = new TextBlock { Text = Model.PathOf(id), TextTrimming = TextTrimming.CharacterEllipsis };
                path.MouseLeftButtonDown += (_, e) =>
                {
                    if (e.ClickCount == 2 && tree.IsDirectory[captured]) Model.DrillTo(captured);
                };
                var size = new TextBlock { Text = ByteFormat.Format(Model.Totals[id]), Width = 90, Foreground = Subtle };
                DockPanel.SetDock(check, Dock.Left);
                DockPanel.SetDock(size, Dock.Right);
                row.Children.Add(check); row.Children.Add(size); row.Children.Add(path);
                Root.Children.Add(row);
            }
            stageBtn.Click += (_, _) =>
            {
                foreach (var id in checkedIds) Model.Stage(id, "big & untouched");
            };
        }
    }
}
