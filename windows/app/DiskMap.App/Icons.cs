using System.Windows.Media;

namespace DiskMap.App;

/// <summary>
/// Google Material Symbols Rounded glyphs, subset and bundled for
/// offline use. All icon text flows through here.
/// </summary>
public static class Icons
{
    public static readonly FontFamily FontFamily = new(
        new Uri("pack://application:,,,/"), "./Assets/Fonts/#Material Symbols Rounded");

    // Chrome
    public const string Search = "\uEF7A";
    public const string Rescan = "\uE5D5";
    public const string Trash = "\uE92E";
    public const string Back = "\uE5C4";
    public const string Forward = "\uE5C8";
    public const string Settings = "\uE8B8";
    public const string Add = "\uE145";
    public const string More = "\uE5D3";
    public const string Info = "\uE88E";
    public const string Warning = "\uF083";
    public const string Cancel = "\uE5CD";
    public const string Check = "\uF0BE";
    public const string Shield = "\uE9E0";
    public const string Focus = "\uE3B4";
    public const string Copy = "\uE14D";
    public const string Open = "\uE89E";
    public const string Link = "\uE250";
    public const string Drive = "\uF80E";
    public const string ChevronDown = "\uE5CF";
    public const string Grid = "\uE9B0";
    public const string DarkMode = "\uE51C";
    public const string LightMode = "\uE518";
    public const string Visibility = "\uE8F4";

    // Sidebar destinations
    public const string Overview = "\uE871";
    public const string BiggestFiles = "\uE873";
    public const string BiggestFolders = "\uE2C7";
    public const string Forgotten = "\uE8B3";
    public const string Duplicates = "\uE14D";
    public const string SafeReview = "\uF0BE";
    public const string Caches = "\uE86A";
    public const string Downloads = "\uF090";
    public const string Media = "\uE404";
    public const string FileBrowser = "\uE2C8";
    public const string Visualize = "\uE9B0";
    public const string Developer = "\uE86F";
    public const string Applications = "\uE5C3";
    public const string Snapshots = "\uE412";
    public const string Cleanup = "\uE92E";

    // File kinds
    public const string Folder = "\uE2C7";
    public const string File = "\uE873";
    public const string Video = "\uE404";
    public const string Audio = "\uEB82";
    public const string Image = "\uE3F4";
    public const string Document = "\uE873";
    public const string Code = "\uE86F";
    public const string Archive = "\uE149";
    public const string DiskImage = "\uF80E";
    public const string Application = "\uE5C3";
    public const string List = "\uE5D2";

    /// <summary>Glyph for a FileTypes category id.</summary>
    public static string ForKind(string kindId) => kindId switch
    {
        "video" => Video,
        "audio" => Audio,
        "image" => Image,
        "document" => Document,
        "developer" => Code,
        "archive" => Archive,
        "diskImage" => DiskImage,
        "application" => Application,
        "folder" => Folder,
        _ => File,
    };
}
