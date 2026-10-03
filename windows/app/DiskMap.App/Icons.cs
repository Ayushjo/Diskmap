namespace DiskMap.App;

/// <summary>
/// Icon glyphs — Segoe MDL2 Assets codepoints (available on every
/// supported Windows). All icon text flows through here so a wrong
/// glyph is a one-line fix.
/// </summary>
public static class Icons
{
    public const string Font = "Segoe MDL2 Assets";

    // Chrome
    public const string Search = "\uE721";
    public const string Rescan = "\uE72C";
    public const string Trash = "\uE74D";
    public const string Back = "\uE76B";
    public const string Forward = "\uE76C";
    public const string Settings = "\uE713";
    public const string Add = "\uE710";
    public const string More = "\uE712";
    public const string Info = "\uE946";
    public const string Check = "\uE8FB";
    public const string Shield = "\uEA18";
    public const string Focus = "\uE740";
    public const string Copy = "\uE8C8";
    public const string Open = "\uE8DA";
    public const string Link = "\uE71B";
    public const string Drive = "\uEDA2";
    public const string ChevronDown = "\uE70D";
    public const string Grid = "\uE80A";

    // Sidebar destinations
    public const string Overview = "\uE80F";
    public const string BiggestFiles = "\uE8A5";
    public const string BiggestFolders = "\uE8B7";
    public const string Forgotten = "\uE81C";
    public const string Duplicates = "\uE8C8";
    public const string SafeReview = "\uE8FB";
    public const string Caches = "\uE7B8";
    public const string Downloads = "\uE896";
    public const string Media = "\uE714";
    public const string FileBrowser = "\uE8F1";
    public const string Visualize = "\uE71D";
    public const string Developer = "\uE943";
    public const string Applications = "\uED35";
    public const string Snapshots = "\uE722";
    public const string Cleanup = "\uE74D";

    // File kinds
    public const string Folder = "\uE8B7";
    public const string File = "\uE8A5";
    public const string Video = "\uE714";
    public const string Audio = "\uE8D6";
    public const string Image = "\uE91B";
    public const string Document = "\uE8A5";
    public const string Code = "\uE943";
    public const string Archive = "\uE7B8";
    public const string DiskImage = "\uEDA2";
    public const string Application = "\uED35";
    public const string List = "\uEA37";

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
