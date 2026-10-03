namespace DiskMap.Core;

/// <summary>
/// Minimal geometry types so DiskMap.Core stays free of any UI-framework
/// dependency (the macOS core uses CoreGraphics; WPF has its own Rect/Point
/// which the app layer maps onto these).
/// </summary>
public readonly record struct DmRect(double X, double Y, double Width, double Height)
{
    public double MinX => X;
    public double MinY => Y;
    public double MaxX => X + Width;
    public double MaxY => Y + Height;
    public double MidX => X + Width / 2;
    public double MidY => Y + Height / 2;

    /// <summary>Matches CGRect.contains: half-open, excludes MaxX/MaxY.</summary>
    public bool Contains(DmPoint p) =>
        p.X >= MinX && p.X < MaxX && p.Y >= MinY && p.Y < MaxY;

    public DmRect Inset(double dx, double dy) =>
        new(X + dx, Y + dy, Width - dx * 2, Height - dy * 2);

    public DmRect Intersection(DmRect other)
    {
        double x = Math.Max(MinX, other.MinX);
        double y = Math.Max(MinY, other.MinY);
        double w = Math.Min(MaxX, other.MaxX) - x;
        double h = Math.Min(MaxY, other.MaxY) - y;
        return w <= 0 || h <= 0 ? new DmRect(0, 0, 0, 0) : new DmRect(x, y, w, h);
    }
}

public readonly record struct DmPoint(double X, double Y);
