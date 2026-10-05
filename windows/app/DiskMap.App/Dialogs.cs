using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Effects;
using DiskMap.Core;

namespace DiskMap.App;

/// <summary>
/// The app's own popup chrome — a borderless, rounded card with a soft
/// shadow in the theme's colors — instead of the stock Win32 message box
/// and menu. Shared by the risky-item warning and the tray flyout.
/// </summary>
public static class Dialogs
{
    /// <summary>A borderless themed window whose content sits on a rounded card.</summary>
    public static Window CardWindow(UIElement content, double width)
    {
        var card = new Border
        {
            Background = Ui.Brush("AppCard"),
            BorderBrush = Ui.Brush("AppCardBorder"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(18),
            Margin = new Thickness(16),   // room for the shadow
            Child = content,
            Effect = new DropShadowEffect
            {
                BlurRadius = 24, ShadowDepth = 4, Opacity = 0.22, Direction = 270, Color = Colors.Black,
            },
        };
        return new Window
        {
            WindowStyle = WindowStyle.None,
            AllowsTransparency = true,
            Background = Brushes.Transparent,
            ResizeMode = ResizeMode.NoResize,
            ShowInTaskbar = false,
            SizeToContent = SizeToContent.Height,
            Width = width + 32,
            Content = card,
            FontFamily = Application.Current.MainWindow?.FontFamily ?? new FontFamily("Segoe UI"),
            Foreground = Ui.Brush("AppForeground"),
        };
    }

    /// <summary>One row of a confirmation: what will be touched, where it is, how big.</summary>
    public sealed record ConfirmItem(string Name, string Path, long Bytes);

    /// <summary>
    /// The confirmation for anything that changes the disk or the Cleanup
    /// list in bulk: says what will happen, lists every affected item by
    /// full path (scrollable), totals it, and defaults to Cancel. True = go.
    /// </summary>
    public static bool Confirm(Window? owner, string title, string message,
        IReadOnlyList<ConfirmItem> items, string confirmLabel, bool danger = false, string? footnote = null)
    {
        var body = new StackPanel();
        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };
        var tile = Ui.IconTile(danger ? Icons.Warning : Icons.Cleanup, 36,
            danger ? Ui.Brush("AppDangerBg") : Ui.Brush("AppAccentSoft"),
            danger ? Ui.Brush("AppDanger") : Ui.Brush("AppAccent"), 9);
        tile.Margin = new Thickness(0, 0, 12, 0);
        DockPanel.SetDock(tile, Dock.Left);
        head.Children.Add(tile);
        var titleText = Ui.T(title, 15, FontWeights.SemiBold);
        titleText.TextWrapping = TextWrapping.Wrap;
        titleText.VerticalAlignment = VerticalAlignment.Center;
        head.Children.Add(titleText);
        body.Children.Add(head);
        var msg = Ui.T(message, 12.5);
        msg.TextWrapping = TextWrapping.Wrap;
        msg.Margin = new Thickness(0, 0, 0, 10);
        body.Children.Add(msg);

        // Every affected item, full path — "from which folder" is never a guess.
        var list = new StackPanel();
        foreach (var item in items.OrderByDescending(i => i.Bytes).Take(400))
        {
            var row = new DockPanel { Margin = new Thickness(0, 3, 0, 3) };
            var size = Ui.Mono(ByteFormat.Format(item.Bytes), 11.5, FontWeights.Medium);
            size.Margin = new Thickness(12, 0, 0, 0);
            DockPanel.SetDock(size, Dock.Right);
            row.Children.Add(size);
            var names = new StackPanel();
            var name = Ui.T(item.Name, 12, FontWeights.Medium);
            name.TextTrimming = TextTrimming.CharacterEllipsis;
            names.Children.Add(name);
            var path = Ui.Faint(item.Path, 11);
            path.TextTrimming = TextTrimming.CharacterEllipsis;
            path.ToolTip = item.Path;
            names.Children.Add(path);
            row.Children.Add(names);
            list.Children.Add(row);
        }
        if (items.Count > 400) list.Children.Add(Ui.Faint($"… and {items.Count - 400:N0} more"));
        body.Children.Add(new Border
        {
            Background = Ui.Brush("AppHover"), CornerRadius = new CornerRadius(8),
            Padding = new Thickness(12, 8, 12, 8), Margin = new Thickness(0, 0, 0, 10),
            Child = new ScrollViewer { MaxHeight = 260, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = list },
        });
        var total = Ui.Mono($"{items.Count:N0} item{(items.Count == 1 ? "" : "s")} · {ByteFormat.Format(items.Sum(i => i.Bytes))}",
            12, FontWeights.SemiBold);
        total.Margin = new Thickness(0, 0, 0, footnote is null ? 14 : 4);
        body.Children.Add(total);
        if (footnote is not null)
        {
            var note = Ui.Faint(footnote, 11.5);
            note.TextWrapping = TextWrapping.Wrap;
            note.Margin = new Thickness(0, 0, 0, 14);
            body.Children.Add(note);
        }

        bool result = false;
        Window? window = null;
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var cancel = Ui.Button("Cancel", null, Ui.ButtonStyle.Outline, () => window!.Close());
        cancel.IsCancel = true;
        cancel.Margin = new Thickness(0, 0, 8, 0);
        var go = Ui.Button(confirmLabel, danger ? Icons.Trash : Icons.Cleanup,
            danger ? Ui.ButtonStyle.Danger : Ui.ButtonStyle.Primary, () => { result = true; window!.Close(); });
        buttons.Children.Add(cancel);
        buttons.Children.Add(go);
        body.Children.Add(buttons);

        window = CardWindow(body, 520);
        window.Owner = owner;
        window.WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner;
        window.Loaded += (_, _) => cancel.Focus();   // the safe choice has focus
        window.ShowDialog();
        return result;
    }

    /// <summary>
    /// "ext4.vhdx is a whole Linux distribution (WSL)…" — what the item
    /// is, what recycling it breaks, the right way to reclaim the space,
    /// and Cancel as the default. True = add it anyway.
    /// </summary>
    public static bool ConfirmRisky(Window? owner, string name, StorageVerdict verdict)
    {
        bool result = false;
        var window = RiskyWindow(owner, name, verdict, anyway => result = anyway);
        window.ShowDialog();
        return result;
    }

    /// <summary>The warning window itself; <paramref name="done"/> gets true for "Add anyway".</summary>
    public static Window RiskyWindow(Window? owner, string name, StorageVerdict verdict, Action<bool> done)
    {
        var body = new StackPanel();
        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 12) };
        var tile = Ui.IconTile(Icons.Warning, 36, Ui.Brush("AppWarningBg"), Ui.Brush("AppWarning"), 9);
        tile.Margin = new Thickness(0, 0, 12, 0);
        DockPanel.SetDock(tile, Dock.Left);
        head.Children.Add(tile);
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var title = Ui.T($"Add {name} to Cleanup?", 15, FontWeights.SemiBold);
        title.TextTrimming = TextTrimming.CharacterEllipsis;
        titles.Children.Add(title);
        titles.Children.Add(Ui.MonoLabel(verdict.Class.Title.ToUpperInvariant(), Ui.Brush("AppWarning")));
        head.Children.Add(titles);
        body.Children.Add(head);

        if (verdict.Note is { } note)
        {
            var noteText = Ui.T(note, 12.5);
            noteText.TextWrapping = TextWrapping.Wrap;
            noteText.Margin = new Thickness(0, 0, 0, 10);
            body.Children.Add(noteText);
        }
        if (verdict.Instead is { } instead)
        {
            var box = new StackPanel();
            box.Children.Add(Ui.MonoLabel("INSTEAD", Ui.Brush("AppSubtle")));
            var insteadText = Ui.T(instead, 12, null, Ui.Brush("AppForeground"));
            insteadText.TextWrapping = TextWrapping.Wrap;
            insteadText.Margin = new Thickness(0, 4, 0, 0);
            box.Children.Add(insteadText);
            body.Children.Add(new Border
            {
                Background = Ui.Brush("AppHover"), CornerRadius = new CornerRadius(8),
                Padding = new Thickness(12, 10, 12, 10), Margin = new Thickness(0, 0, 0, 14), Child = box,
            });
        }

        Window? window = null;
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var cancel = Ui.Button("Cancel", null, Ui.ButtonStyle.Primary, () => window!.Close());
        cancel.IsDefault = true;
        cancel.IsCancel = true;
        var anyway = Ui.Button("Add anyway", null, Ui.ButtonStyle.Danger, () => { done(true); window!.Close(); });
        anyway.Margin = new Thickness(0, 0, 8, 0);
        buttons.Children.Add(anyway);
        buttons.Children.Add(cancel);
        body.Children.Add(buttons);

        window = CardWindow(body, 440);
        window.Owner = owner;
        window.WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner;
        window.Loaded += (_, _) => cancel.Focus();
        return window;
    }
}
