using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using DiskMap.Core;

namespace DiskMap.App.Controls;

/// <summary>
/// Sunburst: concentric rings, angle ∝ size. Ring 1 = children of the
/// zoomed node, ring 2 = their children. Center circle drills back up.
/// Slice geometry from ChartLayout (shared with macOS); only the arc
/// drawing is platform code.
/// </summary>
public sealed class SunburstControl : FrameworkElement
{
    private readonly List<(int? NodeId, PathGeometry Geometry)> _hit = [];
    private ToolTip? _tooltip;

    public SunburstControl()
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

        double cx = ActualWidth / 2, cy = ActualHeight / 2;
        double radius = Math.Min(cx, cy);
        double centerRadius = radius * 0.22;
        double ringWidth = (radius - centerRadius) / 2;

        // Center = current node; click to zoom out.
        dc.DrawEllipse(NodeColors.BrushFor(model.ZoomedNode),
            new Pen(NodeColors.Stroke, 1), new Point(cx, cy), centerRadius, centerRadius);

        var slices = ChartLayout.SlicesOf(model.ZoomedNode, tree, model.Totals);
        long total = Math.Max(1, model.Totals[model.ZoomedNode]);
        DrawRing(dc, slices, total, 0, centerRadius, centerRadius + ringWidth, cx, cy, tree);
    }

    private void DrawRing(DrawingContext dc, List<ChartSlice> slices, long total,
        double startAngle, double r0, double r1, double cx, double cy, FileTree tree)
    {
        double angle = startAngle;
        foreach (var slice in slices)
        {
            double sweep = 2 * Math.PI * slice.Size / total;
            if (sweep < 0.002) { angle += sweep; continue; }
            var geom = Arc(cx, cy, r0, r1, angle, angle + sweep);
            var fill = slice.NodeID is { } id ? NodeColors.BrushFor(id) : NodeColors.OtherBrush;
            dc.DrawGeometry(fill, new Pen(NodeColors.Stroke, 1), geom);
            _hit.Add((slice.NodeID, geom));
            if (slice.Children.Count > 0)
                DrawRing(dc, slice.Children, Math.Max(1, slice.Size), angle, r1, r1 + (r1 - r0), cx, cy, tree);
            angle += sweep;
        }
    }

    private static PathGeometry Arc(double cx, double cy, double r0, double r1, double a0, double a1)
    {
        // Arc segment between two radii. Full circle handled by splitting.
        if (a1 - a0 >= 2 * Math.PI - 1e-4) a1 = a0 + 2 * Math.PI - 1e-4;
        Point P(double r, double a) => new(cx + r * Math.Cos(a), cy + r * Math.Sin(a));
        var fig = new PathFigure { StartPoint = P(r1, a0), IsClosed = true };
        bool large = a1 - a0 > Math.PI;
        fig.Segments.Add(new ArcSegment(P(r1, a1), new Size(r1, r1), 0, large, SweepDirection.Clockwise, true));
        fig.Segments.Add(new LineSegment(P(r0, a1), true));
        fig.Segments.Add(new ArcSegment(P(r0, a0), new Size(r0, r0), 0, large, SweepDirection.Counterclockwise, true));
        return new PathGeometry([fig]);
    }

    private int? HitAt(Point p)
    {
        for (int i = _hit.Count - 1; i >= 0; i--)
            if (_hit[i].Geometry.FillContains(p)) return _hit[i].NodeId;
        return null;
    }

    private void OnClick(object sender, MouseButtonEventArgs e)
    {
        var model = ScanModel.Shared;
        var center = new Point(ActualWidth / 2, ActualHeight / 2);
        var pos = e.GetPosition(this);
        double dist = Math.Sqrt(Math.Pow(pos.X - center.X, 2) + Math.Pow(pos.Y - center.Y, 2));
        double centerRadius = Math.Min(center.X, center.Y) * 0.22;
        if (dist <= centerRadius)
        {
            if (model.Tree is { } tree && model.ZoomedNode > 0)
                model.DrillToAncestor(tree.Parent[model.ZoomedNode]);
            return;
        }
        if (HitAt(pos) is { } id && model.Tree?.IsDirectory[id] == true)
            model.DrillTo(id);
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
        stage.Click += (_, _) => model.Stage(id, "from sunburst");
        menu.Items.Add(stage);
        menu.IsOpen = true;
    }
}
