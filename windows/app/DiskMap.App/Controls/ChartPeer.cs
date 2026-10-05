using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Media;

namespace DiskMap.App.Controls;

/// <summary>
/// WIN-061: UI Automation peer shared by the non-treemap charts — the
/// chart announces itself ("Sunburst — Home, N cells") and exposes its
/// biggest slices as list items, same as the treemap's peer.
/// </summary>
public sealed class ChartPeer : FrameworkElementAutomationPeer
{
    private readonly string _chartName;
    private readonly Func<IEnumerable<int>> _topIds;

    public ChartPeer(FrameworkElement owner, string chartName, Func<IEnumerable<int>> topIds)
        : base(owner)
    {
        _chartName = chartName;
        _topIds = topIds;
    }

    protected override string GetNameCore()
    {
        var model = ScanModel.Shared;
        var tree = model.Tree;
        return tree is null
            ? $"{_chartName} — no scan"
            : $"{_chartName} — {tree.NameOf(model.ZoomedNode)}";
    }

    protected override List<AutomationPeer> GetChildrenCore()
    {
        var peers = new List<AutomationPeer>();
        var model = ScanModel.Shared;
        var tree = model.Tree;
        if (tree is null || model.ZoomedNode >= model.Totals.Length) return peers;
        long total = Math.Max(1, model.Totals[model.ZoomedNode]);
        foreach (int id in _topIds())
        {
            string share = $"{100.0 * model.Totals[id] / total:0.#}%";
            bool dir = tree.IsDirectory[id];
            peers.Add(new ChartItemPeer(
                $"{tree.NameOf(id)}, {ByteFormat.Format(model.Totals[id])}, {share}"
                    + (dir ? ", folder — double-click to enter" : "")));
        }
        return peers;
    }
}

/// <summary>One accessible chart cell — "name, size, share[, folder]" text only.</summary>
public sealed class ChartItemPeer : AutomationPeer
{
    private readonly string _name;
    public ChartItemPeer(string name) => _name = name;
    protected override string GetNameCore() => _name;
    protected override string GetItemTypeCore() => "chart cell";
    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.ListItem;
    protected override bool IsContentElementCore() => true;
    protected override bool IsControlElementCore() => true;
    protected override string GetClassNameCore() => "ChartCell";
    protected override string GetAutomationIdCore() => _name;
    protected override string GetAcceleratorKeyCore() => "";
    protected override string GetAccessKeyCore() => "";
    protected override string GetHelpTextCore() => "";
    protected override string GetItemStatusCore() => "";
    protected override AutomationPeer? GetLabeledByCore() => null;
    protected override bool IsKeyboardFocusableCore() => false;
    protected override bool IsOffscreenCore() => false;
    protected override bool IsPasswordCore() => false;
    protected override bool IsRequiredForFormCore() => false;
    protected override bool IsEnabledCore() => true;
    protected override AutomationOrientation GetOrientationCore() => AutomationOrientation.None;
    protected override bool HasKeyboardFocusCore() => false;
    protected override Rect GetBoundingRectangleCore() => Rect.Empty;
    protected override Point GetClickablePointCore() => new(double.NaN, double.NaN);
    protected override void SetFocusCore() { }
    protected override AutomationPeer? GetPeerFromPointCore(Point point) => null;
    protected override List<AutomationPeer>? GetChildrenCore() => null;
    public override object? GetPattern(PatternInterface patternInterface) => null;
}
