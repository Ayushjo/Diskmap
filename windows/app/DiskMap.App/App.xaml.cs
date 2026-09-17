using System.Windows;

namespace DiskMap.App;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        // Fluent theme (.NET 9+): modern rounded controls + real dark mode
        // that follows the OS setting — the closest thing to the macOS
        // build inheriting NSWindow appearance.
#pragma warning disable WPF0001 // ThemeMode is experimental but stable in practice on .NET 10
        ThemeMode = ThemeMode.System;
#pragma warning restore WPF0001
        Theme.Apply(); // our own palette brushes on top of Fluent
        base.OnStartup(e);
    }
}

