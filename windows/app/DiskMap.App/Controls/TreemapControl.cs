using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using DiskMap.Core;

namespace DiskMap.App.Controls;

/// <summary>
/// Custom-drawn squarified treemap — layout comes from
/// DiskMap.Core.SquarifiedTreemap (verified port), so geometry matches
/// the macOS build exactly; only the drawing calls are platform-native.
///
/// Tiles are colored by dominant file kind (the reference design's
/// type-colored map): a folder takes the pastel of whatever category
/// holds most of its bytes; unclassifiable content falls back to the
/// neutral gray.
///
/// Interactions: click selects (inspector), double-click a directory to
/// drill in; hover shows name + size; right-click offers Reveal in
/// Explorer / Stage for cleanup.
/// </summary>
public sealed class TreemapControl : FrameworkElement
{
    private readonly DrawingVisual _map = new();
    private readonly DrawingVisual _hover = new();
    private readonly DrawingVisual _selection = new();
    private List<TreemapRect> _rects = [];
    private (FileTree? Tree, long[]? Totals, int Zoom, Size Size) _drawn;
    private int _hoverId = -1;
    private int _lastSelectedDrawn = -1;
    private readonly Dictionary<int, Brush> _kindBrushCache = [];
    private (FileTree? Tree, long[]? Totals) _kindCacheKey;
    private readonly ToolTip _tooltip = new() { Placement = System.Windows.Controls.Primitives.PlacementMode.Mouse };

    public TreemapControl()
    {
        AddVisualChild(_map);
        AddVisualChild(_hover);
        AddVisualChild(_selection);
        ModelEvents.WhileLoaded(this, Redraw);
        SizeChanged += (_, _) => Redraw();
        MouseLeftButtonDown += OnClick;
        MouseMove += OnMove;
        MouseLeave += (_, _) => SetHover(null);
        MouseRightButtonDown += OnRightClick;
        ToolTip = _tooltip;
        ToolTipService.SetIsEnabled(this, false); // opened by hand, per hovered cell
    }

    protected override int VisualChildrenCount => 3;
    protected override Visual GetVisualChild(int index) =>
        index == 0 ? _map : index == 1 ? _hover : _selection;

    /// <summary>Tile fill for a node: dominant-kind pastel for dirs, kind pastel for files.</summary>
    private Brush FillFor(int id)
    {
        var model = ScanModel.Shared;
        var tree = model.Tree;
        if (tree is null) return NodeColors.OtherBrush;
        if (_kindCacheKey != (tree, model.Totals))
        {
            _kindBrushCache.Clear();
            _kindCacheKey = (tree, model.Totals);
        }
        if (_kindBrushCache.TryGetValue(id, out var cached)) return cached;
        string kind = FileTypes.DominantKind(tree, model.Totals, id);
        var brush = Ui.Hex(FileTypes.TileColorOf(kind));
        _kindBrushCache[id] = brush;
        return brush;
    }

    private void Redraw()
    {
        var model = ScanModel.Shared;
        var tree = model.Tree;
        var totals = model.Totals;
        var size = new Size(ActualWidth, ActualHeight);
        bool same = _drawn == (tree, totals, model.ZoomedNode, size);
        if (same && _lastSelectedDrawn == model.SelectedNode) return;
        _drawn = (tree, totals, model.ZoomedNode, size);
        SetHover(null);

        using (var dc = _map.RenderOpen())
        {
            // Paint the whole area so the gaps between cells still take the mouse.
            dc.DrawRectangle(Brushes.Transparent, null, new Rect(size));
            if (tree is null || totals.Length != tree.Count || size.Width <= 0 || size.Height <= 0)
            {
                _rects = [];
            }
            else
            {
                _rects = SquarifiedTreemap.Layout(
                    tree.ChildrenOf(model.ZoomedNode, totals), new DmRect(0, 0, size.Width, size.Height));
                var nameFace = new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);
                var smallFace = new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
                double dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
                long zoomTotal = Math.Max(1, totals[model.ZoomedNode]);
                foreach (var r in _rects)
                {
                    var rect = Inset(r.Rect);
                    if (rect.Width <= 0 || rect.Height <= 0) continue;
                    dc.DrawRectangle(FillFor(r.Id), null, rect);

                    // Label when the cell is big enough: name / size / share.
                    if (rect.Width > 52 && rect.Height > 40)
                    {
                        var nameText = new FormattedText(
                            tree.NameOf(r.Id), System.Globalization.CultureInfo.CurrentUICulture,
                            FlowDirection.LeftToRight, nameFace, 11, Brushes.White, dpi)
                        {
                            MaxTextWidth = Math.Max(10, rect.Width - 12),
                            MaxLineCount = 1,
                            Trimming = TextTrimming.CharacterEllipsis,
                        };
                        var sizeText = new FormattedText(
                            ByteFormat.Format(totals[r.Id]), System.Globalization.CultureInfo.CurrentUICulture,
                            FlowDirection.LeftToRight, smallFace, 10, Brushes.White, dpi);
                        var shareText = new FormattedText(
                            $"{100.0 * totals[r.Id] / zoomTotal:0.#}%", System.Globalization.CultureInfo.CurrentUICulture,
                            FlowDirection.LeftToRight, smallFace, 10, Brushes.White, dpi);
                        dc.DrawText(nameText, new Point(rect.X + 8, rect.Y + 6));
                        dc.DrawText(sizeText, new Point(rect.X + 8, rect.Y + 21));
                        dc.DrawText(shareText, new Point(rect.X + 8, rect.Y + 35));
                    }
                    else if (rect.Width > 36 && rect.Height > 18)
                    {
                        var nameText = new FormattedText(
                            tree.NameOf(r.Id), System.Globalization.CultureInfo.CurrentUICulture,
                            FlowDirection.LeftToRight, smallFace, 10, Brushes.White, dpi)
                        {
                            MaxTextWidth = Math.Max(10, rect.Width - 10),
                            MaxLineCount = 1,
                            Trimming = TextTrimming.CharacterEllipsis,
                        };
                        dc.DrawText(nameText, new Point(rect.X + 6, rect.Y + 3));
                    }
                }
            }
        }
        if (!same || _lastSelectedDrawn != model.SelectedNode) DrawSelection();
    }

    private void DrawSelection()
    {
        var model = ScanModel.Shared;
        _lastSelectedDrawn = model.SelectedNode;
        using var dc = _selection.RenderOpen();
        var hit = _rects.FirstOrDefault(r => r.Id == model.SelectedNode);
        if (hit.Rect is { } r && r.Width > 0)
        {
            var rect = Inset(r);
            var pen = new Pen(Brushes.White, 2.5);
            dc.DrawRectangle(null, pen, rect);
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
        if (HitAt(e.GetPosition(this)) is not { } hit) return;
        if (e.ClickCount >= 2)
        {
            if (ScanModel.Shared.Tree?.IsDirectory[hit.Id] == true)
                ScanModel.Shared.DrillTo(hit.Id);
        }
        else
        {
            ScanModel.Shared.Select(hit.Id);
            DrawSelection();
        }
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
