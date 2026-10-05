using System.IO;
using System.Windows;

namespace DiskMap.App;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        // WIN-058: the user's Appearance choice decides the Fluent theme
        // and our palette together.
        var settings = AppSettings.Load();
#pragma warning disable WPF0001 // ThemeMode is experimental but stable in practice on .NET 10
        ThemeMode = settings.WantsDark ? ThemeMode.Dark : ThemeMode.Light;
#pragma warning restore WPF0001
        Theme.Apply(settings.WantsDark); // our own palette brushes on top of Fluent
        SystemParameters.StaticPropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(SystemParameters.HighContrast))
            {
                Theme.Apply(AppSettings.Load().WantsDark);
                (Current.MainWindow as MainWindow)?.RebuildForTheme();
            }
        };
        // A failing click reports instead of taking the app (and the scan) down.
        DispatcherUnhandledException += (_, args) =>
        {
            MessageBox.Show(args.Exception.Message, "freedisk.space", MessageBoxButton.OK, MessageBoxImage.Warning);
            args.Handled = true;
        };
        base.OnStartup(e);
        // WIN-055: `diskmap C:\some\folder` launches straight into a scan.
        StartupPath = e.Args is [{ } arg, ..] && Directory.Exists(arg)
            ? Path.GetFullPath(arg) : null;
    }

    /// <summary>argv[0] when it's a real directory — scanned on load.</summary>
    public static string? StartupPath { get; private set; }
}

