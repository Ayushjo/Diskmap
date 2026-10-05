using System.Windows.Input;
using DiskMap.Core;

namespace DiskMap.App.Controls;

/// <summary>
/// WIN-061: the shared arrow-key model for the radial/stacked charts —
/// the macOS ChartNavigation contract. Left/Right move between siblings,
/// Up selects the containing slice, Down the first child, Enter drills a
/// directory, Esc clears the multi-selection. The treemap keeps its own
/// flat-index variant; its cells have no parent links.
/// </summary>
internal static class ChartNavigation
{
    /// <summary>Depth-first flattened slices with parent links — rebuilt per render.</summary>
    public static List<(ChartSlice Slice, ChartSlice? Parent)> Flatten(List<ChartSlice> roots)
    {
        var nav = new List<(ChartSlice, ChartSlice?)>();
        void Walk(List<ChartSlice> slices, ChartSlice? parent)
        {
            foreach (var s in slices)
            {
                nav.Add((s, parent));
                Walk(s.Children, s);
            }
        }
        Walk(roots, null);
        return nav;
    }

    /// <summary>Returns true when the key moved the selection or drilled.</summary>
    public static bool OnKey(KeyEventArgs e, List<(ChartSlice Slice, ChartSlice? Parent)> nav, ScanModel model)
    {
        if (nav.Count == 0 || model.Tree is null) return false;
        int index = nav.FindIndex(n => n.Slice.NodeID == model.SelectedNode);
        if (index < 0) index = 0;
        var current = nav[index];

        switch (e.Key)
        {
            case Key.Right:
            case Key.Left:
            {
                var siblings = nav.Where(n => ReferenceEquals(n.Parent, current.Parent)).ToList();
                int at = siblings.FindIndex(n => ReferenceEquals(n.Slice, current.Slice));
                int next = at + (e.Key == Key.Right ? 1 : -1);
                if (next >= 0 && next < siblings.Count && siblings[next].Slice.NodeID is { } nid)
                {
                    model.Select(nid);
                    return true;
                }
                return false;
            }
            case Key.Up:
                if (current.Parent?.NodeID is { } pid) { model.Select(pid); return true; }
                return false;
            case Key.Down:
            {
                var child = nav.FirstOrDefault(n =>
                    ReferenceEquals(n.Parent, current.Slice) && n.Slice.NodeID is not null);
                if (child.Slice?.NodeID is { } cid) { model.Select(cid); return true; }
                return false;
            }
            case Key.Enter:
                if (current.Slice.NodeID is { } drill && model.Tree.IsDirectory[drill])
                {
                    model.DrillTo(drill);
                    return true;
                }
                return false;
            case Key.Escape:
                model.ClearMulti();
                return true;
            default:
                return false;
        }
    }

    /// <summary>Top-60 node ids by total — the accessible-item cap macOS uses.</summary>
    public static IEnumerable<int> AccessibleIds(List<(ChartSlice Slice, ChartSlice? Parent)> nav, ScanModel model)
    {
        var totals = model.Totals;
        return nav.Select(n => n.Slice)
            .Where(s => s.NodeID is { } id && id >= 0 && id < totals.Length)
            .OrderByDescending(s => totals[s.NodeID!.Value])
            .Take(60)
            .Select(s => s.NodeID!.Value);
    }
}
