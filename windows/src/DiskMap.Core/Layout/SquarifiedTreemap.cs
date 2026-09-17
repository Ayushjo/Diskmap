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

    private static void Squarify(List<(int Id, double Size)> items, DmRect rect, List<TreemapRect> result)
    {
        while (items.Count > 0 && rect.Width > 0 && rect.Height > 0)
        {
            if (items.Count == 1)
            {
                result.Add(new TreemapRect(items[0].Id, rect));
                return;
            }

            double total = items.Sum(i => i.Size);
            if (total <= 0) return;

            // The paper's width() is the shorter side of the *remaining*
            // rectangle. A row is a strip spanning that side.
            double shortSide = Math.Min(rect.Width, rect.Height);
            double rectArea = rect.Width * rect.Height;

            var row = new List<(int Id, double Size)>();
            double rowSum = 0;
            double bestWorst = double.PositiveInfinity;
            int index = 0;

            while (index < items.Count)
            {
                var candidate = items[index];
                double proposedSum = rowSum + candidate.Size;
                var candidateSizes = row.Select(r => r.Size).Append(candidate.Size).ToList();
                double worst = WorstAspectRatio(candidateSizes, proposedSum, shortSide, rectArea, total);

                if (row.Count == 0 || worst <= bestWorst)
                {
                    row.Add(candidate);
                    rowSum = proposedSum;
                    bestWorst = worst;
                    index++;
                }
                else
                {
                    break;
                }
            }

            rect = Place(row, rowSum, total, rect, result);
            items = items[index..];
        }
    }

    /// <summary>
    /// Lays <paramref name="row"/> along the shorter side. The last item in
    /// the row absorbs rounding leftover so the strip is covered exactly.
    /// Returns the unused remainder of <paramref name="rect"/>.
    /// </summary>
    private static DmRect Place(
        List<(int Id, double Size)> row,
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
            for (int i = 0; i < row.Count; i++)
            {
                double height = i == row.Count - 1
                    ? rect.MaxY - y
                    : rect.Height * (row[i].Size / sum);
                result.Add(new TreemapRect(row[i].Id, new DmRect(rect.MinX, y, colWidth, height)));
                y += height;
            }
            double usedMaxX = rect.MinX + colWidth;
            return new DmRect(usedMaxX, rect.MinY, rect.MaxX - usedMaxX, rect.Height);
        }
        else
        {
            double rowHeight = rect.Height * (sum / total);
            double x = rect.MinX;
            for (int i = 0; i < row.Count; i++)
            {
                double width = i == row.Count - 1
                    ? rect.MaxX - x
                    : rect.Width * (row[i].Size / sum);
                result.Add(new TreemapRect(row[i].Id, new DmRect(x, rect.MinY, width, rowHeight)));
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
    /// only correct when the rectangle is already square.
    /// </summary>
    private static double WorstAspectRatio(
        List<double> sizes,
        double sum,
        double shortSide,
        double rectArea,
        double total)
    {
        if (sum <= 0 || shortSide <= 0 || rectArea <= 0 || total <= 0)
            return double.PositiveInfinity;
        double thickness = sum / total * rectArea / shortSide;
        if (thickness <= 0) return double.PositiveInfinity;

        double worst = 0;
        foreach (double size in sizes)
        {
            if (size <= 0) return double.PositiveInfinity;
            double length = size / sum * shortSide;
            double aspect = length >= thickness ? length / thickness : thickness / length;
            if (aspect > worst) worst = aspect;
        }
        return worst;
    }
}
