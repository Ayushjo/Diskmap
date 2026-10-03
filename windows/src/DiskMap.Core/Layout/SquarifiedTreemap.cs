namespace DiskMap.Core;

public readonly record struct TreemapRect(int Id, DmRect Rect);

/// <summary>
/// Squarified treemap layout (Bruls, Huizing, van Wijk, "Squarified
/// Treemaps", 2000) — the algorithm behind WinDirStat, GrandPerspective,
/// and most disk-usage treemaps. Greedily builds rows/columns that keep
/// rectangles as close to square as possible, which is what keeps small
/// files legible instead of degenerating into 1px slivers.
///
/// Ported from the macOS implementation, which is verified against the
/// paper's section 3.1 example: sizes [6, 6, 4, 3, 2, 2, 1] in a 6×4
/// rectangle. Rectangles are placed from rect.MinX/MinY advancing in
/// +x/+y, so the first item is the top-left. Equal aspect ratios still
/// accept the candidate (&lt;=), matching the paper's worst(row) &ge;
/// worst(row++[c]).
/// </summary>
public static class SquarifiedTreemap
{
    public static List<TreemapRect> Layout(List<(int Id, long Size)> items, DmRect rect)
    {
        var result = new List<TreemapRect>();
        if (items.Count == 0 || rect.Width <= 0 || rect.Height <= 0) return result;

        var sorted = items
            .Where(i => i.Size > 0)
            .OrderByDescending(i => i.Size)
            .Select(i => (i.Id, Size: (double)i.Size))
            .ToList();
        if (sorted.Count == 0) return result;

        Squarify(sorted, rect, result);
        return result;
    }

    /// <summary>
    /// Topmost rectangle containing <paramref name="point"/>, if any.
    /// Layouts from <see cref="Layout"/> do not overlap; last-match still
    /// prefers a later rect when a point sits on a shared edge.
    /// </summary>
    public static int? HitTest(List<TreemapRect> rects, DmPoint point)
    {
        for (int i = rects.Count - 1; i >= 0; i--)
            if (rects[i].Rect.Contains(point)) return rects[i].Id;
        return null;
    }

    /// <summary>
    /// The row is items[start..end). Linear per row: a running total
    /// replaces re-summing the remainder, and the worst aspect ratio needs
    /// only the row's largest and smallest items — a folder with tens of
    /// thousands of children used to stall the UI thread for seconds.
    /// </summary>
    private static void Squarify(List<(int Id, double Size)> items, DmRect rect, List<TreemapRect> result)
    {
        double total = 0;
        foreach (var item in items) total += item.Size; // integer byte counts: sums stay exact
        int start = 0;
        while (start < items.Count && rect.Width > 0 && rect.Height > 0)
        {
            if (start == items.Count - 1)
            {
                result.Add(new TreemapRect(items[start].Id, rect));
                return;
            }
            if (total <= 0) return;

            // The paper's width() is the shorter side of the *remaining*
            // rectangle. A row is a strip spanning that side.
            double shortSide = Math.Min(rect.Width, rect.Height);
            double rectArea = rect.Width * rect.Height;

            int end = start;
            double rowSum = 0;
            double bestWorst = double.PositiveInfinity;
            while (end < items.Count)
            {
                double proposedSum = rowSum + items[end].Size;
                // Sorted descending: the row's extremes are its first item
                // and the candidate.
                double worst = WorstAspectRatio(
                    items[start].Size, items[end].Size, proposedSum, shortSide, rectArea, total);

                if (end == start || worst <= bestWorst)
                {
                    rowSum = proposedSum;
                    bestWorst = worst;
                    end++;
                }
                else
                {
                    break;
                }
            }

            rect = Place(items, start, end, rowSum, total, rect, result);
            total -= rowSum;
            start = end;
        }
    }

    /// <summary>
    /// Lays items[start..end) along the shorter side. The last item in the
    /// row absorbs rounding leftover so the strip is covered exactly.
    /// Returns the unused remainder of <paramref name="rect"/>.
    /// </summary>
    private static DmRect Place(
        List<(int Id, double Size)> items,
        int start,
        int end,
        double sum,
        double total,
        DmRect rect,
        List<TreemapRect> result)
    {
        bool spansHeight = rect.Width >= rect.Height;
        if (spansHeight)
        {
            double colWidth = rect.Width * (sum / total);
            double y = rect.MinY;
            for (int i = start; i < end; i++)
            {
                double height = i == end - 1
                    ? rect.MaxY - y
                    : rect.Height * (items[i].Size / sum);
                result.Add(new TreemapRect(items[i].Id, new DmRect(rect.MinX, y, colWidth, height)));
                y += height;
            }
            double usedMaxX = rect.MinX + colWidth;
            return new DmRect(usedMaxX, rect.MinY, rect.MaxX - usedMaxX, rect.Height);
        }
        else
        {
            double rowHeight = rect.Height * (sum / total);
            double x = rect.MinX;
            for (int i = start; i < end; i++)
            {
                double width = i == end - 1
                    ? rect.MaxX - x
                    : rect.Width * (items[i].Size / sum);
                result.Add(new TreemapRect(items[i].Id, new DmRect(x, rect.MinY, width, rowHeight)));
                x += width;
            }
            double usedMaxY = rect.MinY + rowHeight;
            return new DmRect(rect.MinX, usedMaxY, rect.Width, rect.MaxY - usedMaxY);
        }
    }

    /// <summary>
    /// Highest aspect ratio in a candidate row. This is the paper's
    /// worst(R, w) = max(w²·r₊/s², s²/(w²·r₋)) after scaling sizes so they
    /// sum to the remaining rectangle's area — not to shortSide², which is
    /// only correct when the rectangle is already square. A cell's aspect
    /// ratio falls then rises with its size, so the row's largest and
    /// smallest items bound it.
    /// </summary>
    private static double WorstAspectRatio(
        double largest,
        double smallest,
        double sum,
        double shortSide,
        double rectArea,
        double total)
    {
        if (sum <= 0 || shortSide <= 0 || rectArea <= 0 || total <= 0)
            return double.PositiveInfinity;
        double thickness = sum / total * rectArea / shortSide;
        if (thickness <= 0 || smallest <= 0) return double.PositiveInfinity;

        double Aspect(double size)
        {
            double length = size / sum * shortSide;
            return length >= thickness ? length / thickness : thickness / length;
        }
        return Math.Max(Aspect(largest), Aspect(smallest));
    }
}
