using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using DiskMap.Core;

namespace DiskMap.App.Controls;

/// <summary>
/// Flame graph: the zoomed node spans full width at top; each row below
/// shows its children sized proportionally. Same ChartLayout slices as
/// the other charts — only the stacking is flame-specific.
/// </summary>
public sealed class FlameControl : FrameworkElement
{
    private readonly List<(int? NodeId, Rect Rect)> _hit = [];
    private ToolTip? _tooltip;
    private const double RowHeight = 26;
    private const double RowGap = 2;
    private const int MaxDepth = 12;

    public FlameControl()
    {
        ScanModel.Shared.StateChanged += (_, _) => Dispatcher.InvokeAsync(InvalidateVisual);
        MouseLeftButtonDown += OnClick;
        MouseMove += OnMove;
        MouseLeave += (_, _) => { if (_tooltip is not null) _tooltip.IsOpen = false; };
        MouseRightButtonDown += OnRightClick;
    }

    protected override void OnRender(DrawingContext dc)
    {
        _hit.Clear();
        var model = ScanModel.Shared;
        var tree = model.Tree;
        if (tree is null || model.Totals.Length == 0 || ActualWidth <= 0) return;

        double width = ActualWidth;
        long rootSize = Math.Max(1, model.Totals[model.ZoomedNode]);

        // Root bar.
        var rootRect = new Rect(0, 0, width, RowHeight);
        dc.DrawRectangle(NodeColors.BrushFor(model.ZoomedNode), new Pen(NodeColors.Stroke, 1), rootRect);
        DrawLabel(dc, rootRect, tree.NameOf(model.ZoomedNode), rootSize);

        var slices = ChartLayout.SlicesOf(model.ZoomedNode, tree, model.Totals);
        DrawRow(dc, slices, rootSize, 0, width, 1, tree);
    }

    private void DrawRow(DrawingContext dc, List<ChartSlice> slices, long parentSize,
        double x, double width, int depth, FileTree tree)
    {
        if (depth > MaxDepth || width <= 0) return;
        double y = depth * (RowHeight + RowGap);
        double offset = x;
        foreach (var slice in slices)
        {
            double w = width * slice.Size / parentSize;
            if (w < 1) { offset += w; continue; }
            var rect = new Rect(offset, y, w, RowHeight);
            var fill = slice.NodeID is { } id ? NodeColors.BrushFor(id) : NodeColors.OtherBrush;
            dc.DrawRectangle(fill, new Pen(NodeColors.Stroke, 1), rect);
            _hit.Add((slice.NodeID, rect));
            if (slice.NodeID is { } nid && w > 50)
                DrawLabel(dc, rect, tree.NameOf(nid), slice.Size);
            if (slice.Children.Count > 0)
                DrawRow(dc, slice.Children, Math.Max(1, slice.Size), offset, w, depth + 1, tree);
            offset += w;
        }
    }

    private void DrawLabel(DrawingContext dc, Rect rect, string name, long size)
    {
        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        var text = new FormattedText($"{name} — {ByteFormat.Format(size)}",
            System.Globalization.CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
            new Typeface("Segoe UI"), 11, Brushes.White, dpi);
        text.MaxTextWidth = Math.Max(10, rect.Width - 8);
        text.Trimming = TextTrimming.CharacterEllipsis;
        dc.DrawText(text, new Point(rect.X + 5, rect.Y + (rect.Height - 14) / 2));
    }

    private int? HitAt(Point p)
    {
        foreach (var (id, rect) in _hit)
            if (rect.Contains(p)) return id;
        return null;
    }

    private void OnClick(object sender, MouseButtonEventArgs e)
    {
        if (HitAt(e.GetPosition(this)) is { } id && ScanModel.Shared.Tree?.IsDirectory[id] == true)
            ScanModel.Shared.DrillTo(id);
    }

    private void OnMove(object sender, MouseEventArgs e)
    {
        var model = ScanModel.Shared;
        if (HitAt(e.GetPosition(this)) is { } id && model.Tree is { } tree)
        {
            _tooltip ??= new ToolTip();
            _tooltip.Content = $"{tree.NameOf(id)} — {ByteFormat.Format(model.Totals[id])}";
            _tooltip.IsOpen = true;
            ToolTip = _tooltip;
        }
        else if (_tooltip is not null) _tooltip.IsOpen = false;
    }

    private void OnRightClick(object sender, MouseButtonEventArgs e)
    {
        if (HitAt(e.GetPosition(this)) is not { } id) return;
        var model = ScanModel.Shared;
        var menu = new ContextMenu();
        var reveal = new MenuItem { Header = "Reveal in Explorer" };
        reveal.Click += (_, _) => Explorer.Reveal(model.PathOf(id));
        menu.Items.Add(reveal);
        var stage = new MenuItem { Header = "Stage for cleanup" };
        stage.Click += (_, _) => model.Stage(id, "from flame graph");
        menu.Items.Add(stage);
        menu.IsOpen = true;
    }
}
