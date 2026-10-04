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

    /// <summary>
    /// The Calm palette (docs/DESIGN.md §3.1/§22): one canvas, one raised
    /// step, hairlines, ink text, a single violet accent. Safety colours
    /// are dot+word colours — never fills. Soft values are the spec's
    /// alpha mixes composited over the canvas.
    /// </summary>
    public static void Apply(bool dark)
    {
        var r = Application.Current.Resources;

        // Surfaces — one canvas everywhere; raised is for floats only.
        Set(r, "AppBackground", dark ? "#FF0B0B0C" : "#FFF8F7F4");
        Set(r, "AppSidebar", dark ? "#FF0B0B0C" : "#FFF8F7F4");
        Set(r, "AppCard", dark ? "#FF141416" : "#FFFFFFFF");
        Set(r, "AppCardBorder", dark ? "#FF26262A" : "#FFE4E3DF");
        Set(r, "AppChrome", dark ? "#FF0B0B0C" : "#FFF8F7F4");
        Set(r, "AppField", dark ? "#FF101012" : "#FFFCFBFA");   // raised @ 55%
        Set(r, "AppHover", dark ? "#FF161617" : "#FFEEEDEB");   // ink/white @ 4.5%

        // Text — ink, ink2, ink3.
        Set(r, "AppForeground", dark ? "#FFF2F2F3" : "#FF252B31");
        Set(r, "AppSubtle", dark ? "#FFA3A3A8" : "#FF66717E");
        Set(r, "AppFaint", dark ? "#FF76767C" : "#FF949AA2");

        // Accent + selection — one violet.
        Set(r, "AppAccent", dark ? "#FF9A8BF0" : "#FF7966DA");
        Set(r, "AppAccentSoft", dark ? "#FF1B1925" : "#FFEAE7F1");   // accent @ 11%
        Set(r, "AppNavSelected", dark ? "#FF1B1925" : "#FFEAE7F1");
        Set(r, "AppRowSelected", dark ? "#FF1B1925" : "#FFEAE7F1");

        // Safety — dot+word colours; Bg keys stay as muted tints for
        // the pages that still badge.
        Set(r, "AppDanger", dark ? "#FFEE7A70" : "#FFC2453D");
        Set(r, "AppDangerBg", dark ? "#FF241717" : "#FFF2E3E0");
        Set(r, "AppSuccess", dark ? "#FF6CC495" : "#FF3E8E63");
        Set(r, "AppSuccessBg", dark ? "#FF151F1B" : "#FFE4EBE4");
        Set(r, "AppWarning", dark ? "#FFE0A548" : "#FFB7791F");
        Set(r, "AppWarningBg", dark ? "#FF221C13" : "#FFF1E9DD");
        Set(r, "AppInfoBg", dark ? "#FF1B1925" : "#FFEAE7F1");
        Set(r, "AppInkButton", dark ? "#FFF2F2F3" : "#FF252B31");
        Set(r, "AppInkButtonFg", dark ? "#FF0B0B0C" : "#FFFFFFFF");
        Set(r, "AppBarTrack", dark ? "#FF26262A" : "#FFE4E3DF");

        // Kept for existing references (pages rewritten to the new names).
        Set(r, "AppPanel", dark ? "#FF0B0B0C" : "#FFF8F7F4");
        Set(r, "AppBorder", dark ? "#FF26262A" : "#FFE4E3DF");
    }

    private static void Set(ResourceDictionary r, string key, string hex)
    {
        // Replace, don't mutate: BAML-loaded brushes arrive frozen, and
        // DynamicResource re-reads the dictionary entry on swap anyway.
        r[key] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
    }
}
