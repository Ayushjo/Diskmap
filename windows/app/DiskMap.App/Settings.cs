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
    [JsonPropertyName("textScale")] public double TextScale { get; set; } = 1.0;        // 0.9 / 1.0 / 1.1 / 1.2

    private static string Path0 => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "DiskMap", "settings.json");

    public static AppSettings Load()
    {
        try
        {
            return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(Path0)) ?? new AppSettings();
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
