using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;

namespace DiskMap.App;

/// <summary>
/// Follows the system light/dark setting (HKCU\...\Personalize →
/// AppsUseLightTheme) and swaps the app palette brushes — the WPF
/// equivalent of the macOS build inheriting NSWindow appearance.
/// Palette brushes are DynamicResource so mutating .Color re-themes
/// every control that referenced them.
/// </summary>
public static class Theme
{
    public static bool IsDark =>
        (Registry.GetValue(
            @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
            "AppsUseLightTheme", 1) as int?) == 0;

    public static void Apply()
    {
        var r = Application.Current.Resources;
        bool dark = IsDark;

        Set(r, "AppBackground", dark ? "#FF1E1E1E" : "#FFFFFFFF");
        Set(r, "AppForeground", dark ? "#FFE8E8E8" : "#FF1B1B1B");
        Set(r, "AppPanel", dark ? "#FF252526" : "#FFFAFAFA");
        Set(r, "AppBorder", dark ? "#FF3F3F46" : "#33000000");
        Set(r, "AppSubtle", dark ? "#FF9D9D9D" : "#FF6E6E6E");
        Set(r, "AppChrome", dark ? "#FF2D2D30" : "#FFFCFCFC");
        Set(r, "AppHover", dark ? "#FF3E3E42" : "#FFE5F1FB");
    }

    private static void Set(ResourceDictionary r, string key, string hex)
    {
        // Replace, don't mutate: BAML-loaded brushes arrive frozen, and
        // DynamicResource re-reads the dictionary entry on swap anyway.
        r[key] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
    }
}
