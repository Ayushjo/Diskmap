using System.Windows.Controls;
using DiskMap.App.Controls;

namespace DiskMap.App.Pages;

/// <summary>
/// Chart pages are just the control filling the page — the breadcrumb
/// and size toggle live in the main window header, same as the macOS
/// app's shared chrome.
/// </summary>
public sealed class TreemapPage : UserControl
{
    public TreemapPage() { Content = new TreemapControl(); }
}

public sealed class SunburstPage : UserControl
{
    public SunburstPage() { Content = new SunburstControl(); }
}

public sealed class FlamePage : UserControl
{
    public FlamePage() { Content = new ScrollViewer { Content = new FlameControl { MinHeight = 400 } }; }
}

public sealed class BubblesPage : UserControl
{
    public BubblesPage() { Content = new BubblesControl(); }
}

public sealed class MindMapPage : UserControl
{
    public MindMapPage() { Content = new ScrollViewer { Content = new MindMapControl { MinHeight = 500 } }; }
}
