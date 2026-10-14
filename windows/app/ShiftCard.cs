using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Effects;

namespace PitchShift;

// One card: title + on/off switch, the big number, − 0 + buttons, then the card's own rows (Body).
// Everything is sized for a scale `s` (1 = smallest window); a bigger window gives a bigger scale.
[ContentProperty(nameof(Body))]
sealed class ShiftCard : Grid
{
    public const double BaseWidth = 266;   // card width in the smallest window
    public const double BaseColumn = 232;  // width of the rows in the smallest window

    public readonly GradientSwitch Switch = new();
    public AmountBox Amount { get; private set; } = null!;
    public readonly Button Minus = new(), Zero = new(), Plus = new();
    public event Action<bool>? Toggled;
    public event Action<double>? AmountChosen;
    // Called when the scale changes, so the card's own rows can resize their controls.
    public event Action<double>? Scaled;

    readonly Border shadow = new(), card = new(), glow = new();
    readonly TextBlock title = new();
    readonly ContentControl body = new();
    readonly StackPanel stack = new();
    readonly DockPanel header = new();
    readonly StackPanel buttons = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
    readonly Dictionary<int, double> heights = new();  // height needed at each scale
    readonly DropShadowEffect depth = new() { Direction = 270, ShadowDepth = 1, BlurRadius = 6, Opacity = 0.3, Color = Colors.Black };
    string key = "";
    bool updating;  // true while Show() sets the switch (not a click)
    bool? active;
    double column = BaseColumn;

    public double Scale { get; private set; }

    public ShiftCard()
    {
        // A soft shadow (on its own layer, so the text stays sharp), the card, and the purple-pink edge when on.
        shadow.Effect = depth;
        shadow.SetResourceReference(Border.BackgroundProperty, "PsCardBack");
        card.BorderThickness = new Thickness(1);
        card.SetResourceReference(Border.BackgroundProperty, "PsCardBack");
        card.SetResourceReference(Border.BorderBrushProperty, "PsCardBorder");
        glow.BorderThickness = new Thickness(1.5);
        glow.BorderBrush = Theme.Gradient;
        glow.Opacity = 0;
        glow.IsHitTestVisible = false;
        stack.HorizontalAlignment = HorizontalAlignment.Center;
        stack.VerticalAlignment = VerticalAlignment.Top;
        Children.Add(shadow);
        Children.Add(card);
        Children.Add(glow);
        Children.Add(stack);
        Theme.Changed += UpdateShadow;
        UpdateShadow();
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
            AutomationProperties.SetName(this, value);
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
        title.FontWeight = FontWeights.SemiBold;
        title.VerticalAlignment = VerticalAlignment.Center;
        title.SetResourceReference(TextBlock.ForegroundProperty, "PsText");
        Switch.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetAutomationId(Switch, key + "Switch");
        // Checked/Unchecked (not Click), so screen readers and the UI checks can switch it too.
        Switch.Checked += (_, _) => { if (!updating) Toggled?.Invoke(true); };
        Switch.Unchecked += (_, _) => { if (!updating) Toggled?.Invoke(false); };
        header.LastChildFill = true;
        DockPanel.SetDock(Switch, Dock.Right);
        header.Children.Add(Switch);
        header.Children.Add(title);
        stack.Children.Add(header);

        Amount = new AmountBox(key);
        Amount.Committed += v => AmountChosen?.Invoke(v);
        stack.Children.Add(Amount);

        // Glyphs in the icon's middle color. No keyboard shortcuts: they'd catch a typed "-" or "0".
        Setup(Minus, "−", "Lower", "Down 1", "Minus", () => PitchShift.Amount.Step(Amount.Value, -1));
        Setup(Zero, "0", "Back to 0", "Back to 0", "Zero", () => 0);
        Setup(Plus, "+", "Higher", "Up 1", "Plus", () => PitchShift.Amount.Step(Amount.Value, +1));
        buttons.Children.Add(Minus);
        buttons.Children.Add(Zero);
        buttons.Children.Add(Plus);
        stack.Children.Add(buttons);

        body.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        body.Focusable = false;
        stack.Children.Add(body);
        Apply(1);
    }

    void Setup(Button button, string glyph, string name, string tip, string id, Func<double> next)
    {
        var text = new TextBlock
        {
            Text = glyph,
            FontWeight = glyph == "0" ? FontWeights.SemiBold : FontWeights.Normal,
            Foreground = Theme.MidBrush,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        button.Content = text;
        button.Padding = new Thickness(0);
        button.HorizontalContentAlignment = HorizontalAlignment.Center;
        button.VerticalContentAlignment = VerticalAlignment.Center;
        button.ToolTip = tip;
        button.IsEnabledChanged += (_, _) => text.Opacity = button.IsEnabled ? 1 : 0.35;
        AutomationProperties.SetName(button, name);
        AutomationProperties.SetAutomationId(button, key + id);
        button.Click += (_, _) =>
        {
            if (Amount.IsEditing) Amount.Finish(apply: true);  // keeps what was typed, then changes it
            var value = next();
            Amount.Value = value;
            AmountChosen?.Invoke(value);
        };
    }

    // ---------- Sizes ----------

    // Regular controls in a small window, large ones once everything is 1.3 times bigger.
    public static bool Large(double s) => s >= 1.3;
    public static double ControlHeight(double s) => Large(s) ? 38 : 32;
    public static double ButtonHeight(double s) => Large(s) ? 36 : 30;
    public static double ControlFont(double s) => Large(s) ? 15 : 14;

    // Sizes everything for a scale (1 = smallest window) and clears the extra spacing from Spread.
    public void Apply(double s)
    {
        if (s != Scale)
        {
            Scale = s;
            title.FontSize = 14 + (s - 1) * 2.5;
            Switch.Size = Large(s) ? new Size(46, 26) : new Size(40, 22);
            foreach (var b in new[] { Minus, Zero, Plus })
            {
                b.Width = Math.Round(48 * s);
                b.Height = ButtonHeight(s);
                b.FontSize = ControlFont(s);
                ((TextBlock)b.Content).FontSize = (b == Zero ? 0 : 4) + ControlFont(s);
            }
            Zero.Margin = new Thickness(Math.Round(8 * s), 0, Math.Round(8 * s), 0);
            var r = 12 + 5 * (Math.Max(s, 1) - 1);
            shadow.CornerRadius = card.CornerRadius = glow.CornerRadius = new CornerRadius(r);
            stack.Margin = new Thickness(0, Math.Round(14 * s), 0, Math.Round(16 * s));
            buttons.Margin = new Thickness(0, Math.Round(8 * s), 0, 0);
            Scaled?.Invoke(s);
        }
        Spread(0);
    }

    // Fits the rows to the card's width (in a very wide card they stop growing and stay centered).
    public void Place(double width)
    {
        column = Math.Round(Math.Min(width - 34 * Scale, BaseColumn * Scale * 1.35));
        stack.Width = column;
    }

    // Extra height first makes the number bigger (while the widest number, "−23.75", still fits), then the rest
    // goes above the number and below the − 0 + buttons, so a tall card stays balanced.
    public void Spread(double extra)
    {
        var baseSize = 52 * Scale;
        Amount.SetFontSize(baseSize);
        var baseHeight = Amount.Height;
        Amount.SetFontSize(Math.Max(baseSize, Math.Min(Math.Min(baseSize + extra * 0.4, baseSize * 1.5), column / AmountBox.WidestPerPoint(this))));
        var left = Math.Max(0, extra - (Amount.Height - baseHeight));
        Amount.Margin = new Thickness(0, Math.Round(4 * Scale + left / 2), 0, 0);
        body.Margin = new Thickness(0, Math.Round(16 * Scale + left / 2), 0, 0);
    }

    // The height the card needs at a scale (leaves the card sized for that scale).
    public double NeededHeight(double s, double width)
    {
        var k = (int)Math.Round(s * 100);
        if (heights.TryGetValue(k, out var h)) return h;
        Apply(s);
        Place(width);
        stack.Measure(new Size(column, double.PositiveInfinity));
        h = Math.Ceiling(stack.DesiredSize.Height);
        heights[k] = h;
        return h;
    }

    // Call when a row is shown or hidden.
    public void ForgetHeights() => heights.Clear();

    // ---------- State ----------

    // Updates the number and buttons. `active` = the card is on (and can work); `waiting` = on, but the chosen
    // apps aren't making sound, so just the number is paler.
    public void Show(bool on, double value, bool active, bool waiting)
    {
        if (Switch.IsChecked != on)
        {
            updating = true;
            Switch.IsChecked = on;
            updating = false;
        }
        if (!Amount.IsEditing) Amount.Value = value;
        if (active != this.active)
        {
            // Contents fade between bright and dim; the colored edge fades in or out.
            if (this.active is not null)
            {
                Motion.Crossfade(buttons, 0.25);
                if (body.Content is FrameworkElement rows) Motion.Crossfade(rows, 0.25);
            }
            this.active = active;
            Motion.To(glow, OpacityProperty, active ? 0.55 : 0, IsVisible ? 0.25 : 0);
        }
        Amount.IsEnabled = active;
        Amount.Strength = active ? (waiting ? 0.5 : 1) : 0.4;
        Minus.IsEnabled = active && value > PitchShift.Amount.Min;
        Plus.IsEnabled = active && value < PitchShift.Amount.Max;
        Zero.IsEnabled = active && value != 0;
    }

    void UpdateShadow()
    {
        depth.Opacity = Theme.IsDark ? 0.35 : 0.09;
        depth.BlurRadius = Theme.IsDark ? 6 : 5;
    }
}
