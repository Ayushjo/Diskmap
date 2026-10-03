using System.Windows;

namespace DiskMap.App;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        // Fluent theme (.NET 9+): modern rounded controls. The reference
        // design is light, so the app stays light for now — the dark
        // palette path remains in Theme.Apply for when dark mode lands
        // properly (tracked in PARITY).
#pragma warning disable WPF0001 // ThemeMode is experimental but stable in practice on .NET 10
        ThemeMode = ThemeMode.Light;
#pragma warning restore WPF0001
        Theme.Apply(); // our own palette brushes on top of Fluent
        // A failing click reports instead of taking the app (and the scan) down.
        DispatcherUnhandledException += (_, args) =>
        {
            MessageBox.Show(args.Exception.Message, "DiskMap", MessageBoxButton.OK, MessageBoxImage.Warning);
            args.Handled = true;
        };
        base.OnStartup(e);
    }
}

