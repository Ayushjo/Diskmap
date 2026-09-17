using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using DiskMap.Core;

namespace DiskMap.App.Controls;

/// <summary>
/// Custom-drawn squarified treemap — the Windows counterpart of the macOS
/// TreemapView. Layout comes from DiskMap.Core.SquarifiedTreemap (verified
/// port), so geometry matches the macOS build exactly; only the drawing
/// calls are platform-native.
///
/// Interactions: left-click a directory to drill in; hover shows name +
/// size; right-click offers Reveal in Explorer / Stage for cleanup.
/// </summary>
public sealed class TreemapControl : FrameworkElement
{
    private List<TreemapRect> _rects = [];
    private int _hoverId = -1;
    private ToolTip? _tooltip;

    public TreemapControl()
    {
        ScanModel.Shared.StateChanged += (_, _) => Dispatcher.InvokeAsync(InvalidateVisual);
        MouseLeftButtonDown += OnClick;
        MouseMove += OnMove;
        MouseLeave += (_, _) => { _hoverId = -1; InvalidateVisual(); };
        MouseRightButtonDown += OnRightClick;
    }

    protected override void OnRender(DrawingContext dc)
    {
        var model = ScanModel.Shared;
        var tree = model.Tree;
        if (tree is null || model.Totals.Length == 0 || ActualWidth <= 0 || ActualHeight <= 0)
            return;

        var items = tree.ChildrenOf(model.ZoomedNode, model.Totals);
        var bounds = new DmRect(0, 0, ActualWidth, ActualHeight);
        _rects = SquarifiedTreemap.Layout(items, bounds);

        var typeface = new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
        foreach (var r in _rects)
        {
            var rect = new Rect(r.Rect.X + 1, r.Rect.Y + 1,
                Math.Max(0, r.Rect.Width - 2), Math.Max(0, r.Rect.Height - 2));
            if (rect.Width <= 0 || rect.Height <= 0) continue;
            var fill = NodeColors.BrushFor(r.Id);
            dc.DrawRectangle(fill, new Pen(NodeColors.Stroke, 1), rect);
            if (r.Id == _hoverId)
                dc.DrawRectangle(NodeColors.DirectoryOverlay, null, rect);

            // Label when the cell is big enough to hold a name + size.
            if (rect.Width > 48 && rect.Height > 30)
            {
                string name = tree.NameOf(r.Id);
                long size = model.Totals[r.Id];
                var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
                var nameText = new FormattedText(
                    name, System.Globalization.CultureInfo.CurrentUICulture,
                    FlowDirection.LeftToRight, typeface, 12,
                    Brushes.White, dpi);
                var sizeText = new FormattedText(
                    ByteFormat.Format(size), System.Globalization.CultureInfo.CurrentUICulture,
                    FlowDirection.LeftToRight, typeface, 10,
                    Brushes.White, dpi);
                double tx = rect.X + 5, ty = rect.Y + 4;
                if (nameText.Width > rect.Width - 8)
                {
                    nameText.MaxTextWidth = Math.Max(10, rect.Width - 8);
                    nameText.Trimming = TextTrimming.CharacterEllipsis;
                }
                dc.DrawText(nameText, new Point(tx, ty));
                dc.DrawText(sizeText, new Point(tx, ty + 15));
            }
        }
    }

    private void OnClick(object sender, MouseButtonEventArgs e)
    {
        var hit = HitAt(e.GetPosition(this));
        if (hit is { } id && ScanModel.Shared.Tree?.IsDirectory[id] == true)
            ScanModel.Shared.DrillTo(id);
    }

    private void OnRightClick(object sender, MouseButtonEventArgs e)
    {
        var hit = HitAt(e.GetPosition(this));
        if (hit is not { } id) return;
        var model = ScanModel.Shared;
        var menu = new ContextMenu();
        var reveal = new MenuItem { Header = "Reveal in Explorer" };
        reveal.Click += (_, _) => Explorer.Reveal(model.PathOf(id));
        menu.Items.Add(reveal);
        var stage = new MenuItem { Header = "Stage for cleanup" };
        stage.Click += (_, _) => model.Stage(id, "from treemap");
        menu.Items.Add(stage);
        menu.IsOpen = true;
    }

    private void OnMove(object sender, MouseEventArgs e)
    {
        var hit = HitAt(e.GetPosition(this));
        if (hit != (_hoverId >= 0 ? _hoverId : (int?)null))
        {
            _hoverId = hit ?? -1;
            InvalidateVisual();
        }
        var model = ScanModel.Shared;
        if (hit is { } id && model.Tree is { } tree)
        {
            string tip = $"{tree.NameOf(id)} — {ByteFormat.Format(model.Totals[id])}";
            if (_tooltip is null) _tooltip = new ToolTip();
            if (!Equals(_tooltip.Content, tip)) { _tooltip.Content = tip; }
            ToolTip = _tooltip;
            _tooltip.IsOpen = true;
        }
        else if (_tooltip is not null)
        {
            _tooltip.IsOpen = false;
        }
    }

    private int? HitAt(Point p) =>
        SquarifiedTreemap.HitTest(_rects, new DmPoint(p.X, p.Y));
}
