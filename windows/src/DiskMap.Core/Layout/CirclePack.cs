namespace DiskMap.Core;

public readonly record struct PackedCircle(string Id, double X, double Y, double Radius);

/// <summary>
/// Circle packing for the bubbles view. Radii come from sqrt(size) so
/// area tracks size. Each sibling is seated tangent to an already placed
/// circle, at the angle closest to the origin that clears the others. A
/// separation pass then pushes any remaining intersection apart, so a
/// missed sample cannot leave two circles overlapping. The enclosing
/// circle may contain empty space.
/// </summary>
public static class CirclePack
{
    public static List<PackedCircle> Pack(List<ChartSlice> slices) => PackNodes(slices).Circles;

    private sealed class Node
    {
        public required string Id;
        public required double Radius;
        public double X;
        public double Y;
        public List<Node> Children = [];
    }

    private static (List<PackedCircle> Circles, double Enclosing) PackNodes(List<ChartSlice> slices)
    {
        var nodes = slices
            .Where(s => s.Size > 0)
            .OrderByDescending(s => s.Size)
            .Select(slice =>
            {
                if (slice.Children.Count == 0)
                {
                    return new Node { Id = slice.Id, Radius = Math.Sqrt(slice.Size) };
                }
                var nested = PackNodes(slice.Children);
                double radius = Math.Max(Math.Sqrt(slice.Size), nested.Enclosing);
                return new Node { Id = slice.Id, Radius = radius, Children = ScaleInto(nested.Circles, radius) };
            })
            .ToList();

        PlaceSiblings(nodes);
        var circles = new List<PackedCircle>();
        foreach (var node in nodes)
        {
            circles.Add(new PackedCircle(node.Id, node.X, node.Y, node.Radius));
            foreach (var child in node.Children)
                circles.Add(new PackedCircle(child.Id, node.X + child.X, node.Y + child.Y, child.Radius));
        }
        return (circles, EnclosingRadius(nodes));
    }

    private static List<Node> ScaleInto(List<PackedCircle> circles, double enclosing)
    {
        double current = circles.Aggregate(0.0, (r, c) => Math.Max(r, Math.Sqrt(c.X * c.X + c.Y * c.Y) + c.Radius));
        double scale = current > 0 ? Math.Min(1, enclosing / current) : 1;
        return circles.Select(c => new Node { Id = c.Id, Radius = c.Radius * scale, X = c.X * scale, Y = c.Y * scale }).ToList();
    }

    private static double EnclosingRadius(List<Node> nodes) =>
        nodes.Aggregate(0.0, (r, n) => Math.Max(r, Math.Sqrt(n.X * n.X + n.Y * n.Y) + n.Radius));

    private static void PlaceSiblings(List<Node> nodes)
    {
        if (nodes.Count == 0) return;
        nodes[0].X = 0;
        nodes[0].Y = 0;
        if (nodes.Count == 1) return;
        nodes[1].X = nodes[0].Radius + nodes[1].Radius;
        nodes[1].Y = 0;
        const int samples = 72;
        for (int index = 2; index < nodes.Count; index++)
        {
            double bestX = nodes[index - 1].X + nodes[index - 1].Radius + nodes[index].Radius;
            double bestY = 0;
            double bestScore = double.MaxValue;
            for (int host = 0; host < index; host++)
            {
                double distance = nodes[host].Radius + nodes[index].Radius;
                for (int step = 0; step < samples; step++)
                {
                    double angle = (double)step / samples * 2 * Math.PI;
                    double x = nodes[host].X + Math.Cos(angle) * distance;
                    double y = nodes[host].Y + Math.Sin(angle) * distance;
                    if (!Clears(x, y, nodes[index].Radius, nodes, index)) continue;
                    double score = x * x + y * y;
                    if (score < bestScore)
                    {
                        bestScore = score;
                        bestX = x;
                        bestY = y;
                    }
                }
            }
            nodes[index].X = bestX;
            nodes[index].Y = bestY;
        }
        Separate(nodes);
    }

    private static bool Clears(double x, double y, double radius, List<Node> nodes, int count)
    {
        for (int i = 0; i < count; i++)
        {
            double dx = x - nodes[i].X;
            double dy = y - nodes[i].Y;
            double minDist = radius + nodes[i].Radius;
            if (dx * dx + dy * dy < minDist * minDist - 1e-6) return false;
        }
        return true;
    }

    private static void Separate(List<Node> nodes)
    {
        if (nodes.Count <= 1) return;
        for (int iter = 0; iter < 100; iter++)
        {
            bool moved = false;
            for (int i = 0; i < nodes.Count; i++)
            {
                for (int j = i + 1; j < nodes.Count; j++)
                {
                    double dx = nodes[j].X - nodes[i].X;
                    double dy = nodes[j].Y - nodes[i].Y;
                    double dist = Math.Sqrt(dx * dx + dy * dy);
                    double minDist = nodes[i].Radius + nodes[j].Radius;
                    if (dist >= minDist - 1e-6) continue;
                    double push = (minDist - dist) / 2 + 1e-4;
                    double ux = dist > 0 ? dx / dist : 1;
                    double uy = dist > 0 ? dy / dist : 0;
                    nodes[i].X -= ux * push;
                    nodes[i].Y -= uy * push;
                    nodes[j].X += ux * push;
                    nodes[j].Y += uy * push;
                    moved = true;
                }
            }
            if (!moved) return;
        }
    }
}
