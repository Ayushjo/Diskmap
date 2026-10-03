using DiskMap.Core.Native;
using Microsoft.Win32;

namespace DiskMap.Core;

public sealed record AppLeftovers(
    string? AppId,
    string AppName,
    string InstallPath,
    long InstallSize,
    List<string> LeftoverPaths,
    long LeftoverSize);

public sealed record InstalledApp(string Name, string? Publisher, string? InstallLocation, string? RegistryKeyName);

/// <summary>
/// Finds files an app scattered outside its install directory when it was
/// installed/run — caches, preferences, saved state, logs.
///
/// Windows has no API that enumerates "everything this app touched"
/// either. The heuristic mirrors the macOS build: enumerate installed apps
/// from the registry Uninstall hives (HKLM x64 + 32-bit view + HKCU), then
/// search the standard user/system data locations for items whose name
/// contains the app's display name or publisher token. Because it's
/// heuristic, leftovers always land in a *staged* cleanup list for review —
/// never delete automatically.
/// </summary>
public static class AppLeftoverFinder
{
    private const string UninstallPath = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall";

    private static string[] SearchLocations =>
    [
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),      // %APPDATA%
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), // %LOCALAPPDATA%
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),// %PROGRAMDATA%
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Documents"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs"),
    ];

    /// <summary>
    /// Installed apps from the three Uninstall hives: HKLM 64-bit,
    /// HKLM 32-bit (Wow6432Node), HKCU. Same role as scanning
    /// /Applications on macOS.
    /// </summary>
    public static List<InstalledApp> InstalledApplications()
    {
        var apps = new List<InstalledApp>();
        ReadUninstallHive(RegistryHive.LocalMachine, RegistryView.Registry64, apps);
        ReadUninstallHive(RegistryHive.LocalMachine, RegistryView.Registry32, apps);
        ReadUninstallHive(RegistryHive.CurrentUser, RegistryView.Registry64, apps);
        return apps
            .GroupBy(a => a.Name, StringComparer.OrdinalIgnoreCase)
            .Select(g => g.First())
            .OrderBy(a => a.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static void ReadUninstallHive(RegistryHive root, RegistryView view, List<InstalledApp> apps)
    {
        using var baseKey = RegistryKey.OpenBaseKey(root, view);
        using var uninstall = baseKey.OpenSubKey(UninstallPath);
        if (uninstall is null) return;
        foreach (var subName in uninstall.GetSubKeyNames())
        {
            using var sub = uninstall.OpenSubKey(subName);
            if (sub is null) continue;
            var name = sub.GetValue("DisplayName") as string;
            if (string.IsNullOrWhiteSpace(name)) continue;
            // System components and updates aren't user-uninstallable apps.
            if (sub.GetValue("SystemComponent") is int sc && sc == 1) continue;
            apps.Add(new InstalledApp(
                name.Trim(),
                (sub.GetValue("Publisher") as string)?.Trim(),
                (sub.GetValue("InstallLocation") as string)?.Trim(),
                subName));
        }
    }

    public static AppLeftovers FindLeftovers(InstalledApp app)
    {
        var matches = new List<string>();
        // Match tokens: display name and publisher are the closest thing
        // Windows has to a bundle identifier.
        var tokens = new List<string> { app.Name };
        if (!string.IsNullOrWhiteSpace(app.Publisher) && app.Publisher.Length > 3)
            tokens.Add(app.Publisher);

        foreach (var location in SearchLocations)
        {
            if (!Directory.Exists(location)) continue;
            IEnumerable<string> contents;
            try { contents = Directory.EnumerateFileSystemEntries(location); }
            catch { continue; }

            foreach (var item in contents)
            {
                string itemName = Path.GetFileName(item);
                if (tokens.Any(t => t.Length > 3 && itemName.Contains(t, StringComparison.OrdinalIgnoreCase)))
                {
                    // Don't match the app's own install dir or the Recycle Bin.
                    if (item.Contains("$Recycle.Bin", StringComparison.OrdinalIgnoreCase)) continue;
                    matches.Add(item);
                }
            }
        }

        long installSize = !string.IsNullOrWhiteSpace(app.InstallLocation) && Directory.Exists(app.InstallLocation)
            ? AllocatedSize(app.InstallLocation)
            : 0;
        long leftoverSize = matches.Sum(AllocatedSize);

        return new AppLeftovers(
            AppId: app.RegistryKeyName,
            AppName: app.Name,
            InstallPath: app.InstallLocation ?? "",
            InstallSize: installSize,
            LeftoverPaths: matches,
            LeftoverSize: leftoverSize);
    }

    public static long AllocatedSize(string path)
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists && !Directory.Exists(path)) return 0;
            if ((info.Attributes & FileAttributes.Directory) == 0)
                return OnDiskSize(path, info.Length, info.Attributes);

            long total = 0;
            foreach (var entry in Directory.EnumerateFileSystemEntries(path, "*",
                         SearchOption.AllDirectories))
            {
                try
                {
                    var fi = new FileInfo(entry);
                    if ((fi.Attributes & FileAttributes.Directory) != 0) continue;
                    total += OnDiskSize(entry, fi.Length, fi.Attributes);
                }
                catch { /* skip unreadable */ }
            }
            return total;
        }
        catch { return 0; }
    }

    private static long OnDiskSize(string path, long logical, FileAttributes attributes)
    {
        const FileAttributes special = FileAttributes.Compressed | FileAttributes.SparseFile;
        if ((attributes & special) != 0)
        {
            uint low = Win32.GetCompressedFileSizeW(Win32.ExtendedPath(path), out uint high);
            if (low != 0xFFFFFFFF) return ((long)high << 32) | low;
        }
        if (logical == 0) return 0;
        // Round up to a 4K cluster — the common NTFS size; precise per-file
        // clusters would need per-volume queries that don't pay for a
        // heuristic leftover listing.
        return (logical + 4095) / 4096 * 4096;
    }
}
