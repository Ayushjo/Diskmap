using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;

namespace DiskMap.App;

/// <summary>
/// The app's palette — colors are swapped in place by <see cref="Apply"/>
/// and controls reference them via DynamicResource (or
/// <see cref="Ui.Brush"/> for code-built UI). Light values follow the
/// reference design: near-white content, gray sidebar, blue accent,
/// pastel chart tiles.
/// </summary>
public static class Theme
{
    /// <summary>True when the OS is in dark mode — kept for when the app ships its dark theme.</summary>
    public static bool IsDark =>
        (Registry.GetValue(
            @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
            "AppsUseLightTheme", 1) as int?) == 0;

    /// <summary>
    /// WIN-058: dark mode is live — the user's Appearance setting
    /// ("system" follows the OS) decides; an explicit override wins.
    /// </summary>
    public static void Apply() => Apply(AppSettings.Load().WantsDark);

    public static void Apply(bool dark)
    {
        var r = Application.Current.Resources;

        // Surfaces
        Set(r, "AppBackground", dark ? "#FF1C1C1E" : "#FFFFFFFF");
        Set(r, "AppSidebar", dark ? "#FF232325" : "#FFF5F6F7");
        Set(r, "AppCard", dark ? "#FF262628" : "#FFFFFFFF");
        Set(r, "AppCardBorder", dark ? "#FF3A3A3D" : "#FFE7E7EA");
        Set(r, "AppChrome", dark ? "#FF2C2C2E" : "#FFFFFFFF");
        Set(r, "AppField", dark ? "#FF2C2C2E" : "#FFF1F2F4");
        Set(r, "AppHover", dark ? "#FF33353B" : "#FFF0F2F5");

        // Text
        Set(r, "AppForeground", dark ? "#FFF2F2F5" : "#FF1D1D1F");
        Set(r, "AppSubtle", dark ? "#FF9A9AA0" : "#FF6E6E73");
        Set(r, "AppFaint", dark ? "#FF6F6F74" : "#FF9CA3AF");

        // Accent + selection
        Set(r, "AppAccent", dark ? "#FF4C8DFF" : "#FF2563EB");
        Set(r, "AppAccentSoft", dark ? "#FF2B3A55" : "#FFEAF1FE");
        Set(r, "AppNavSelected", dark ? "#FF33353B" : "#FFE8ECF3");
        Set(r, "AppRowSelected", dark ? "#FF2B3A55" : "#FFEFF4FE");

        // Semantic
        Set(r, "AppDanger", dark ? "#FFF87171" : "#FFDC2626");
        Set(r, "AppDangerBg", dark ? "#FF452A2A" : "#FFFDECEC");
        Set(r, "AppSuccess", dark ? "#FF4ADE80" : "#FF16A34A");
        Set(r, "AppSuccessBg", dark ? "#FF243B2C" : "#FFE8F6EE");
        Set(r, "AppWarning", dark ? "#FFFBBF24" : "#FFB45309");
        Set(r, "AppWarningBg", dark ? "#FF3F3620" : "#FFFEF3DE");
        Set(r, "AppInfoBg", dark ? "#FF24324A" : "#FFEEF4FE");
        Set(r, "AppInkButton", dark ? "#FFF2F2F5" : "#FF1D1D1F");
        Set(r, "AppInkButtonFg", dark ? "#FF1D1D1F" : "#FFFFFFFF");
        Set(r, "AppBarTrack", dark ? "#FF333336" : "#FFECECF0");

        // Kept for existing references (pages rewritten to the new names).
        Set(r, "AppPanel", dark ? "#FF232325" : "#FFF5F6F7");
        Set(r, "AppBorder", dark ? "#FF3A3A3D" : "#FFE7E7EA");
    }

    private static void Set(ResourceDictionary r, string key, string hex)
    {
        // Replace, don't mutate: BAML-loaded brushes arrive frozen, and
        // DynamicResource re-reads the dictionary entry on swap anyway.
        r[key] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
    }
}
