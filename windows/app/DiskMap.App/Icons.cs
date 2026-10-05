using DiskMap.Core;

namespace DiskMap.App;

/// <summary>
/// WPF-native SVG icon identifiers generated from react-icons 5.5.0.
/// General UI uses Bootstrap Icons; developer ecosystems use Simple Icons.
/// </summary>
public static class Icons
{
    // Chrome
    public const string Search = "BsSearch";
    public const string Rescan = "BsArrowClockwise";
    public const string Trash = "BsTrash3";
    public const string Back = "BsArrowLeft";
    public const string Forward = "BsArrowRight";
    public const string Settings = "BsGear";
    public const string Add = "BsPlus";
    public const string More = "BsThreeDots";
    public const string Info = "BsInfoCircle";
    public const string Warning = "BsExclamationTriangle";
    public const string Cancel = "BsX";
    public const string Check = "BsCheckCircle";
    public const string Shield = "BsShieldCheck";
    public const string Focus = "BsCrosshair";
    public const string Copy = "BsCopy";
    public const string Open = "BsBoxArrowUpRight";
    public const string Link = "BsLink45Deg";
    public const string Drive = "BsDeviceHdd";
    public const string ChevronDown = "BsChevronDown";
    public const string Grid = "BsGrid";
    public const string DarkMode = "BsMoon";
    public const string LightMode = "BsSun";
    public const string Visibility = "BsEye";

    // Sidebar destinations
    public const string Overview = "BsGrid";
    public const string BiggestFiles = "BsFileEarmark";
    public const string BiggestFolders = "BsFolder";
    public const string Forgotten = "BsClockHistory";
    public const string Duplicates = "BsCopy";
    public const string SafeReview = "BsCheckCircle";
    public const string Caches = "BsArrowRepeat";
    public const string Downloads = "BsDownload";
    public const string Media = "BsFilm";
    public const string FileBrowser = "BsFolder2Open";
    public const string Visualize = "BsGrid3X3Gap";
    public const string Developer = "BsCodeSlash";
    public const string Applications = "BsApp";
    public const string Snapshots = "BsCamera";
    public const string Cleanup = "BsTrash3";

    // File kinds and chart modes
    public const string Folder = "BsFolder";
    public const string File = "BsFileEarmark";
    public const string Video = "BsFilm";
    public const string Audio = "BsFileMusic";
    public const string Image = "BsFileImage";
    public const string Document = "BsFileEarmark";
    public const string Code = "BsCodeSlash";
    public const string Archive = "BsFileZip";
    public const string DiskImage = "BsDeviceHdd";
    public const string Application = "BsApp";
    public const string List = "BsList";
    public const string PieChart = "BsPieChart";
    public const string BarChart = "BsBarChart";
    public const string Bubble = "BsCircle";
    public const string Diagram = "BsDiagram3";

    // Developer ecosystems (Simple Icons via react-icons/si)
    public const string NextJs = "SiNextdotjs";
    public const string NodeJs = "SiNodedotjs";
    public const string Python = "SiPython";
    public const string Docker = "SiDocker";
    public const string Rust = "SiRust";
    public const string Flutter = "SiFlutter";
    public const string Android = "SiAndroid";
    public const string Dotnet = "SiDotnet";
    public const string Gradle = "SiGradle";
    public const string Maven = "SiApachemaven";
    public const string JetBrains = "SiJetbrains";
    public const string OpenAi = "SiOpenai";

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

    public static string ForDeveloperItem(DeveloperItem item)
    {
        string path = item.AbsolutePath;
        if (path.Contains("\\.next", StringComparison.OrdinalIgnoreCase)
            || item.DisplayName.Equals(".next", StringComparison.OrdinalIgnoreCase))
            return NextJs;
        return ForEcosystem(item.Ecosystem, path);
    }

    public static string ForEcosystem(DeveloperEcosystem ecosystem, string? path = null) => ecosystem switch
    {
        DeveloperEcosystem.Node => NodeJs,
        DeveloperEcosystem.Docker => Docker,
        DeveloperEcosystem.Dotnet => Dotnet,
        DeveloperEcosystem.Python => Python,
        DeveloperEcosystem.Android => Android,
        DeveloperEcosystem.Rust => Rust,
        DeveloperEcosystem.Flutter => Flutter,
        DeveloperEcosystem.Jvm when path?.Contains("maven", StringComparison.OrdinalIgnoreCase) == true => Maven,
        DeveloperEcosystem.Jvm => Gradle,
        DeveloperEcosystem.IdeAi when path?.Contains(".idea", StringComparison.OrdinalIgnoreCase) == true => JetBrains,
        DeveloperEcosystem.IdeAi => OpenAi,
        _ => Code,
    };
}
