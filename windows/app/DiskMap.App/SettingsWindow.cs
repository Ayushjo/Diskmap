using System.Windows;
using System.Windows.Controls;

namespace DiskMap.App;

/// <summary>
/// WIN-060: the Settings window (Ctrl+,). Appearance and text size apply
/// through the same callbacks the View menu uses; the scan toggles just
/// persist — the next scan reads them.
/// </summary>
public sealed class SettingsWindow : Window
{
    private readonly AppSettings _settings = AppSettings.Load();
    private readonly Action<string> _onAppearance;
    private readonly Action<double> _onTextScale;
    private readonly StackPanel _appearanceRow = new() { Orientation = Orientation.Horizontal };
    private readonly StackPanel _textScaleRow = new() { Orientation = Orientation.Horizontal };

    public SettingsWindow(Action<string> onAppearance, Action<double> onTextScale)
    {
        _onAppearance = onAppearance;
        _onTextScale = onTextScale;

        Title = "DiskMap Settings";
        Width = 430;
        Height = 400;
        MinWidth = 380;
        MinHeight = 360;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ResizeMode = ResizeMode.CanMinimize;

        var body = new StackPanel { Margin = new Thickness(20) };

        body.Children.Add(Ui.SectionLabel("APPEARANCE"));
        _appearanceRow.Margin = new Thickness(0, 4, 0, 14);
        body.Children.Add(_appearanceRow);
        BuildAppearanceRow();

        body.Children.Add(Ui.SectionLabel("TEXT SIZE"));
        _textScaleRow.Margin = new Thickness(0, 4, 0, 14);
        body.Children.Add(_textScaleRow);
        BuildTextScaleRow();

        body.Children.Add(Ui.SectionLabel("SCANNING & HISTORY"));
        var history = new CheckBox
        {
            Content = new TextBlock
            {
                Text = "Keep storage history — so Overview can say what grew this week",
                TextWrapping = TextWrapping.Wrap, FontSize = 12.5,
            },
            IsChecked = _settings.KeepHistory,
            Margin = new Thickness(0, 6, 0, 6),
        };
        history.Click += (_, _) => { _settings.KeepHistory = history.IsChecked == true; _settings.Save(); };
        body.Children.Add(history);
        var clones = new CheckBox
        {
            Content = new TextBlock
            {
                Text = "Count block clones once on ReFS volumes — maps every file's extents after each scan (slower on large drives)",
                TextWrapping = TextWrapping.Wrap, FontSize = 12.5,
            },
            IsChecked = _settings.CloneAccounting,
            Margin = new Thickness(0, 2, 0, 0),
        };
        clones.Click += (_, _) => { _settings.CloneAccounting = clones.IsChecked == true; _settings.Save(); };
        body.Children.Add(clones);

        Content = body;
    }

    private static readonly (string Id, string Label)[] Appearances =
        [("system", "Follow Windows"), ("light", "Light"), ("dark", "Dark")];
    private static readonly (double Scale, string Label)[] TextScales =
        [(0.9, "Smaller"), (1.0, "Default"), (1.15, "Larger"), (1.3, "Largest")];

    private void BuildAppearanceRow()
    {
        _appearanceRow.Children.Clear();
        foreach (var (id, label) in Appearances)
        {
            string captured = id;
            var pill = Ui.Pill(label, _settings.Appearance == id, () =>
            {
                _settings.Appearance = captured;
                _onAppearance(captured);
                BuildAppearanceRow();
            });
            pill.Margin = new Thickness(0, 0, 6, 0);
            _appearanceRow.Children.Add(pill);
        }
    }

    private void BuildTextScaleRow()
    {
        _textScaleRow.Children.Clear();
        foreach (var (scale, label) in TextScales)
        {
            double captured = scale;
            var pill = Ui.Pill(label, Math.Abs(_settings.TextScale - scale) < 0.001, () =>
            {
                _settings.TextScale = captured;
                _onTextScale(captured);
                BuildTextScaleRow();
            });
            pill.Margin = new Thickness(0, 0, 6, 0);
            _textScaleRow.Children.Add(pill);
        }
    }
}
