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
    /// <summary>
    /// WIN-061: the map announces itself and its slices to UIA — the top
    /// 60 cells as "name, X, Y%" items, folders marked drillable —
    /// matching macOS's accessible-list cap.
    /// </summary>
    protected override System.Windows.Automation.Peers.AutomationPeer OnCreateAutomationPeer() =>
        new TreemapPeer(this);

    private sealed class TreemapPeer : System.Windows.Automation.Peers.FrameworkElementAutomationPeer
    {
        public TreemapPeer(TreemapControl owner) : base(owner) { }

        protected override string GetNameCore()
        {
            var model = ScanModel.Shared;
            var tree = model.Tree;
            int count = ((TreemapControl)Owner)._rects.Count;
            return tree is null
                ? "Storage treemap — no scan"
                : $"Storage treemap — {tree.NameOf(model.ZoomedNode)}, {count} cells";
        }

        protected override List<System.Windows.Automation.Peers.AutomationPeer> GetChildrenCore()
        {
            var owner = (TreemapControl)Owner;
            var model = ScanModel.Shared;
            var tree = model.Tree;
            var peers = new List<System.Windows.Automation.Peers.AutomationPeer>();
            if (tree is null) return peers;
            long total = Math.Max(1, model.Totals[model.ZoomedNode]);
            foreach (var r in owner._rects.OrderByDescending(r =>
                r.Id >= 0 && r.Id < model.Totals.Length ? model.Totals[r.Id] : 0).Take(60))
            {
                if (r.Id == OtherId || r.Id < 0 || r.Id >= tree.Count) continue;
                string share = $"{100.0 * model.Totals[r.Id] / total:0.#}%";
                bool dir = tree.IsDirectory[r.Id];
                peers.Add(new SlicePeer(
                    $"{tree.NameOf(r.Id)}, {ByteFormat.Format(model.Totals[r.Id])}, {share}"
                        + (dir ? ", folder — double-click to enter" : "")));
            }
            return peers;
        }

        private sealed class SlicePeer : System.Windows.Automation.Peers.AutomationPeer
        {
            private readonly string _name;
            public SlicePeer(string name) => _name = name;
            protected override string GetNameCore() => _name;
            protected override string GetItemTypeCore() => "chart cell";
            protected override System.Windows.Automation.Peers.AutomationControlType GetAutomationControlTypeCore() =>
                System.Windows.Automation.Peers.AutomationControlType.ListItem;
            protected override bool IsContentElementCore() => true;
            protected override bool IsControlElementCore() => true;
            protected override string GetClassNameCore() => "TreemapCell";
            protected override string GetAutomationIdCore() => _name;
            protected override string GetAcceleratorKeyCore() => "";
            protected override string GetAccessKeyCore() => "";
            protected override string GetHelpTextCore() => "";
            protected override string GetItemStatusCore() => "";
            protected override System.Windows.Automation.Peers.AutomationPeer? GetLabeledByCore() => null;
            protected override bool IsKeyboardFocusableCore() => false;
            protected override bool IsOffscreenCore() => false;
            protected override bool IsPasswordCore() => false;
            protected override bool IsRequiredForFormCore() => false;
            protected override bool IsEnabledCore() => true;
            protected override System.Windows.Automation.Peers.AutomationOrientation GetOrientationCore() =>
                System.Windows.Automation.Peers.AutomationOrientation.None;
            protected override bool HasKeyboardFocusCore() => false;
            protected override Rect GetBoundingRectangleCore() => Rect.Empty;
            protected override System.Windows.Point GetClickablePointCore() => new(double.NaN, double.NaN);
            protected override void SetFocusCore() { }
            protected override System.Windows.Automation.Peers.AutomationPeer? GetPeerFromPointCore(System.Windows.Point point) => null;
            protected override List<System.Windows.Automation.Peers.AutomationPeer>? GetChildrenCore() => null;
            public override object? GetPattern(System.Windows.Automation.Peers.PatternInterface patternInterface) => null;
        }
    }

    /// <summary>WIN-061: arrow keys move the selection across cells (visual order = layout order).</summary>
    protected override void OnKeyDown(KeyEventArgs e)
    {
        var model = ScanModel.Shared;
        int index = _rects.FindIndex(r => r.Id == model.SelectedNode);
        if (index < 0) index = 0;
        int delta = e.Key switch
        {
            Key.Right or Key.Down => 1,
            Key.Left or Key.Up => -1,
            _ => 0,
        };
        if (delta != 0 && _rects.Count > 0)
        {
            var next = _rects[(index + delta + _rects.Count) % _rects.Count];
            if (next.Id != OtherId) { model.Select(next.Id); DrawSelection(); }
            e.Handled = true;
        }
        else if (e.Key == Key.Enter && index >= 0
            && model.Tree?.IsDirectory[_rects[index].Id] == true)
        {
            model.DrillTo(_rects[index].Id);
            e.Handled = true;
        }
        else if (e.Key == Key.Escape)
        {
            model.ClearMulti();
            e.Handled = true;
        }
        base.OnKeyDown(e);
    }

    private readonly DrawingVisual _map = new();
    private readonly DrawingVisual _hover = new();
    private readonly DrawingVisual _selection = new();
    private List<TreemapRect> _rects = [];
    private (FileTree? Tree, long[]? Totals, int Zoom, Size Size) _drawn;
    /// <summary>Sentinel tile id for the depth-collapsed remainder — never drillable, never in the tree.</summary>
    private const int OtherId = int.MinValue;
    private string _otherLabel = "Other";
    private int _hoverId = -1;
    private int _lastSelectedDrawn = -1;
    private double _lastDepth;
    private string? _lastMode;
    private readonly Dictionary<int, Brush> _kindBrushCache = [];
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
        Focusable = true;   // WIN-061: arrow-key chart navigation
    }

    protected override int VisualChildrenCount => 3;
    protected override Visual GetVisualChild(int index) =>
        index == 0 ? _map : index == 1 ? _hover : _selection;

    /// <summary>
    /// Tile fill for a node under the active coloring mode (WIN-048):
    /// type → dominant-kind pastel; age → forgotten-band ramp by dominant
    /// age; folder → a stable hue per sibling so ownership reads at a
    /// glance. Cached per (tree, totals, mode) — the layer swaps, the
    /// geometry doesn't.
    /// </summary>
    private Brush FillFor(int id)
    {
        var model = ScanModel.Shared;
        var tree = model.Tree;
        if (tree is null || id == OtherId) return NodeColors.OtherBrush;
        if (_kindCacheKey != (tree, model.Totals, model.ColoringMode))
        {
            _kindBrushCache.Clear();
            _kindCacheKey = (tree, model.Totals, model.ColoringMode);
        }
        if (_kindBrushCache.TryGetValue(id, out var cached)) return cached;
        var brush = model.ColoringMode switch
        {
            "age" => AgeBrush(tree, model.Totals, id),
            "folder" => FolderBrush(tree.NameOf(id)),
            _ => Ui.Hex(FileTypes.TileColorOf(FileTypes.DominantKind(tree, model.Totals, id))),
        };
        _kindBrushCache[id] = brush;
        return brush;
    }

    private (FileTree? Tree, long[]? Totals, string? Mode) _kindCacheKey;

    /// <summary>Age ramp: the Forgotten Files palette, dominant bucket by bytes.</summary>
    private static Brush AgeBrush(FileTree tree, long[] totals, int id)
    {
        var buckets = new Dictionary<AgeBucket, long>();
        var stack = new Stack<int>([id]);
        while (stack.TryPop(out int n))
        {
            if (tree.IsDirectory[n])
            {
                int c = tree.FirstChild[n];
                while (c != -1) { stack.Push(c); c = tree.NextSibling[c]; }
            }
            else
            {
                var b = AgeMap.Bucket(tree.ModifiedDay[n], AgeMap.Today());
                buckets[b] = buckets.GetValueOrDefault(b) + totals[n];
            }
        }
        var dominant = buckets.OrderByDescending(kv => kv.Value).FirstOrDefault().Key;
        return dominant switch
        {
            AgeBucket.Under30 => Ui.Hex("#4ADE80"),
            AgeBucket.Days30To90 => Ui.Hex("#86EFAC"),
            AgeBucket.Days90To365 => Ui.Hex("#FDE68A"),
            AgeBucket.OneToTwoYears => Ui.Hex("#F0A95F"),
            AgeBucket.OverTwoYears => Ui.Hex("#DC2626"),
            _ => NodeColors.OtherBrush,
        };
    }

    /// <summary>Folder mode: one stable pastel per name — siblings read as distinct owners.</summary>
    private static Brush FolderBrush(string name)
    {
        string[] palette =
            ["#BFDBFE", "#FBCFE8", "#BBF7D0", "#FDE68A", "#DDD6FE",
             "#FED7AA", "#A5F3FC", "#FECACA", "#D9F99D", "#F5D0FE"];
        int hash = 0;
        foreach (char c in name) hash = hash * 31 + char.ToLowerInvariant(c);
        return Ui.Hex(palette[Math.Abs(hash) % palette.Length]);
    }

    private void Redraw()
    {
        var model = ScanModel.Shared;
        var tree = model.Tree;
        var totals = model.Totals;
        var size = new Size(ActualWidth, ActualHeight);
        bool same = _drawn == (tree, totals, model.ZoomedNode, size)
            && _lastDepth == model.ChartDepth && _lastMode == model.ColoringMode;
        if (same && _lastSelectedDrawn == model.SelectedNode) return;
        _drawn = (tree, totals, model.ZoomedNode, size);
        _lastDepth = model.ChartDepth;
        _lastMode = model.ColoringMode;
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
                // Depth slider: children under zoomTotal × ChartDepth
                // collapse into one "Other" tile (id = OtherId) — the
                // same fraction the ring charts use.
                long zoomTotal = Math.Max(1, totals[model.ZoomedNode]);
                double threshold = zoomTotal * model.ChartDepth;
                var children = tree.ChildrenOf(model.ZoomedNode, totals);
                var items = children.Where(c => c.Size >= threshold)
                    .Select(c => (c.Id, c.Size)).ToList();
                long otherSize = children.Where(c => c.Size < threshold).Sum(c => c.Size);
                int otherCount = children.Count(c => c.Size < threshold);
                _otherLabel = $"Other ({otherCount:N0})";
                if (otherSize > 0) items.Add((OtherId, otherSize));
                _rects = SquarifiedTreemap.Layout(items, new DmRect(0, 0, size.Width, size.Height));
                var nameFace = new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);
                var smallFace = new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
                double dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
                foreach (var r in _rects)
                {
                    var rect = Inset(r.Rect);
                    if (rect.Width <= 0 || rect.Height <= 0) continue;
                    dc.DrawRectangle(FillFor(r.Id), null, rect);
                    bool isOther = r.Id == OtherId;
                    long shown = isOther ? items.First(i => i.Id == OtherId).Size : totals[r.Id];
                    string label = isOther ? _otherLabel : tree.NameOf(r.Id);

                    // Label when the cell is big enough: name / size / share.
                    if (rect.Width > 52 && rect.Height > 40)
                    {
                        var nameText = new FormattedText(
                            label, System.Globalization.CultureInfo.CurrentUICulture,
                            FlowDirection.LeftToRight, nameFace, 11, Brushes.White, dpi)
                        {
                            MaxTextWidth = Math.Max(10, rect.Width - 12),
                            MaxLineCount = 1,
                            Trimming = TextTrimming.CharacterEllipsis,
                        };
                        var sizeText = new FormattedText(
                            ByteFormat.Format(shown), System.Globalization.CultureInfo.CurrentUICulture,
                            FlowDirection.LeftToRight, smallFace, 10, Brushes.White, dpi);
                        var shareText = new FormattedText(
                            $"{100.0 * shown / zoomTotal:0.#}%", System.Globalization.CultureInfo.CurrentUICulture,
                            FlowDirection.LeftToRight, smallFace, 10, Brushes.White, dpi);
                        dc.DrawText(nameText, new Point(rect.X + 8, rect.Y + 6));
                        dc.DrawText(sizeText, new Point(rect.X + 8, rect.Y + 21));
                        dc.DrawText(shareText, new Point(rect.X + 8, rect.Y + 35));
                    }
                    else if (rect.Width > 36 && rect.Height > 18)
                    {
                        var nameText = new FormattedText(
                            label, System.Globalization.CultureInfo.CurrentUICulture,
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
        // Multi-selected cells get the accent outline; the focused cell
        // the white one.
        var accentPen = new Pen(Ui.Brush("AppAccent"), 2);
        foreach (var cell in _rects)
        {
            if (cell.Id >= 0 && model.MultiSelection.Contains(cell.Id))
                dc.DrawRectangle(null, accentPen, Inset(cell.Rect));
        }
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
        if (hit is { } h && model.Tree is { } tree && h.Id >= 0 && h.Id < model.Totals.Length)
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
        if (HitAt(e.GetPosition(this)) is not { } hit || hit.Id == OtherId) return;
        var model = ScanModel.Shared;
        // WIN-052: Ctrl+click toggles the shared multi-select set;
        // a plain click drops back to single selection.
        if (Keyboard.Modifiers == ModifierKeys.Control && e.ClickCount == 1)
        {
            model.ToggleMulti(hit.Id);
            DrawSelection();
            return;
        }
        if (e.ClickCount >= 2)
        {
            if (model.Tree?.IsDirectory[hit.Id] == true)
                model.DrillTo(hit.Id);
        }
        else
        {
            model.ClearMulti();
            model.Select(hit.Id);
            DrawSelection();
        }
    }

    private void OnRightClick(object sender, MouseButtonEventArgs e)
    {
        if (HitAt(e.GetPosition(this)) is not { } hit || hit.Id == OtherId) return;
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
