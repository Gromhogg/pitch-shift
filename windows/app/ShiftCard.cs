using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Markup;

namespace PitchShift;

// One card: title + on/off switch, the big number, − 0 + buttons, then the card's own rows (Body).
[ContentProperty(nameof(Body))]
sealed class ShiftCard : Border
{
    public const double InnerWidth = 248;

    public readonly ToggleButton Switch = new();
    public AmountBox Amount { get; private set; } = null!;
    public readonly Button Minus = new(), Zero = new(), Plus = new();
    public event Action<bool>? Toggled;
    public event Action<double>? AmountChosen;

    readonly TextBlock title = new();
    readonly ContentControl body = new();
    readonly StackPanel stack = new();
    string key = "";
    bool updating;  // true while Show() sets the switch (not a click)

    public ShiftCard()
    {
        CornerRadius = new CornerRadius(8);
        BorderThickness = new Thickness(1);
        SetResourceReference(BackgroundProperty, "PsCardBack");
        SetResourceReference(BorderBrushProperty, "PsCardBorder");
        Width = InnerWidth + 32 + 2;
        stack.Margin = new Thickness(16, 14, 16, 16);
        Child = stack;
    }

    // "Hear" or "Voice": used for the names the checks find things by.
    public string Key
    {
        get => key;
        set
        {
            key = value;
            Build();
        }
    }

    public string Title
    {
        get => title.Text;
        set
        {
            title.Text = value;
            AutomationProperties.SetName(Switch, value);
        }
    }

    public object? Body
    {
        get => body.Content;
        set => body.Content = value;
    }

    void Build()
    {
        stack.Children.Clear();

        title.FontSize = 14;
        title.FontWeight = FontWeights.SemiBold;
        title.VerticalAlignment = VerticalAlignment.Center;
        title.SetResourceReference(TextBlock.ForegroundProperty, "PsText");
        Switch.Style = (Style)Application.Current.FindResource("PsSwitch");
        Switch.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetAutomationId(Switch, key + "Switch");
        // Checked/Unchecked (not Click), so screen readers and the UI checks can switch it too.
        Switch.Checked += (_, _) => { if (!updating) Toggled?.Invoke(true); };
        Switch.Unchecked += (_, _) => { if (!updating) Toggled?.Invoke(false); };
        var header = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(Switch, Dock.Right);
        header.Children.Add(Switch);
        header.Children.Add(title);
        stack.Children.Add(header);

        Amount = new AmountBox(key) { Margin = new Thickness(0, 4, 0, 6) };
        Amount.Committed += v => AmountChosen?.Invoke(v);
        stack.Children.Add(Amount);

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
        // Glyphs in the icon's middle color. No keyboard shortcuts: they'd catch a typed "-" or "0".
        Setup(Minus, "−", "Lower", "Minus", () => Amount.Value = Step(-1));
        Setup(Zero, "0", "Normal", "Zero", () => Amount.Value = 0);
        Setup(Plus, "+", "Higher", "Plus", () => Amount.Value = Step(+1));
        Zero.Margin = new Thickness(8, 0, 8, 0);
        buttons.Children.Add(Minus);
        buttons.Children.Add(Zero);
        buttons.Children.Add(Plus);
        stack.Children.Add(buttons);

        body.Margin = new Thickness(0, 16, 0, 0);
        body.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        stack.Children.Add(body);
    }

    double Step(int direction) => PitchShift.Amount.Step(Amount.Value, direction);

    void Setup(Button button, string glyph, string name, string id, Action apply)
    {
        var text = new TextBlock
        {
            Text = glyph,
            FontSize = glyph == "0" ? 14 : 18,
            FontWeight = glyph == "0" ? FontWeights.SemiBold : FontWeights.Normal,
            Foreground = Theme.MidBrush,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, glyph == "0" ? 0 : -2, 0, 0),
        };
        button.Content = text;
        button.Width = 52;
        button.Height = 30;
        button.Padding = new Thickness(0);
        button.HorizontalContentAlignment = HorizontalAlignment.Center;
        button.VerticalContentAlignment = VerticalAlignment.Center;
        button.IsEnabledChanged += (_, _) => text.Opacity = button.IsEnabled ? 1 : 0.35;
        AutomationProperties.SetName(button, name);
        AutomationProperties.SetAutomationId(button, key + id);
        button.Click += (_, _) =>
        {
            if (Amount.IsEditing) Amount.Finish(apply: true);
            apply();
            AmountChosen?.Invoke(Amount.Value);
        };
    }

    // Updates the number and buttons. `active` = the card is on (and can work);
    // `waiting` = the chosen apps aren't running, so the number is drawn lighter.
    public void Show(bool on, double value, bool active, bool waiting)
    {
        if (Switch.IsChecked != on)
        {
            updating = true;
            Switch.IsChecked = on;
            updating = false;
        }
        if (!Amount.IsEditing) Amount.Value = value;
        Amount.IsEnabled = active;
        Amount.Strength = waiting ? 0.45 : 1;
        Amount.Opacity = active ? 1 : 0.35;
        Minus.IsEnabled = active && value > PitchShift.Amount.Min;
        Plus.IsEnabled = active && value < PitchShift.Amount.Max;
        Zero.IsEnabled = active && value != 0;
    }
}
