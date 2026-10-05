using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using DiskMap.Core;

namespace DiskMap.App;

/// <summary>
/// Design-system factories for the code-built UI (the app composes its
/// views in C#, not XAML templates). Every visual primitive the
/// reference design uses — cards, pills, badges, icon tiles, table
/// chrome, the stacked segment bar — is made here so the pages stay
/// consistent.
/// </summary>
public static class Ui
{
    private static readonly Dictionary<string, Brush> _brushes = new(StringComparer.Ordinal);
    public static double TextScale { get; set; } = 1;
    public static double Scaled(double value) => value * TextScale;
    public const double PageSide = 28;
    public const double PageTop = 28;
    public const double ZoneGap = 18;
    public const double GroupGap = 16;
    public const double InlineGap = 8;
    public const double RowHeight = 36;
    public const double TwoLineRowHeight = 44;

    public static Border Gap(double height) => new() { Height = height };

    public static Brush Brush(string resourceKey) =>
        (Brush)Application.Current.Resources[resourceKey];

    public static Brush Hex(string hex)
    {
        if (_brushes.TryGetValue(hex, out var cached)) return cached;
        var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
        brush.Freeze();
        return _brushes[hex] = brush;
    }

    // ---- Text ----

    public static TextBlock T(string text, double size = 12, FontWeight? weight = null,
        Brush? fg = null, bool wrap = false)
    {
        return new TextBlock
        {
            Text = text,
            FontSize = Scaled(size),
            FontWeight = weight ?? FontWeights.Normal,
            Foreground = fg ?? Brush("AppForeground"),
            TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
            TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
    }

    /// <summary>20 px semibold page title.</summary>
    public static TextBlock PageTitle(string text) =>
        T(text, 20, FontWeights.SemiBold);

    /// <summary>12 px gray line under the page title.</summary>
    public static TextBlock PageSubtitle(string text) =>
        new() { Text = text, FontSize = Scaled(12), Foreground = Brush("AppSubtle"), TextWrapping = TextWrapping.Wrap };

    /// <summary>Small uppercase-ish gray section label ("FIND", "Safety").</summary>
    public static TextBlock SectionLabel(string text) => MonoLabel(text);

    public static TextBlock Subtle(string text, double size = 12) =>
        T(text, size, null, Brush("AppSubtle"));

    public static TextBlock Faint(string text, double size = 11) =>
        T(text, size, null, Brush("AppFaint"));

    public static FrameworkElement Glyph(string icon, double size = 13, Brush? fg = null)
    {
        var color = fg ?? Brush("AppForeground");
        if (!ReactIconData.TryGet(icon, out var definition))
            return T("?", size, FontWeights.Medium, color);
        var canvas = new Canvas { Width = definition.Width, Height = definition.Height };
        foreach (var geometry in definition.Geometries)
            canvas.Children.Add(new System.Windows.Shapes.Path { Data = geometry, Fill = color });
        return new Viewbox
        {
            Width = Scaled(size), Height = Scaled(size),
            Stretch = Stretch.Uniform,
            VerticalAlignment = VerticalAlignment.Center,
            Child = canvas,
            Tag = icon,
        };
    }

    public static void SetIconBrush(FrameworkElement icon, Brush brush)
    {
        if (icon is Viewbox { Child: Canvas canvas })
            foreach (var path in canvas.Children.OfType<System.Windows.Shapes.Path>()) path.Fill = brush;
        else if (icon is TextBlock text)
            text.Foreground = brush;
    }

    // ---- Surfaces ----

    /// <summary>White card: 1 px border, 10 px radius, padding.</summary>
    public static Border Card(UIElement child, double padding = 16, Thickness? margin = null)
    {
        return new Border
        {
            Background = Brush("AppCard"),
            BorderBrush = Brush("AppCardBorder"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(padding),
            Margin = margin ?? new Thickness(0, 0, 0, 12),
            Child = child,
        };
    }

    /// <summary>Rounded square holding a glyph — the mockup's item icons.</summary>
    public static Border IconTile(string icon, double size = 36, Brush? bg = null,
        Brush? fg = null, double radius = 8)
    {
        var glyph = Glyph(icon, size * 0.56, fg ?? Brush("AppAccent"));
        glyph.HorizontalAlignment = HorizontalAlignment.Center;
        return new Border
        {
            Width = size, Height = size,
            Background = bg ?? Brush("AppAccentSoft"),
            CornerRadius = new CornerRadius(radius),
            Child = glyph,
        };
    }

    private static ImageSource? _brandIconSource;

    public static FrameworkElement BrandIcon(double size)
    {
        try
        {
            _brandIconSource ??= BitmapDecoder.Create(
                    new Uri("pack://application:,,,/app.ico", UriKind.Absolute),
                    BitmapCreateOptions.PreservePixelFormat,
                    BitmapCacheOption.OnLoad)
                .Frames.OrderByDescending(frame => frame.PixelWidth).First();
            return new Image
            {
                Source = _brandIconSource,
                Width = size, Height = size,
                Stretch = Stretch.Uniform,
                SnapsToDevicePixels = true,
            };
        }
        catch
        {
            return BrandMark(size);
        }
    }

    public static FrameworkElement BrandMark(double height)
    {
        double width = height * 260 / 273;
        var mark = new Canvas { Width = width, Height = height };
        var bar = new Border
        {
            Width = width * 69 / 260, Height = height,
            CornerRadius = new CornerRadius(height * 8 / 273),
            Background = Brush("AppForeground"),
        };
        var top = new Border
        {
            Width = width * 173 / 260, Height = height * 129 / 273,
            CornerRadius = new CornerRadius(
                height * 8 / 273, height * 129 / 273,
                height * 6 / 273, height * 30 / 273),
            Background = Brush("AppAccent"),
        };
        var bottom = new Border
        {
            Width = width * 173 / 260, Height = height * 126 / 273,
            CornerRadius = new CornerRadius(
                height * 34 / 273, height * 6 / 273,
                height * 126 / 273, height * 8 / 273),
            Background = Brush("AppForeground"),
        };
        Canvas.SetLeft(top, width * 87 / 260);
        Canvas.SetLeft(bottom, width * 87 / 260);
        Canvas.SetTop(bottom, height * 147 / 273);
        mark.Children.Add(bar);
        mark.Children.Add(top);
        mark.Children.Add(bottom);
        return mark;
    }

    /// <summary>Kind badge pill — light tinted background, colored text.</summary>
    public static Border Badge(string text, Brush fg, Brush bg)
    {
        return new Border
        {
            Background = bg,
            CornerRadius = new CornerRadius(4),
            Padding = new Thickness(7, 2, 7, 2),
            VerticalAlignment = VerticalAlignment.Center,
            Child = new TextBlock { Text = text, FontSize = Scaled(11), FontWeight = FontWeights.Medium, Foreground = fg },
        };
    }

    /// <summary>Type column: a kind-colour dot and a word — no tinted fill (§3.4).</summary>
    public static Border KindBadge(string kindId)
    {
        var cat = FileTypes.Categories.FirstOrDefault(c => c.Id == kindId);
        string label = cat?.Label ?? (kindId == FileTypes.FolderId ? "Folder" : "Other");
        var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(Dot(KindColor(kindId), 6));
        var t = T(label, 11, null, Brush("AppSubtle"));
        t.Margin = new Thickness(6, 0, 0, 0);
        t.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(t);
        return new Border { Child = row };
    }

    /// <summary>Safety — a dot and a word, never a fill (spec §3.2).</summary>
    public static Border SafetyBadge(bool safe, string? text = null)
    {
        return new Border
        {
            VerticalAlignment = VerticalAlignment.Center,
            Child = SafetyLabel(safe ? Brush("AppSuccess") : Brush("AppWarning"),
                text ?? (safe ? "Generally safe" : "Review first"), 11),
        };
    }

    // ---- Buttons ----

    public enum ButtonStyle { Outline, Primary, Dark, Danger, Ghost }

    public static System.Windows.Controls.Button Button(string text, string? glyph, ButtonStyle style, Action? onClick = null)
    {
        var content = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (glyph is not null)
        {
            Brush glyphFg = style switch
            {
                ButtonStyle.Primary or ButtonStyle.Dark => Brush("AppInkButtonFg"),
                ButtonStyle.Danger => Brush("AppDanger"),
                _ => Brush("AppForeground"),
            };
            var icon = Glyph(glyph, 15, glyphFg);
            icon.Margin = new Thickness(0, 0, 6, 0);
            content.Children.Add(icon);
        }
        content.Children.Add(new TextBlock
        {
            Text = text, FontSize = Scaled(13),
            // Explicit — Foreground does not reliably inherit through the
            // templated ContentPresenter into element content.
            Foreground = style switch
            {
                ButtonStyle.Primary or ButtonStyle.Dark => Brush("AppInkButtonFg"),
                ButtonStyle.Danger => Brush("AppDanger"),
                _ => Brush("AppForeground"),
            },
            FontWeight = FontWeights.Medium,
            VerticalAlignment = VerticalAlignment.Center,
        });

        var btn = new System.Windows.Controls.Button
        {
            Content = content,
            MinHeight = 28,
            Padding = new Thickness(12, 0, 12, 0),
            Cursor = Cursors.Hand,
        };
        ApplyButtonStyle(btn, style);
        System.Windows.Automation.AutomationProperties.SetName(btn, text);
        if (onClick is not null) btn.Click += (_, _) => onClick();
        return btn;
    }

    public static System.Windows.Controls.Button IconButton(string glyph, string label, Action onClick)
    {
        var btn = new System.Windows.Controls.Button
        {
            Content = Glyph(glyph, 16, Brush("AppSubtle")),
            Width = 28, Height = 28, Padding = new Thickness(0),
            Cursor = Cursors.Hand, ToolTip = label,
        };
        System.Windows.Automation.AutomationProperties.SetName(btn, label);
        ApplyButtonStyle(btn, ButtonStyle.Ghost);
        btn.Click += (_, _) => onClick();
        return btn;
    }

    public static void ApplyButtonStyle(System.Windows.Controls.Button btn, ButtonStyle style)
    {
        Brush bg, fg, border;
        switch (style)
        {
            case ButtonStyle.Primary:
                // Calm system: the one filled button is ink — violet is
                // selection/links/chips, never a button (§8).
                bg = Brush("AppInkButton"); fg = Brush("AppInkButtonFg"); border = Brush("AppInkButton"); break;
            case ButtonStyle.Dark:
                bg = Brush("AppInkButton"); fg = Brush("AppInkButtonFg"); border = Brush("AppInkButton"); break;
            case ButtonStyle.Danger:
                bg = Brush("AppDangerBg"); fg = Brush("AppDanger"); border = Brush("AppDangerBg"); break;
            case ButtonStyle.Ghost:
                bg = Brushes.Transparent; fg = Brush("AppForeground"); border = Brushes.Transparent; break;
            default:
                bg = Brush("AppCard"); fg = Brush("AppForeground"); border = Brush("AppCardBorder"); break;
        }
        btn.Background = bg;
        btn.Foreground = fg;
        btn.BorderBrush = border;
        btn.BorderThickness = new Thickness(style == ButtonStyle.Ghost ? 0 : 1);
        btn.HorizontalContentAlignment = HorizontalAlignment.Center;
        btn.Template = RoundedButtonTemplate();
    }

    /// <summary>Simple rounded-rect template so every button shares chrome.</summary>
    private static ControlTemplate RoundedButtonTemplate()
    {
        var template = new ControlTemplate(typeof(System.Windows.Controls.Button));
        var border = new FrameworkElementFactory(typeof(Border));
        border.SetValue(Border.BackgroundProperty, new TemplateBindingExtension(Control.BackgroundProperty));
        border.SetValue(Border.BorderBrushProperty, new TemplateBindingExtension(Control.BorderBrushProperty));
        border.SetValue(Border.BorderThicknessProperty, new TemplateBindingExtension(Control.BorderThicknessProperty));
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(6));
        border.SetValue(Border.PaddingProperty, new TemplateBindingExtension(Control.PaddingProperty));
        var content = new FrameworkElementFactory(typeof(ContentPresenter));
        content.SetValue(ContentPresenter.HorizontalAlignmentProperty, HorizontalAlignment.Center);
        content.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
        border.AppendChild(content);
        template.VisualTree = border;
        var hover = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(UIElement.OpacityProperty, 0.85));
        template.Triggers.Add(hover);
        var disabled = new Trigger { Property = UIElement.IsEnabledProperty, Value = false };
        disabled.Setters.Add(new Setter(UIElement.OpacityProperty, 0.45));
        template.Triggers.Add(disabled);
        return template;
    }

    /// <summary>Filter chip — compact accent tint when selected, no outline when idle (§9).</summary>
    public static System.Windows.Controls.Button Pill(string text, bool selected, Action onClick)
    {
        var foreground = selected ? Brush("AppForeground") : Brush("AppSubtle");
        var btn = new System.Windows.Controls.Button
        {
            Content = new TextBlock
            {
                Text = text, FontSize = Scaled(13), FontWeight = FontWeights.Medium,
                Foreground = foreground, VerticalAlignment = VerticalAlignment.Center,
            },
            Foreground = foreground,
            Background = selected ? Brush("AppAccentSoft") : Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Height = 26,
            Padding = new Thickness(9, 0, 9, 0),
            Cursor = Cursors.Hand,
        };
        var template = new ControlTemplate(typeof(System.Windows.Controls.Button));
        var border = new FrameworkElementFactory(typeof(Border));
        border.SetValue(Border.BackgroundProperty, new TemplateBindingExtension(Control.BackgroundProperty));
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(6));
        border.SetValue(Border.PaddingProperty, new TemplateBindingExtension(Control.PaddingProperty));
        var content = new FrameworkElementFactory(typeof(ContentPresenter));
        content.SetValue(ContentPresenter.HorizontalAlignmentProperty, HorizontalAlignment.Center);
        content.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
        border.AppendChild(content);
        template.VisualTree = border;
        var hover = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(Control.BackgroundProperty, selected ? Brush("AppAccentSoft") : Brush("AppHover")));
        template.Triggers.Add(hover);
        btn.Template = template;
        System.Windows.Automation.AutomationProperties.SetName(btn, text);
        btn.Click += (_, _) => onClick();
        return btn;
    }

    // ---- Fields ----

    /// <summary>Thirty-pixel search field with a clear action and focus outline (§9.1).</summary>
    public static (Border Box, TextBox Input) SearchBox(string placeholder, double width = 300)
    {
        var input = new TextBox
        {
            FontSize = Scaled(13),
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            VerticalAlignment = VerticalAlignment.Center,
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        var hint = new TextBlock
        {
            Text = placeholder, FontSize = Scaled(13), Foreground = Brush("AppFaint"),
            IsHitTestVisible = false, VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(2, 0, 0, 0),
        };
        var textHost = new Grid();
        textHost.Children.Add(input);
        textHost.Children.Add(hint);

        var row = new DockPanel();
        var icon = Glyph(Icons.Search, 12, Brush("AppFaint"));
        icon.Margin = new Thickness(0, 0, 8, 0);
        DockPanel.SetDock(icon, Dock.Left);
        row.Children.Add(icon);
        var clear = Glyph(Icons.Cancel, 15, Brush("AppFaint"));
        clear.Visibility = Visibility.Collapsed;
        clear.Cursor = Cursors.Hand;
        clear.Margin = new Thickness(8, 0, 0, 0);
        clear.VerticalAlignment = VerticalAlignment.Center;
        clear.MouseLeftButtonDown += (_, e) => { input.Clear(); input.Focus(); e.Handled = true; };
        DockPanel.SetDock(clear, Dock.Right);
        row.Children.Add(clear);
        row.Children.Add(textHost);
        var box = new Border
        {
            Background = Brush("AppField"),
            BorderBrush = Brush("AppCardBorder"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(11, 0, 11, 0),
            Height = 32,
            Width = width,
            Child = row,
        };
        input.TextChanged += (_, _) =>
        {
            hint.Visibility = input.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            clear.Visibility = input.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        };
        bool focused = false, hovering = false;
        void PaintBorder() => box.BorderBrush = focused
            ? WithOpacity("AppAccent", 0.75)
            : hovering ? WithOpacity("AppFaint", 0.55) : Brush("AppCardBorder");
        input.GotKeyboardFocus += (_, _) => { focused = true; PaintBorder(); };
        input.LostKeyboardFocus += (_, _) => { focused = false; PaintBorder(); };
        input.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Escape || input.Text.Length == 0) return;
            input.Clear();
            e.Handled = true;
        };
        box.MouseEnter += (_, _) => { hovering = true; PaintBorder(); };
        box.MouseLeave += (_, _) => { hovering = false; PaintBorder(); };
        box.MouseLeftButtonDown += (_, _) => input.Focus();
        return (box, input);
    }

    // ---- Table chrome ----

    /// <summary>Uppercase-ish column header row.</summary>
    public static Grid TableHeader(params (string Label, GridLength Width, bool Right)[] cols)
    {
        var grid = new Grid { Margin = new Thickness(0, 0, 0, 4) };
        for (int i = 0; i < cols.Length; i++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = cols[i].Width });
            var label = new TextBlock
            {
                Text = cols[i].Label, FontSize = Scaled(11), FontWeight = FontWeights.Medium,
                Foreground = Brush("AppFaint"),
                HorizontalAlignment = cols[i].Right ? HorizontalAlignment.Right : HorizontalAlignment.Left,
                Margin = new Thickness(i == 0 ? 0 : 8, 0, 0, 0),
            };
            Grid.SetColumn(label, i);
            grid.Children.Add(label);
        }
        return grid;
    }

    /// <summary>A row's shared column grid; callers place cell content.</summary>
    public static Grid TableRowGrid(params GridLength[] widths)
    {
        var grid = new Grid { MinHeight = RowHeight };
        foreach (var w in widths) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = w });
        return grid;
    }

    public static void Cell(Grid row, UIElement element, int column, bool right = false)
    {
        Grid.SetColumn(element, column);
        if (element is FrameworkElement fe && right) fe.HorizontalAlignment = HorizontalAlignment.Right;
        if (element is FrameworkElement f2) f2.VerticalAlignment = VerticalAlignment.Center;
        if (element is FrameworkElement f3 && column > 0) f3.Margin = new Thickness(8, 0, 0, 0);
        row.Children.Add(element);
    }

    /// <summary>Two-line name cell: icon tile + name over gray path.</summary>
    public static DockPanel NameCell(string glyph, Brush glyphBg, Brush glyphFg,
        string name, string? sub, double iconSize = 30)
    {
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(T(name, 13, FontWeights.Medium));
        if (sub is { Length: > 0 })
            text.Children.Add(Faint(sub));
        var icon = IconTile(glyph, iconSize, glyphBg, glyphFg, 7);
        icon.Margin = new Thickness(0, 0, 10, 0);
        DockPanel.SetDock(icon, Dock.Left);
        var dock = new DockPanel();
        dock.Children.Add(icon);
        dock.Children.Add(text);
        return dock;
    }

    /// <summary>Overflow "⋯" button.</summary>
    public static System.Windows.Controls.Button MoreButton(Action onClick)
    {
        var btn = Button(" ", Icons.More, ButtonStyle.Ghost, onClick);
        btn.Padding = new Thickness(6, 2, 6, 2);
        return btn;
    }

    // ---- Bars ----

    /// <summary>Thin progress bar (track + fill), rounded ends.</summary>
    public static Grid Bar(double fraction, Brush fill, double height = 6, double maxWidth = 160)
    {
        var grid = new Grid { Height = height, Width = maxWidth };
        var track = new Border { Background = Brush("AppBarTrack"), CornerRadius = new CornerRadius(height / 2) };
        var bar = new Border
        {
            Background = fill,
            CornerRadius = new CornerRadius(height / 2),
            HorizontalAlignment = HorizontalAlignment.Left,
            Width = Math.Max(0, Math.Min(1, fraction)) * maxWidth,
        };
        grid.Children.Add(track);
        grid.Children.Add(bar);
        return grid;
    }

    // ---- Cards with icon + title header ----

    /// <summary>
    /// Calm section (§11.3): a mono label, a hairline, the body — no
    /// icon tile, no card chrome. The legacy icon params are accepted
    /// so call sites don't change; they're ignored.
    /// </summary>
    public static Border HeadedCard(string glyph, Brush iconBg, Brush iconFg,
        string title, string? subtitle, UIElement body, Thickness? margin = null)
    {
        var stack = new StackPanel();
        stack.Children.Add(SectionHeader(title, subtitle));
        stack.Children.Add(new Border { Height = 10 });
        stack.Children.Add(body);
        return new Border { Child = stack, Margin = margin ?? new Thickness(0, 0, 0, 24) };
    }

    /// <summary>Page header: colored icon tile + bold title + gray subtitle.</summary>
    public static DockPanel PageHeader(string glyph, Brush iconBg, Brush iconFg,
        string title, string subtitle)
    {
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 16) };
        var tile = IconTile(glyph, 44, iconBg, iconFg, 10);
        DockPanel.SetDock(tile, Dock.Left);
        header.Children.Add(tile);
        var text = new StackPanel { Margin = new Thickness(12, 2, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(T(title, 20, FontWeights.Bold));
        text.Children.Add(Subtle(subtitle, 12.5));
        header.Children.Add(text);
        return header;
    }

    /// <summary>One stat: a mono figure on top, label line below.</summary>
    public static Border StatCard(string glyph, Brush iconBg, Brush iconFg,
        string value, string label, string? sub = null)
    {
        var stack = new StackPanel();
        var vt = Mono(value, 20, FontWeights.SemiBold);
        vt.Margin = new Thickness(0, 0, 0, 3);
        stack.Children.Add(vt);
        var labelText = T(label, 11.5, FontWeights.Medium, Brush("AppSubtle"), wrap: true);
        stack.Children.Add(labelText);
        if (sub is not null)
        {
            var detail = Faint(sub);
            detail.TextWrapping = TextWrapping.Wrap;
            detail.Margin = new Thickness(0, 2, 0, 0);
            stack.Children.Add(detail);
        }
        return new Border { Child = stack };
    }

    /// <summary>One flat figure strip with hairlines between figures.</summary>
    public static UniformGrid StatRow(params Border[] cards)
    {
        var grid = new UniformGrid { Columns = cards.Length, Margin = new Thickness(0, 2, 0, GroupGap) };
        for (int i = 0; i < cards.Length; i++)
        {
            cards[i].BorderBrush = Brush("AppBorder");
            cards[i].BorderThickness = new Thickness(i == 0 ? 0 : 1, 0, 0, 0);
            cards[i].Padding = new Thickness(i == 0 ? 0 : 24, 0, i == cards.Length - 1 ? 0 : 24, 0);
            grid.Children.Add(cards[i]);
        }
        return grid;
    }

    /// <summary>Colored dot + label + thin bar + right value — a breakdown row.</summary>
    public static DockPanel DotRow(Brush color, string label, string value, double frac)
    {
        var row = new DockPanel { Margin = new Thickness(0, 4, 0, 4) };
        var val = Mono(value, 11, FontWeights.Medium, Brush("AppSubtle"));
        DockPanel.SetDock(val, Dock.Right);
        val.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(val);
        var dot = new Border
        {
            Width = 8, Height = 8, CornerRadius = new CornerRadius(4),
            Background = color, Margin = new Thickness(0, 0, 8, 0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        DockPanel.SetDock(dot, Dock.Left);
        row.Children.Add(dot);
        var mid = new DockPanel();
        var name = T(label, 12);
        name.Margin = new Thickness(0, 0, 10, 0);
        DockPanel.SetDock(name, Dock.Left);
        mid.Children.Add(name);
        var bar = Bar(Math.Clamp(frac, 0.02, 1), color, 6, 0);
        bar.VerticalAlignment = VerticalAlignment.Center;
        mid.Children.Add(bar);
        row.Children.Add(mid);
        return row;
    }

    /// <summary>Thin colored bar sized to its container — for table cells.</summary>
    public static Grid MiniBar(double frac, Brush brush)
    {
        return Bar(Math.Clamp(frac, 0.02, 1), brush, 5, 0);
    }

    /// <summary>Table header label — the mono eyebrow (§12).</summary>
    public static TextBlock TableHead(string text) =>
        MonoLabel(text, Brush("AppSubtle"));

    /// <summary>Segmented bar of (value, brush) parts — for age/type distribution.</summary>
    public static Grid Segmented(List<(double Frac, Brush B)> parts, double height = 10)
    {
        var g = new Grid { Height = height };
        for (int i = 0; i < parts.Count; i++)
            g.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = new GridLength(Math.Max(parts[i].Frac, 0.001), GridUnitType.Star),
            });
        for (int i = 0; i < parts.Count; i++)
        {
            var seg = new Border { Background = parts[i].B };
            Grid.SetColumn(seg, i);
            g.Children.Add(seg);
        }
        var host = new Grid { Height = height };
        host.Children.Add(new Border { Background = Brush("AppBarTrack"), CornerRadius = new CornerRadius(height / 2) });
        host.Children.Add(new Border { CornerRadius = new CornerRadius(height / 2), ClipToBounds = true, Child = g });
        return host;
    }

    /// <summary>
    /// Bottom selection/action bar: "N selected · X" | buttons | "N items · X".
    /// </summary>
    public static Border BottomBar(FrameworkElement left, FrameworkElement right,
        params FrameworkElement[] middleButtons)
    {
        var dock = new DockPanel();
        left.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(left, Dock.Left);
        dock.Children.Add(left);
        right.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(right, Dock.Right);
        dock.Children.Add(right);
        var mid = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        foreach (var b in middleButtons)
        {
            b.Margin = new Thickness(4, 0, 4, 0);
            mid.Children.Add(b);
        }
        dock.Children.Add(mid);
        return new Border
        {
            BorderBrush = Brush("AppBorder"), BorderThickness = new Thickness(0, 1, 0, 0),
            MinHeight = 48, Padding = new Thickness(10, 8, 10, 0), Child = dock,
        };
    }


    /// <summary>Empty-state block: big glyph, title, gray body, optional action.</summary>
    public static StackPanel EmptyState(string glyph, string title, string body,
        System.Windows.Controls.Button? action = null, bool allowDusty = true)
    {
        var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 60, 0, 0) };
        var icon = allowDusty && AppSettings.Load().ShowDusty
            ? BrandIcon(72)
            : Glyph(glyph, 34, Brush("AppFaint"));
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        var t = T(title, 15, FontWeights.SemiBold);
        t.HorizontalAlignment = HorizontalAlignment.Center;
        var b = Subtle(body);
        b.HorizontalAlignment = HorizontalAlignment.Center;
        b.TextAlignment = TextAlignment.Center;
        stack.Children.Add(icon);
        stack.Children.Add(new Border { Height = 12 });
        stack.Children.Add(t);
        stack.Children.Add(new Border { Height = 6 });
        stack.Children.Add(b);
        if (action is not null)
        {
            stack.Children.Add(new Border { Height = 18 });
            stack.Children.Add(action);
        }
        return stack;
    }

    /// <summary>Info callout card — light blue, ⓘ icon, text.</summary>
    public static Border InfoCard(string title, string body, Thickness? margin = null)
    {
        var row = new DockPanel();
        var icon = Glyph(Icons.Info, 14, Brush("AppAccent"));
        DockPanel.SetDock(icon, Dock.Top);
        icon.Margin = new Thickness(0, 1, 8, 0);
        var text = new StackPanel();
        text.Children.Add(T(title, 12, FontWeights.SemiBold));
        text.Children.Add(new Border { Height = 3 });
        text.Children.Add(new TextBlock
        {
            Text = body, FontSize = Scaled(11.5), Foreground = Brush("AppSubtle"),
            TextWrapping = TextWrapping.Wrap,
        });
        row.Children.Add(icon);
        row.Children.Add(text);
        return new Border
        {
            Background = Brushes.Transparent,
            BorderBrush = Brush("AppBorder"), BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(12, 10, 12, 10),
            Margin = margin ?? new Thickness(0, 0, 0, 12),
            Child = row,
        };
    }

    /// <summary>Warning callout card — amber, ⚠ icon, text.</summary>
    public static Border WarningCard(string title, string body, Thickness? margin = null)
    {
        // Calm system: a warning is a dot and a word inside a hairline
        // notice — never an amber fill (§3.2/§11.4).
        var inner = new StackPanel();
        var head = new StackPanel { Orientation = Orientation.Horizontal };
        head.Children.Add(Dot(Brush("AppWarning"), 6));
        var t = T(title, 12.5, FontWeights.Medium);
        t.Margin = new Thickness(8, 0, 0, 0);
        t.VerticalAlignment = VerticalAlignment.Center;
        head.Children.Add(t);
        inner.Children.Add(head);
        var b = new TextBlock
        {
            Text = body, FontSize = Scaled(11.5), Foreground = Brush("AppSubtle"),
            TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0),
        };
        inner.Children.Add(b);
        return new Border
        {
            BorderBrush = Brush("AppBorder"), BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(12, 10, 12, 10),
            Margin = margin ?? new Thickness(0, 0, 0, 12),
            Child = inner,
        };
    }

    /// <summary>Metadata row: gray label left, value right.</summary>
    // ---- Calm kit (docs/DESIGN.md): mono type, hairlines, section
    // headers, dot+word safety, the data palette ----

    /// <summary>SF Mono's Windows counterpart — figures, counts, dates, paths (§4.2).</summary>
    private static readonly FontFamily MonoFont = new("Cascadia Mono, Consolas");

    /// <summary>Mono text — sizes, counts, paths (§4.2). 12 regular.</summary>
    public static TextBlock Mono(string text, double size = 12, FontWeight? weight = null, Brush? fg = null) =>
        new()
        {
            Text = text, FontFamily = MonoFont, FontSize = Scaled(size),
            FontWeight = weight ?? FontWeights.Regular,
            Foreground = fg ?? Brush("AppForeground"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };

    /// <summary>Eyebrow/section label — 10 pt medium mono, uppercase (§4.1 `label`).</summary>
    public static TextBlock MonoLabel(string text, Brush? fg = null, double size = 10) =>
        new()
        {
            Text = text.ToUpperInvariant(), FontFamily = MonoFont, FontSize = Scaled(size),
            FontWeight = FontWeights.Medium, Foreground = fg ?? Brush("AppFaint"),
            VerticalAlignment = VerticalAlignment.Center,
        };

    /// <summary>The one separator — 1 px of `line` (§6).</summary>
    public static Border Hairline() =>
        new() { Height = 1, Background = Brush("AppBorder") };

    /// <summary>Dashed hairline (3/3) — one per screen, under the first-run hero (§6).</summary>
    public static System.Windows.Shapes.Line DashedHairline() =>
        new()
        {
            X1 = 0, X2 = 1, Y1 = 0.5, Y2 = 0.5, Height = 1,
            Stroke = Brush("AppBorder"), StrokeThickness = 1,
            StrokeDashArray = new DoubleCollection { 3, 3 },
            Stretch = System.Windows.Media.Stretch.Fill,
            SnapsToDevicePixels = true,
        };

    /// <summary>The 6 pt safety dot (§3.2) — colour carries the word, never a fill.</summary>
    public static System.Windows.Shapes.Ellipse Dot(Brush fill, double size = 6) =>
        new()
        {
            Width = size, Height = size, Fill = fill,
            VerticalAlignment = VerticalAlignment.Center,
        };

    /// <summary>Safety as spec'd: a 6 pt dot followed by a word — no fills (§3.2).</summary>
    public static StackPanel SafetyLabel(Brush color, string word, double size = 11.5)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(Dot(color));
        var t = T(word, size, FontWeights.Medium, color);
        t.Margin = new Thickness(6, 0, 0, 0);
        t.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(t);
        return row;
    }

    /// <summary>
    /// `SectionHeader` (§11.3): a mono label in ink2, an optional mono
    /// detail in ink3, an optional trailing element (usually a link),
    /// hairline underneath.
    /// </summary>
    public static FrameworkElement SectionHeader(string label, string? detail = null, FrameworkElement? trailing = null)
    {
        var stack = new StackPanel();
        var row = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        if (trailing is not null)
        {
            DockPanel.SetDock(trailing, Dock.Right);
            row.Children.Add(trailing);
        }
        var text = new StackPanel { Orientation = Orientation.Horizontal };
        text.Children.Add(MonoLabel(label, Brush("AppSubtle")));
        if (detail is not null)
        {
            var d = Mono("  " + detail, 10, null, Brush("AppFaint"));
            d.VerticalAlignment = VerticalAlignment.Bottom;
            text.Children.Add(d);
        }
        row.Children.Add(text);
        stack.Children.Add(row);
        stack.Children.Add(Hairline());
        return stack;
    }

    /// <summary>Accent text link — the `LinkButtonStyle` equivalent (§8).</summary>
    public static TextBlock LinkText(string text, Action onClick, double size = 12)
    {
        var t = T(text, size, FontWeights.Medium, Brush("AppAccent"));
        t.Cursor = Cursors.Hand;
        t.MouseLeftButtonDown += (_, _) => onClick();
        return t;
    }

    /// <summary>A colour at a fixed alpha — e.g. the 16% kind tint behind icons (§3.4).</summary>
    public static Brush Tint(Color color, byte alpha) =>
        new SolidColorBrush(Color.FromArgb(alpha, color.R, color.G, color.B));

    /// <summary>Slim bordered notice — the one sanctioned box on a page (§11.4).</summary>
    public static Border Notice(string title, string body)
    {
        var inner = new StackPanel();
        inner.Children.Add(T(title, 13, FontWeights.Medium));
        var b = Subtle(body, 12);
        b.Margin = new Thickness(0, 2, 0, 0);
        b.TextWrapping = TextWrapping.Wrap;
        inner.Children.Add(b);
        return new Border
        {
            Background = Brushes.Transparent,
            BorderBrush = Brush("AppBorder"), BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10), Padding = new Thickness(12, 10, 12, 10),
            Child = inner,
        };
    }

    /// <summary>A brush at a lower opacity — e.g. ink @ 55% for the capacity bar.</summary>
    public static Brush WithOpacity(string resourceKey, double opacity)
    {
        var c = ((SolidColorBrush)Brush(resourceKey)).Color;
        return new SolidColorBrush(c) { Opacity = opacity };
    }

    /// <summary>§3.3 — the one data palette for charts, bars, categories.</summary>
    public static readonly string[] DataPalette =
        ["#849BB8", "#A795C7", "#C78797", "#7BA89C", "#B9A071", "#8FACC0", "#A2A4AC"];

    public static Brush Data(int i) => Hex(DataPalette[i % DataPalette.Length]);
    public static Brush DataTint(int i) => Tint(((SolidColorBrush)Data(i)).Color, 41);

    /// <summary>§3.4 — file-kind colour map (fixed, both appearances).</summary>
    public static Brush KindColor(string kindId) => kindId switch
    {
        "video" => Hex("#C78797"),
        "audio" => Hex("#A795C7"),
        "image" => Hex("#8FACC0"),
        "document" => Hex("#7BA89C"),
        "developer" => Hex("#849BB8"),
        "archive" => Hex("#B9A071"),
        "diskImage" => Hex("#849BB8"),
        "application" => Hex("#8FACC0"),
        "virtualDisk" or "virtualMachine" => Hex("#A795C7"),
        "deviceBackup" or "backup" => Hex("#9FB5A9"),
        "database" => Hex("#A2A4AC"),
        _ => Hex("#A2A4AC"),
    };

    /// <summary>6 pt capacity/proportion bar with a `line` track (§14.1).</summary>
    public static Grid CapacityBar(double fraction, Brush fill, double maxWidth = 520)
    {
        // Star columns size the fill declaratively — no SizeChanged
        // dance, and the radius stays on both edges of the track.
        fraction = Math.Max(0, Math.Min(1, fraction));
        var grid = new Grid { Height = 6, HorizontalAlignment = HorizontalAlignment.Stretch };
        if (!double.IsNaN(maxWidth) && !double.IsInfinity(maxWidth))
            grid.MaxWidth = maxWidth;
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(fraction, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1 - fraction, GridUnitType.Star) });
        var track = new Border { Background = Brush("AppBarTrack"), CornerRadius = new CornerRadius(3) };
        Grid.SetColumnSpan(track, 2);
        var bar = new Border { Background = fill, CornerRadius = new CornerRadius(3) };
        grid.Children.Add(track);
        grid.Children.Add(bar);
        return grid;
    }

    /// <summary>A 36 pt calm row — hover fill, radius 6, hand cursor (§10.1).</summary>
    public static Border HoverRow(FrameworkElement content, Action? onClick = null)
    {
        var row = new Border
        {
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(10, 0, 10, 0),
            Child = content,
            MinHeight = 36,
        };
        row.MouseEnter += (_, _) => row.Background = Brush("AppHover");
        row.MouseLeave += (_, _) => row.Background = Brushes.Transparent;
        if (onClick is not null)
        {
            row.Cursor = Cursors.Hand;
            row.MouseLeftButtonDown += (_, _) => onClick();
        }
        return row;
    }

    /// <summary>The segmented composition bar — 6 pt, 2 pt gaps (§14.1).</summary>
    public static Grid SegBar(List<(double Frac, Brush B)> parts) => Segmented(parts, 6);

    public static DockPanel MetaRow(string label, UIElement value)
    {
        var dock = new DockPanel { Margin = new Thickness(0, 5, 0, 5) };
        var v = value;
        DockPanel.SetDock(v, Dock.Right);
        dock.Children.Add(v);
        dock.Children.Add(T(label, 12, null, Brush("AppSubtle")));
        return dock;
    }

    public static DockPanel MetaRow(string label, string value) =>
        MetaRow(label, T(value, 12, FontWeights.Medium));

    // ---- Dates ----

    public static DateTime? DayToDate(int modifiedDay)
    {
        if (modifiedDay <= 0) return null;
        return DateTimeOffset.FromUnixTimeSeconds((long)modifiedDay * 86_400).LocalDateTime;
    }

    /// <summary>"3 months ago", "1 day ago", "today".</summary>
    public static string RelativeDay(int modifiedDay)
    {
        var date = DayToDate(modifiedDay);
        if (date is not { } d) return "—";
        var days = (DateTime.Now.Date - d.Date).Days;
        return days switch
        {
            <= 0 => "today",
            1 => "1 day ago",
            < 7 => $"{days} days ago",
            < 14 => "1 week ago",
            < 30 => $"{days / 7} weeks ago",
            < 60 => "1 month ago",
            < 365 => $"{days / 30} months ago",
            < 730 => "1 year ago",
            _ => $"{days / 365} years ago",
        };
    }

    /// <summary>"Mon, 12 Aug 2024 at 4:20 PM" — the inspector's second line.</summary>
    public static string AbsoluteDay(int modifiedDay)
    {
        var date = DayToDate(modifiedDay);
        return date is { } d ? d.ToString("ddd, d MMM yyyy") : "—";
    }

    /// <summary>
    /// Creation + last-write times for one path — read on demand for the
    /// inspector only (the tree stores just modifiedDay; one extra stat
    /// per selection is nothing).
    /// </summary>
    public static (DateTime? Created, DateTime? Modified)? FileTimes(string path)
    {
        try
        {
            if (!File.Exists(path) && !Directory.Exists(path)) return null;
            return (File.GetCreationTime(path), File.GetLastWriteTime(path));
        }
        catch { return null; }
    }

    // ---- Segmented type bar ----

    /// <summary>
    /// The stacked colored bar from the mockups: proportional segments,
    /// rounded ends, built as raw drawing so it never allocates controls
    /// per segment.
    /// </summary>
    public sealed class SegmentedBar : FrameworkElement
    {
        private List<(long Value, Brush Brush)> _segments = [];
        private long _total;

        public void Set(List<(long Value, Brush Brush)> segments, long total)
        {
            _segments = segments;
            _total = Math.Max(1, total);
            InvalidateVisual();
        }

        protected override void OnRender(DrawingContext dc)
        {
            var size = new Size(ActualWidth, ActualHeight);
            if (size.Width <= 0 || size.Height <= 0) return;
            double radius = size.Height / 2;
            var clip = new RectangleGeometry(new Rect(size), radius, radius);
            dc.PushClip(clip);
            double x = 0;
            foreach (var (value, brush) in _segments)
            {
                if (value <= 0) continue;
                double w = value * size.Width / _total;
                if (x + w > size.Width) w = size.Width - x;
                dc.DrawRectangle(brush, null, new Rect(x, 0, Math.Max(0, w), size.Height));
                x += w;
                if (x >= size.Width) break;
            }
            if (x < size.Width)
                dc.DrawRectangle(Brush("AppBarTrack"), null, new Rect(x, 0, size.Width - x, size.Height));
            dc.Pop();
        }
    }

    /// <summary>One legend item: colored dot + text.</summary>
    public static StackPanel LegendDot(Brush color, string text)
    {
        var item = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 2, 14, 2) };
        item.Children.Add(new Border
        {
            Width = 8, Height = 8, CornerRadius = new CornerRadius(4),
            Background = color, Margin = new Thickness(0, 0, 6, 0),
            VerticalAlignment = VerticalAlignment.Center,
        });
        item.Children.Add(T(text, 11.5, null, Brush("AppSubtle")));
        return item;
    }

    /// <summary>Segmented bar + legend rows (dot, label, size, percent).</summary>
    public static StackPanel TypeBarWithLegend(List<(string Label, long Bytes, Brush Color)> parts, long total)
    {
        var stack = new StackPanel();
        var bar = new SegmentedBar { Height = 10, Margin = new Thickness(0, 0, 0, 8) };
        bar.Set(parts.Select(p => (p.Bytes, p.Color)).ToList(), total);
        stack.Children.Add(bar);
        var legend = new WrapPanel();
        foreach (var (label, bytes, color) in parts.Take(6))
        {
            if (bytes <= 0) continue;
            var item = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 2, 14, 2) };
            item.Children.Add(new Border
            {
                Width = 8, Height = 8, CornerRadius = new CornerRadius(4),
                Background = color, Margin = new Thickness(0, 0, 6, 0),
                VerticalAlignment = VerticalAlignment.Center,
            });
            item.Children.Add(T($"{ByteFormat.Format(bytes)} {label}", 11.5, null, Brush("AppSubtle")));
            legend.Children.Add(item);
        }
        stack.Children.Add(legend);
        return stack;
    }
}
