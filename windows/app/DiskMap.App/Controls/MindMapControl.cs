using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using DiskMap.Core;

namespace DiskMap.App.Controls;

/// <summary>
/// Mind map: horizontal tree — the zoomed node on the left, children
/// flowing right. Each child gets vertical space ∝ its share of the
/// parent, so big branches get more room. Elbow connectors link parent
/// to child like the macOS mind-map view.
/// </summary>
public sealed class MindMapControl : FrameworkElement
{
    private readonly List<(int? NodeId, Rect Rect)> _hit = [];
    private ToolTip? _tooltip;
    private const double NodeHeight = 34;
    private const double ColumnWidth = 170;
    private const double HGap = 70;
    private const double VGap = 8;
    private const int MaxDepth = 4;

    public MindMapControl()
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
        if (tree is null || model.Totals.Length == 0) return;

        var slices = ChartLayout.SlicesOf(model.ZoomedNode, tree, model.Totals);
        long total = Math.Max(1, model.Totals[model.ZoomedNode]);

        double cy = ActualHeight / 2;
        var rootRect = new Rect(20, cy - NodeHeight / 2, ColumnWidth, NodeHeight);
        dc.DrawRectangle(NodeColors.BrushFor(model.ZoomedNode), new Pen(NodeColors.Stroke, 1), rootRect);
        DrawLabel(dc, rootRect, tree.NameOf(model.ZoomedNode), model.Totals[model.ZoomedNode]);
        _hit.Add((model.ZoomedNode, rootRect));

        DrawChildren(dc, slices, total, 20 + ColumnWidth + HGap, cy, 20 + ColumnWidth + ColumnWidth + HGap, tree, depth: 1, availableHeight: ActualHeight - 40, parentX: 20 + ColumnWidth, parentY: cy);
    }

    private void DrawChildren(DrawingContext dc, List<ChartSlice> slices, long total,
        double x, double centerY, double nextX, FileTree tree,
        int depth, double availableHeight, double parentX, double parentY)
    {
        if (depth > MaxDepth || slices.Count == 0) return;
        double usable = Math.Max(NodeHeight, availableHeight - (slices.Count - 1) * VGap);
        double y = centerY - usable / 2;
        foreach (var slice in slices)
        {
            double h = Math.Max(NodeHeight, usable * slice.Size / Math.Max(1, total) - VGap);
            var rect = new Rect(x, y, ColumnWidth, Math.Min(h, NodeHeight * 1.5));
            var fill = slice.NodeID is { } id ? NodeColors.BrushFor(id) : NodeColors.OtherBrush;
            dc.DrawRectangle(fill, new Pen(NodeColors.Stroke, 1), rect);

            // Elbow connector from parent's right edge to child's left.
            double childMidY = rect.Y + rect.Height / 2;
            var pen = new Pen(NodeColors.Stroke, 1.5);
            dc.DrawLine(pen, new Point(parentX, parentY), new Point(parentX + HGap / 2, parentY));
            dc.DrawLine(pen, new Point(parentX + HGap / 2, parentY), new Point(parentX + HGap / 2, childMidY));
            dc.DrawLine(pen, new Point(parentX + HGap / 2, childMidY), new Point(rect.X, childMidY));

            if (slice.NodeID is { } nid)
                DrawLabel(dc, rect, tree.NameOf(nid), slice.Size);
            _hit.Add((slice.NodeID, rect));

            if (slice.Children.Count > 0)
            {
                DrawChildren(dc, slice.Children, Math.Max(1, slice.Size),
                    nextX, childMidY, nextX + ColumnWidth + HGap, tree,
                    depth + 1, h, rect.Right, childMidY);
            }
            y += h + VGap;
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
        dc.DrawText(text, new Point(rect.X + 6, rect.Y + (rect.Height - 14) / 2));
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
        stage.Click += (_, _) => model.Stage(id, "from mind map");
        menu.Items.Add(stage);
        menu.IsOpen = true;
    }
}
