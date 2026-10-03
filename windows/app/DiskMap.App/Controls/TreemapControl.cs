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
/// Two retained visuals: the map (cells + labels) is laid out and drawn
/// only when the data, zoom or size changes; hover redraws a single
/// highlight rect on its own layer. Re-laying out and redrawing every cell
/// on each mouse move is what made the map crawl.
///
/// Interactions: left-click a directory to drill in; hover shows name +
/// size; right-click offers Reveal in Explorer / Stage for cleanup.
/// </summary>
public sealed class TreemapControl : FrameworkElement
{
    private readonly DrawingVisual _map = new();
    private readonly DrawingVisual _hover = new();
    private List<TreemapRect> _rects = [];
    private (FileTree? Tree, long[]? Totals, int Zoom, Size Size) _drawn;
    private int _hoverId = -1;
    private readonly ToolTip _tooltip = new() { Placement = System.Windows.Controls.Primitives.PlacementMode.Mouse };

    public TreemapControl()
    {
        AddVisualChild(_map);
        AddVisualChild(_hover);
        ModelEvents.WhileLoaded(this, Redraw);
        SizeChanged += (_, _) => Redraw();
        MouseLeftButtonDown += OnClick;
        MouseMove += OnMove;
        MouseLeave += (_, _) => SetHover(null);
        MouseRightButtonDown += OnRightClick;
        ToolTip = _tooltip;
        ToolTipService.SetIsEnabled(this, false); // opened by hand, per hovered cell
    }

    protected override int VisualChildrenCount => 2;
    protected override Visual GetVisualChild(int index) => index == 0 ? _map : _hover;

    private void Redraw()
    {
        var model = ScanModel.Shared;
        var tree = model.Tree;
        var totals = model.Totals;
        var size = new Size(ActualWidth, ActualHeight);
        if (_drawn == (tree, totals, model.ZoomedNode, size)) return;
        _drawn = (tree, totals, model.ZoomedNode, size);
        SetHover(null);

        using var dc = _map.RenderOpen();
        // Paint the whole area so the gaps between cells still take the mouse.
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(size));
        if (tree is null || totals.Length != tree.Count || size.Width <= 0 || size.Height <= 0)
        {
            _rects = [];
            return;
        }

        _rects = SquarifiedTreemap.Layout(
            tree.ChildrenOf(model.ZoomedNode, totals), new DmRect(0, 0, size.Width, size.Height));
        var typeface = new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
        double dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        foreach (var r in _rects)
        {
            var rect = Inset(r.Rect);
            if (rect.Width <= 0 || rect.Height <= 0) continue;
            dc.DrawRectangle(NodeColors.BrushFor(r.Id), NodeColors.StrokePen, rect);

            // Label when the cell is big enough to hold a name + size.
            if (rect.Width > 48 && rect.Height > 30)
            {
                var nameText = new FormattedText(
                    tree.NameOf(r.Id), System.Globalization.CultureInfo.CurrentUICulture,
                    FlowDirection.LeftToRight, typeface, 12, Brushes.White, dpi)
                {
                    MaxTextWidth = Math.Max(10, rect.Width - 8),
                    MaxLineCount = 1,
                    Trimming = TextTrimming.CharacterEllipsis,
                };
                var sizeText = new FormattedText(
                    ByteFormat.Format(totals[r.Id]), System.Globalization.CultureInfo.CurrentUICulture,
                    FlowDirection.LeftToRight, typeface, 10, Brushes.White, dpi);
                dc.DrawText(nameText, new Point(rect.X + 5, rect.Y + 4));
                dc.DrawText(sizeText, new Point(rect.X + 5, rect.Y + 19));
            }
        }
    }

    private static Rect Inset(DmRect r) =>
        new(r.X + 1, r.Y + 1, Math.Max(0, r.Width - 2), Math.Max(0, r.Height - 2));

    private void SetHover(TreemapRect? hit)
    {
        int id = hit?.Id ?? -1;
        if (id == _hoverId) return;
        _hoverId = id;
        using (var dc = _hover.RenderOpen())
        {
            if (hit is { } r) dc.DrawRectangle(NodeColors.DirectoryOverlay, null, Inset(r.Rect));
        }
        var model = ScanModel.Shared;
        if (hit is { } h && model.Tree is { } tree && h.Id < model.Totals.Length)
        {
            _tooltip.Content = $"{tree.NameOf(h.Id)} — {ByteFormat.Format(model.Totals[h.Id])}";
            _tooltip.IsOpen = false; // reopen so it follows the mouse to the new cell
            _tooltip.IsOpen = true;
        }
        else
        {
            _tooltip.IsOpen = false;
        }
    }

    private void OnClick(object sender, MouseButtonEventArgs e)
    {
        if (HitAt(e.GetPosition(this)) is { } hit && ScanModel.Shared.Tree?.IsDirectory[hit.Id] == true)
            ScanModel.Shared.DrillTo(hit.Id);
    }

    private void OnRightClick(object sender, MouseButtonEventArgs e)
    {
        if (HitAt(e.GetPosition(this)) is not { } hit) return;
        int id = hit.Id;
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

    private void OnMove(object sender, MouseEventArgs e) => SetHover(HitAt(e.GetPosition(this)));

    private TreemapRect? HitAt(Point p)
    {
        for (int i = _rects.Count - 1; i >= 0; i--)
            if (_rects[i].Rect.Contains(new DmPoint(p.X, p.Y))) return _rects[i];
        return null;
    }
}
