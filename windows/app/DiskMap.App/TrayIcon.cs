using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace DiskMap.App;

/// <summary>
/// WIN-057: the tray presence — the Windows counterpart of the macOS
/// menu-bar extra. Right-click (or click) opens a flyout in the app's own
/// look rather than the stock Win32 menu: drive free space with its bar,
/// the last scan and what changed since, what's waiting in Cleanup, and
/// the app-level commands (they used to live in the window's ☰ menu).
/// Strictly passive — it never scans or cleans on its own.
/// </summary>
public sealed class TrayIcon : IDisposable
{
    private readonly System.Windows.Forms.NotifyIcon _icon;
    private readonly MainWindow _window;
    private Window? _flyout;
    private DateTime _closedAt;

    public TrayIcon(MainWindow window)
    {
        _window = window;
        // The icon comes out of the exe itself (ApplicationIcon embeds
        // app.ico into the PE resources) — no loose file in the output
        // dir, no CWD-dependent path to get wrong.
        var exeIcon = System.Drawing.Icon.ExtractAssociatedIcon(
            Environment.ProcessPath ?? "DiskMap.App.exe") ?? System.Drawing.SystemIcons.Application;
        _icon = new System.Windows.Forms.NotifyIcon
        {
            Icon = exeIcon,
            Text = "freedisk.space",
            Visible = true,
        };
        _icon.MouseUp += (_, e) =>
        {
            if (e.Button is System.Windows.Forms.MouseButtons.Right or System.Windows.Forms.MouseButtons.Left)
                ToggleFlyout();
        };
        _icon.DoubleClick += (_, _) => ShowWindow();
        ScanModel.Shared.StateChanged += (_, _) => UpdateTooltip();
        UpdateTooltip();
    }

    /// <summary>Hover text: free space at a glance, warning under 10%.</summary>
    private void UpdateTooltip()
    {
        if (ScanModel.Shared.Volume is not { } v) return;
        double freeFrac = v.TotalBytes > 0 ? (double)v.FreeBytes / v.TotalBytes : 0;
        string text = $"freedisk.space — {ByteFormat.Format(v.FreeBytes)} free{(freeFrac < 0.10 ? " ⚠" : "")}";
        _icon.Text = text.Length > 63 ? text[..63] : text;   // NotifyIcon's limit
    }

    private void ShowWindow()
    {
        _flyout?.Close();
        _window.Show();
        _window.WindowState = WindowState.Normal;
        _window.Activate();
    }

    private void ToggleFlyout()
    {
        // The click that dismissed the flyout (focus left it) also lands
        // here — don't reopen it in the same breath.
        if (_flyout is not null || (DateTime.Now - _closedAt).TotalMilliseconds < 250)
        {
            _flyout?.Close();
            return;
        }
        _flyout = BuildFlyout();
        _flyout.Closed += (_, _) => { _flyout = null; _closedAt = DateTime.Now; };
        _flyout.Deactivated += (_, _) => _flyout?.Close();
        _flyout.KeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Escape) _flyout?.Close(); };
        _flyout.Opacity = 0;
        _flyout.Show();
        // Position after layout: bottom-right of the work area, above the
        // taskbar (or wherever the work area ends), like system flyouts.
        var area = SystemParameters.WorkArea;
        _flyout.Left = area.Right - _flyout.ActualWidth - 4;
        _flyout.Top = area.Bottom - _flyout.ActualHeight - 4;
        _flyout.Opacity = 1;
        _flyout.Activate();
    }

    private Window BuildFlyout()
    {
        var model = ScanModel.Shared;
        var body = new StackPanel();

        // Brand row.
        var brand = new DockPanel { Margin = new Thickness(0, 0, 0, 14) };
        var mark = Ui.BrandIcon(22);
        mark.Margin = new Thickness(0, 0, 10, 0);
        DockPanel.SetDock(mark, Dock.Left);
        brand.Children.Add(mark);
        var brandText = Ui.T("freedisk.space", 14, FontWeights.SemiBold);
        brandText.VerticalAlignment = VerticalAlignment.Center;
        brand.Children.Add(brandText);
        body.Children.Add(brand);

        // Drive capacity.
        if (model.Volume is { } v)
        {
            double used = v.TotalBytes > 0 ? 1 - (double)v.FreeBytes / v.TotalBytes : 0;
            bool low = used > 0.90;
            body.Children.Add(Ui.MonoLabel(v.DriveLabel.ToUpperInvariant(), Ui.Brush("AppSubtle")));
            var free = new WrapPanel { Margin = new Thickness(0, 4, 0, 6) };
            free.Children.Add(Ui.Mono($"{ByteFormat.Format(v.FreeBytes)} free", 18, FontWeights.SemiBold));
            var of = Ui.Mono($"  of {ByteFormat.Format(v.TotalBytes)}", 11, null, Ui.Brush("AppSubtle"));
            of.VerticalAlignment = VerticalAlignment.Bottom;
            of.Margin = new Thickness(0, 0, 0, 3);
            free.Children.Add(of);
            body.Children.Add(free);
            var bar = Ui.CapacityBar(used, low ? Ui.Brush("AppDanger") : Ui.Brush("AppAccent"), double.NaN);
            bar.Margin = new Thickness(0, 0, 0, 12);
            body.Children.Add(bar);
        }

        // Last scan + what changed.
        string lastLine = model.Tree is null || model.RootPath is not { } root
            ? "No scan yet"
            : $"Last scan · {root.TrimEnd('\\')} · {ByteFormat.Format(model.Totals[0])}";
        var last = Ui.Subtle(lastLine, 12);
        last.TextTrimming = TextTrimming.CharacterEllipsis;
        body.Children.Add(last);
        if (model.HistoryComparison is { } cmp)
        {
            string span = cmp.IsWeek ? "this week" : $"since {cmp.Since:d}";
            string delta = $"{(cmp.FreeDelta >= 0 ? "+" : "−")}{ByteFormat.Format(Math.Abs(cmp.FreeDelta))} free {span}";
            if (cmp.Growers.Count > 0)
                delta += $" · {cmp.Growers[0].Path} grew {ByteFormat.Format(cmp.Growers[0].Delta)}";
            var deltaText = Ui.Faint(delta, 11.5);
            deltaText.TextTrimming = TextTrimming.CharacterEllipsis;
            deltaText.Margin = new Thickness(0, 2, 0, 0);
            body.Children.Add(deltaText);
        }

        // Cleanup waiting.
        int staged = model.StagedItems.Count;
        if (staged > 0)
        {
            body.Children.Add(new Border
            {
                Background = Ui.Brush("AppAccentSoft"), CornerRadius = new CornerRadius(8),
                Padding = new Thickness(10, 8, 10, 8), Margin = new Thickness(0, 12, 0, 0),
                Child = Ui.T($"{staged:N0} item{(staged == 1 ? "" : "s")} waiting in Cleanup", 12, FontWeights.Medium,
                    Ui.Brush("AppAccent")),
            });
        }

        body.Children.Add(new Border { Height = 1, Background = Ui.Brush("AppBorder"), Margin = new Thickness(-4, 14, -4, 8) });

        // Actions.
        void Action(string glyph, string label, string? hint, bool enabled, Action run)
        {
            var row = new DockPanel { Height = 34, Opacity = enabled ? 1 : 0.45 };
            if (hint is not null)
            {
                var h = Ui.Mono(hint, 10.5, null, Ui.Brush("AppFaint"));
                h.VerticalAlignment = VerticalAlignment.Center;
                DockPanel.SetDock(h, Dock.Right);
                row.Children.Add(h);
            }
            var icon = Ui.Glyph(glyph, 15, Ui.Brush("AppSubtle"));
            icon.Margin = new Thickness(0, 0, 12, 0);
            icon.VerticalAlignment = VerticalAlignment.Center;
            DockPanel.SetDock(icon, Dock.Left);
            row.Children.Add(icon);
            var text = Ui.T(label, 13);
            text.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(text);
            var hover = Ui.HoverRow(row, enabled ? () => { _flyout?.Close(); run(); } : null);
            hover.Margin = new Thickness(-8, 0, -8, 0);
            body.Children.Add(hover);
        }
        bool hasScan = model.Tree is not null;
        Action(Icons.Overview, "Open freedisk.space", null, true, ShowWindow);
        Action(Icons.Rescan, "Rescan", "Ctrl+R", hasScan && !model.IsScanning,
            () => { ShowWindow(); _ = model.RescanAsync(); });
        Action(Icons.Folder, "Scan Folder…", "Ctrl+O", !model.IsScanning,
            () => { ShowWindow(); _ = _window.ScanFolder(); });
        Action(Icons.Cleanup, "Review Cleanup", null, staged > 0,
            () => { ShowWindow(); model.ShowPage("Cleanup"); });
        Action(Icons.Snapshots, "Export Scan…", null, hasScan, () => { ShowWindow(); _window.ExportScan(); });
        body.Children.Add(new Border { Height = 1, Background = Ui.Brush("AppBorder"), Margin = new Thickness(-4, 6, -4, 6) });
        Action(Icons.Settings, "Settings…", "Ctrl+,", true, () => { ShowWindow(); _window.OpenSettings(); });
        Action(Icons.Info, "About freedisk.space", null, true, () => { ShowWindow(); _window.OpenAbout(); });
        Action(Icons.Cancel, "Quit", null, true, () => _window.Close());

        var window = Dialogs.CardWindow(body, 300);
        window.Topmost = true;
        return window;
    }

    /// <summary>Harness: renders the flyout to a PNG without showing it at the tray.</summary>
    internal void SaveFlyoutShot(string path)
    {
        var flyout = BuildFlyout();
        MainWindow.SaveWindowShot(flyout, path);
        flyout.Close();
    }

    public void Dispose()
    {
        _flyout?.Close();
        _icon.Dispose();
    }
}
