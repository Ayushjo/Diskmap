using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Media;
using DiskMap.Core;

namespace DiskMap.App;

/// <summary>
/// Stable per-node colors: hue derived from the node id so the same node
/// renders the same color across pages, matching the macOS build's
/// hash-based palette (id * 2654435761 % 360, saturation .55, value .85).
/// </summary>
public static class NodeColors
{
    public static Color ColorFor(int nodeId)
    {
        unchecked
        {
            // Same hash→hue as macOS nodeColor: id * 2654435761 % 360,
            // saturation .55, brightness .82.
            double hue = (uint)((ulong)nodeId * 2654435761UL) % 360;
            return Hsv(hue, 0.55, 0.82);
        }
    }

    /// <summary>Collapsed "Other" slices — gray at 55% like the macOS build.</summary>
    public static readonly Brush OtherBrush = Freeze(new SolidColorBrush(Color.FromArgb(140, 128, 128, 128)));

    public static Brush BrushFor(int nodeId)
    {
        var brush = new SolidColorBrush(ColorFor(nodeId));
        brush.Freeze();
        return brush;
    }

    private static Color Hsv(double h, double s, double v)
    {
        double c = v * s;
        double x = c * (1 - Math.Abs((h / 60) % 2 - 1));
        double m = v - c;
        (double r, double g, double b) = h switch
        {
            < 60 => (c, x, 0.0),
            < 120 => (x, c, 0.0),
            < 180 => (0.0, c, x),
            < 240 => (0.0, x, c),
            < 300 => (x, 0.0, c),
            _ => (c, 0.0, x),
        };
        return Color.FromRgb(
            (byte)((r + m) * 255), (byte)((g + m) * 255), (byte)((b + m) * 255));
    }

    public static readonly Brush DirectoryOverlay = Freeze(new SolidColorBrush(Color.FromArgb(0x20, 0, 0, 0)));
    public static readonly Brush Stroke = Freeze(new SolidColorBrush(Color.FromArgb(0x59, 0, 0, 0)));

    /// <summary>Age-map bucket colors — ported from macOS AgeMapView.</summary>
    public static Brush AgeBucket(AgeBucket bucket) => Freeze(new SolidColorBrush(bucket switch
    {
        Core.AgeBucket.Under30 => Hsv(0.42 * 360, 0.45, 0.72),
        Core.AgeBucket.Days30To90 => Hsv(0.38 * 360, 0.5, 0.62),
        Core.AgeBucket.Days90To365 => Hsv(0.12 * 360, 0.55, 0.78),
        Core.AgeBucket.OneToTwoYears => Hsv(0.06 * 360, 0.65, 0.72),
        Core.AgeBucket.OverTwoYears => Hsv(0.02 * 360, 0.7, 0.55),
        _ => Hsv(0, 0, 0.6),
    }));

    private static T Freeze<T>(T freezable) where T : Freezable { freezable.Freeze(); return freezable; }
}

public static class ByteFormat
{
    /// <summary>Same scale as macOS ByteCountFormatter (decimal units).</summary>
    public static string Format(long bytes)
    {
        const long kb = 1000, mb = kb * 1000, gb = mb * 1000, tb = gb * 1000;
        return bytes switch
        {
            >= tb => $"{bytes / (double)tb:0.##} TB",
            >= gb => $"{bytes / (double)gb:0.##} GB",
            >= mb => $"{bytes / (double)mb:0.##} MB",
            >= kb => $"{bytes / (double)kb:0.#} KB",
            _ => $"{bytes} B",
        };
    }
}

/// <summary>
/// Explorer integration — the Windows counterpart of Quick Look / Reveal.
/// </summary>
public static class Explorer
{
    public static void Reveal(string path)
    {
        try
        {
            if (File.Exists(path) || Directory.Exists(path))
                Process.Start("explorer.exe", $"/select,\"{path}\"");
            else
                Process.Start("explorer.exe", $"\"{Path.GetDirectoryName(path) ?? path}\"");
        }
        catch { /* explorer missing is not fatal */ }
    }

    public static void Open(string path)
    {
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
        catch { }
    }
}
