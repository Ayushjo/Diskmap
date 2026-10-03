using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using DiskMap.Core;

namespace DiskMap.App.Controls;

/// <summary>
/// Bubble chart from CirclePack — radius ∝ sqrt(size) so area tracks
/// bytes. Nested circles draw their children inside. Same layout engine
/// as the macOS bubbles view.
/// </summary>
public sealed class BubblesControl : FrameworkElement
{
    private readonly List<(int? NodeId, double X, double Y, double R)> _circles = [];
    private readonly Dictionary<string, ChartSlice> _slicesById = new();
    private ToolTip? _tooltip;

    public BubblesControl()
    {
        ScanModel.Shared.StateChanged += (_, _) => Dispatcher.InvokeAsync(InvalidateVisual);
        MouseLeftButtonDown += OnClick;
        MouseMove += OnMove;
        MouseLeave += (_, _) => { if (_tooltip is not null) _tooltip.IsOpen = false; };
        MouseRightButtonDown += OnRightClick;
    }

    protected override void OnRender(DrawingContext dc)
    {
        _circles.Clear();
        _slicesById.Clear();
        var model = ScanModel.Shared;
        var tree = model.Tree;
        if (tree is null || model.Totals.Length == 0) return;

        var slices = ChartLayout.SlicesOf(model.ZoomedNode, tree, model.Totals);
        var packed = CirclePack.Pack(slices);
        if (packed.Count == 0) return;
        foreach (var s in slices) IndexSlice(s);

        double maxR = packed.Max(c => Math.Sqrt(c.X * c.X + c.Y * c.Y) + c.Radius);
        if (maxR <= 0) return;
        double scale = Math.Min(ActualWidth, ActualHeight) / 2 / maxR * 0.95;
        double cx = ActualWidth / 2, cy = ActualHeight / 2;

        foreach (var c in packed)
        {
            double r = c.Radius * scale;
            var center = new Point(cx + c.X * scale, cy + c.Y * scale);
            var slice = _slicesById.GetValueOrDefault(c.Id);
            var fill = slice?.NodeID is { } id ? NodeColors.BrushFor(id) : NodeColors.OtherBrush;
            dc.DrawEllipse(fill, new Pen(NodeColors.Stroke, 1), center, r, r);
            _circles.Add((slice?.NodeID, center.X, center.Y, r));

            if (slice?.NodeID is { } nid && r > 26)
            {
                var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
                var text = new FormattedText(
                    $"{tree.NameOf(nid)}\n{ByteFormat.Format(slice.Size)}",
                    System.Globalization.CultureInfo.CurrentUICulture,
                    FlowDirection.LeftToRight, new Typeface("Segoe UI"), 11,
                    Brushes.White, dpi);
                text.TextAlignment = TextAlignment.Center;
                text.MaxTextWidth = r * 1.6;
                dc.DrawText(text, new Point(center.X - r * 0.8, center.Y - text.Height / 2));
            }
        }
    }

    private void IndexSlice(ChartSlice slice)
    {
        _slicesById[slice.Id] = slice;
        foreach (var c in slice.Children) IndexSlice(c);
    }

    private int? HitAt(Point p)
    {
        int? best = null;
        double bestR = double.MaxValue;
        foreach (var (id, x, y, r) in _circles)
        {
            double dx = p.X - x, dy = p.Y - y;
            if (dx * dx + dy * dy <= r * r && r < bestR) { best = id; bestR = r; }
        }
        return best;
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
        stage.Click += (_, _) => model.Stage(id, "from bubbles");
        menu.Items.Add(stage);
        menu.IsOpen = true;
    }
}
