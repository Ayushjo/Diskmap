namespace DiskMap.Core;

/// <summary>
/// Drive capacity numbers for the sidebar card and the Overview
/// reconciliation — the Windows counterpart of the macOS `statfs` call.
/// </summary>
public readonly record struct VolumeInfo(
    string DriveLabel,
    string DriveFormat,
    long TotalBytes,
    long FreeBytes)
{
    public long UsedBytes => TotalBytes - FreeBytes;
    public double UsedFraction => TotalBytes > 0 ? (double)UsedBytes / TotalBytes : 0;
}

public static class VolumeStats
{
    /// <summary>
    /// Capacity of the volume containing <paramref name="path"/>; null
    /// when the drive can't be resolved (UNC root removed, etc.).
    /// </summary>
    public static VolumeInfo? Of(string? path)
    {
        try
        {
            string target = path is { Length: > 0 } ? Path.GetFullPath(path) : Environment.SystemDirectory;
            string? root = Path.GetPathRoot(target);
            if (root is null) return null;
            var drive = new DriveInfo(root);
            if (!drive.IsReady) return null;
            string label = drive.VolumeLabel is { Length: > 0 } v
                ? $"{v} ({drive.Name.TrimEnd('\\')})"
                : drive.Name.TrimEnd('\\');
            return new VolumeInfo(label, drive.DriveFormat, drive.TotalSize, drive.AvailableFreeSpace);
        }
        catch (Exception)
        {
            return null;
        }
    }
}
