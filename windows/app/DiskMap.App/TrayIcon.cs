using System.Windows;

namespace DiskMap.App;

/// <summary>
/// WIN-057: the tray presence — the Windows counterpart of the macOS
/// menu-bar extra. Strictly passive: free space (warning under 10%),
/// last scan line, rescan, open, exit. One instance per window.
/// </summary>
public sealed class TrayIcon : IDisposable
{
    private readonly System.Windows.Forms.NotifyIcon _icon;
    private readonly Window _window;

    public TrayIcon(Window window)
    {
        _window = window;
        var menu = new System.Windows.Forms.ContextMenuStrip();
        menu.Items.Add(new System.Windows.Forms.ToolStripLabel("DiskMap") { Enabled = false });
        menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
        var free = new System.Windows.Forms.ToolStripMenuItem("Free space: —") { Enabled = false };
        var last = new System.Windows.Forms.ToolStripMenuItem("No scan yet") { Enabled = false };
        var rescan = new System.Windows.Forms.ToolStripMenuItem("Rescan");
        rescan.Click += async (_, _) => { await ScanModel.Shared.RescanAsync(); Refresh(); };
        var open = new System.Windows.Forms.ToolStripMenuItem("Open DiskMap");
        open.Click += (_, _) => Show();
        var exit = new System.Windows.Forms.ToolStripMenuItem("Quit");
        exit.Click += (_, _) => _window.Close();
        menu.Items.AddRange([free, last, rescan, open, new System.Windows.Forms.ToolStripSeparator(), exit]);

        // The icon comes out of the exe itself (ApplicationIcon embeds
        // app.ico into the PE resources) — no loose file in the output
        // dir, no CWD-dependent path to get wrong.
        var exeIcon = System.Drawing.Icon.ExtractAssociatedIcon(
            Environment.ProcessPath ?? "DiskMap.App.exe") ?? System.Drawing.SystemIcons.Application;
        _icon = new System.Windows.Forms.NotifyIcon
        {
            Icon = exeIcon,
            Text = "DiskMap",
            Visible = true,
            ContextMenuStrip = menu,
        };
        _icon.DoubleClick += (_, _) => Show();
        ScanModel.Shared.StateChanged += (_, _) => Refresh();
        Refresh();
    }

    private void Show()
    {
        _window.Show();
        _window.WindowState = WindowState.Normal;
        _window.Activate();
    }

    /// <summary>Repaint the passive lines: free space + last scan.</summary>
    private void Refresh()
    {
        var menu = _icon.ContextMenuStrip;
        if (menu is null) return;
        var model = ScanModel.Shared;
        var freeItem = (System.Windows.Forms.ToolStripMenuItem)menu.Items[2];
        var lastItem = (System.Windows.Forms.ToolStripMenuItem)menu.Items[3];
        var rescan = (System.Windows.Forms.ToolStripMenuItem)menu.Items[4];
        if (model.Volume is { } v)
        {
            double freeFrac = v.TotalBytes > 0 ? (double)v.FreeBytes / v.TotalBytes : 0;
            string warn = freeFrac < 0.10 ? "  ⚠ low" : "";
            freeItem.Text = $"Free space: {ByteFormat.Format(v.FreeBytes)}{warn}";
        }
        lastItem.Text = model.Tree is null || model.RootPath is not { } root
            ? "No scan yet"
            : $"Last scan: {root.TrimEnd('\\')} · {ByteFormat.Format(model.Totals[0])}";
        rescan.Enabled = model.Tree is not null && !model.IsScanning;
    }

    public void Dispose() => _icon.Dispose();
}
