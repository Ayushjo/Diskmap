using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace DiskMap.App;

/// <summary>
/// User settings (WIN-058/059/060): appearance + text scale, persisted
/// to %LOCALAPPDATA%\DiskMap\settings.json. Deliberately tiny — anything
/// bigger graduates to a real settings surface.
/// </summary>
public sealed class AppSettings
{
    [JsonPropertyName("appearance")] public string Appearance { get; set; } = "system"; // system|light|dark
    [JsonPropertyName("textScale")] public double TextScale { get; set; } = 1.0;        // 0.9 / 1.0 / 1.15 / 1.3
    /// <summary>Record a history entry after each scan (the "what grew" comparisons).</summary>
    [JsonPropertyName("keepHistory")] public bool KeepHistory { get; set; } = true;
    /// <summary>WIN-066: after each scan on a ReFS volume, map extents and count block clones once.</summary>
    [JsonPropertyName("cloneAccounting")] public bool CloneAccounting { get; set; }

    private static string Path0 => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "DiskMap", "settings.json");

    public static AppSettings Load()
    {
        try
        {
            var settings = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(Path0)) ?? new AppSettings();
            if (Math.Abs(settings.TextScale - 1.1) < 0.001) settings.TextScale = 1.15;
            if (Math.Abs(settings.TextScale - 1.2) < 0.001) settings.TextScale = 1.3;
            return settings;
        }
        catch { return new AppSettings(); }
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path0)!);
            File.WriteAllText(Path0, JsonSerializer.Serialize(this));
        }
        catch { }
    }

    /// <summary>Resolved dark flag for the palette — "system" follows the OS.</summary>
    public bool WantsDark => Appearance switch
    {
        "dark" => true,
        "light" => false,
        _ => Theme.IsDark,
    };
}
