using System.Globalization;
using System.Media;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace PitchShift;

// The big number. Shows "+2" / "−1.5" / "0" in the icon's colors. Click it to type any amount from −24 to 24:
// Enter applies, Esc cancels, ↑ ↓ change it by 1 right away. Typing "2,5", "−1.25" or "+3" all work.
// A new number rolls in (up when higher, down when lower). A soft grey shape shows behind it on mouse-over
// and while typing.
sealed class AmountBox : Grid
{
    public event Action<double>? Committed;

    static readonly FontFamily NumberFont = new("Segoe UI Variable Display, Segoe UI");

    readonly Button display = new();
    readonly Grid faces = new();                    // the number (and, while rolling, the old one)
    readonly TextBlock face = new(), oldFace = new();
    readonly TranslateTransform faceMove = new(), oldMove = new();
    readonly Border pill = new();                   // soft shape behind the number
    readonly TextBox editor = new();
    double value;
    double strength = 1;
    double fontSize = 52;
    bool editing;
    bool hovering;

    public AmountBox(string key)
    {
        foreach (var t in new[] { face, oldFace })
        {
            t.FontFamily = NumberFont;
            t.FontWeight = FontWeights.Bold;
            t.Foreground = Theme.Gradient;
            t.HorizontalAlignment = HorizontalAlignment.Center;
            t.VerticalAlignment = VerticalAlignment.Center;
            Typography.SetNumeralAlignment(t, FontNumeralAlignment.Tabular);
            faces.Children.Add(t);
        }
        face.RenderTransform = faceMove;
        oldFace.RenderTransform = oldMove;
        oldFace.Opacity = 0;

        pill.SetResourceReference(Border.BackgroundProperty, "PsPill");
        pill.HorizontalAlignment = HorizontalAlignment.Center;
        pill.VerticalAlignment = VerticalAlignment.Center;
        pill.Opacity = 0;
        pill.IsHitTestVisible = false;
        Children.Add(pill);

        display.Style = (Style)Application.Current.FindResource("PsBareButton");
        display.Content = faces;
        display.HorizontalAlignment = HorizontalAlignment.Center;
        display.Padding = new Thickness(12, 0, 12, 0);
        display.Click += (_, _) => BeginEditing();
        display.MouseEnter += (_, _) => Hover(true);
        display.MouseLeave += (_, _) => Hover(false);
        AutomationProperties.SetAutomationId(display, key + "Amount");
        Children.Add(display);

        editor.Style = (Style)Application.Current.FindResource("PsBareTextBox");
        editor.FontFamily = NumberFont;
        editor.FontWeight = FontWeights.Bold;
        editor.Background = Brushes.Transparent;
        editor.TextAlignment = TextAlignment.Center;
        editor.HorizontalAlignment = HorizontalAlignment.Stretch;
        editor.VerticalAlignment = VerticalAlignment.Center;
        editor.CaretBrush = Theme.MidBrush;
        editor.SetResourceReference(Control.ForegroundProperty, "PsText");
        editor.Visibility = Visibility.Collapsed;
        editor.PreviewKeyDown += OnEditorKey;
        editor.TextChanged += (_, _) => PlacePill();
        editor.LostKeyboardFocus += (_, _) => { if (editing) Finish(apply: true); };
        AutomationProperties.SetAutomationId(editor, key + "AmountBox");
        AutomationProperties.SetName(editor, "Amount");
        Children.Add(editor);

        IsEnabledChanged += (_, _) => { if (!IsEnabled) Hover(false); };
        SetFontSize(52);
        Show(roll: false);
    }

    public bool IsEditing => editing;

    public double Value
    {
        get => value;
        set
        {
            var v = Amount.Clean(value);
            if (v == this.value && face.Text == Amount.Display(v)) return;
            var up = v > this.value;
            this.value = v;
            if (!editing) Show(roll: true, up: up);
        }
    }

    // How strong the number looks: 1 = on, 0.5 = waiting for sound, 0.4 = switched off. Fades over 0.3 s.
    public double Strength
    {
        get => strength;
        set
        {
            if (value == strength) return;
            strength = value;
            Motion.To(faces, OpacityProperty, value, IsVisible ? 0.3 : 0);
        }
    }

    public string Hint
    {
        set => display.ToolTip = string.IsNullOrEmpty(value) ? null : value;
    }

    public double FontSizeNow => fontSize;

    // The number's size in points (grows with the window).
    public void SetFontSize(double size)
    {
        size = Math.Round(size * 2) / 2;
        if (size == fontSize && face.FontSize == size) return;
        fontSize = size;
        face.FontSize = oldFace.FontSize = editor.FontSize = size;
        Height = Math.Round(size * 1.38);
        PlacePill();
    }

    // Width of the widest number ("−23.75") for each point of font size.
    public static double WidestPerPoint(Visual visual)
    {
        var text = new FormattedText("−23.75", CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            new Typeface(NumberFont, FontStyles.Normal, FontWeights.Bold, FontStretches.Normal), 100, Brushes.Black,
            VisualTreeHelper.GetDpi(visual).PixelsPerDip);
        return text.WidthIncludingTrailingWhitespace / 100 + 0.3;  // + room for the side padding
    }

    double TextWidth(string text)
    {
        var formatted = new FormattedText(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            new Typeface(NumberFont, FontStyles.Normal, FontWeights.Bold, FontStretches.Normal), fontSize, Brushes.Black,
            VisualTreeHelper.GetDpi(this).PixelsPerDip);
        return formatted.WidthIncludingTrailingWhitespace;
    }

    // The soft shape behind the number: a bit wider than the number, rounded.
    void PlacePill()
    {
        var text = editing ? editor.Text : face.Text;
        pill.Width = Math.Round(Math.Max(TextWidth(text), fontSize) + fontSize * (editing ? 0.9 : 0.7));
        pill.Height = Math.Round(fontSize * 1.12);
        pill.CornerRadius = new CornerRadius(pill.Height * 0.22);
    }

    public void Hover(bool on)
    {
        hovering = on && IsEnabled;
        if (!editing) Motion.To(pill, OpacityProperty, hovering ? 1 : 0, 0.15);
    }

    // Shows the current number. With `roll`, the old number slides away and fades while the new one comes in.
    void Show(bool roll, bool up = true)
    {
        var text = Amount.Display(value);
        AutomationProperties.SetName(display, text);
        if (!roll || !IsVisible || face.Text == text || face.Text.Length == 0)
        {
            face.Text = text;
            PlacePill();
            return;
        }
        oldFace.Text = face.Text;
        face.Text = text;
        PlacePill();
        var distance = Motion.Moves ? Height * 0.22 * (up ? 1 : -1) : 0;
        Run(oldMove, oldFace, 0, -distance, 1, 0);
        Run(faceMove, face, distance, 0, 0, 1);
    }

    static void Run(TranslateTransform move, TextBlock text, double fromY, double toY, double fromOpacity, double toOpacity)
    {
        var time = TimeSpan.FromSeconds(Motion.Off ? 0.001 : 0.22);
        move.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(fromY, toY, time) { EasingFunction = Motion.EaseOut });
        text.BeginAnimation(OpacityProperty, new DoubleAnimation(fromOpacity, toOpacity, time) { EasingFunction = Motion.EaseOut });
    }

    public void BeginEditing(string? startText = null)
    {
        if (editing || !IsEnabled) return;
        editing = true;
        editor.Text = startText ?? Amount.Plain(value);
        display.Visibility = Visibility.Hidden;
        editor.Visibility = Visibility.Visible;
        PlacePill();
        Motion.To(pill, OpacityProperty, 1, 0.15);
        var window = Window.GetWindow(this);
        if (window is not null) window.PreviewMouseDown += OnWindowMouseDown;
        editor.Focus();
        Keyboard.Focus(editor);
        if (startText is null) editor.SelectAll();
        else editor.CaretIndex = editor.Text.Length;
    }

    void OnEditorKey(object sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Enter:
                Finish(apply: true);
                e.Handled = true;
                break;
            case Key.Escape:
                Finish(apply: false);
                e.Handled = true;
                break;
            case Key.Up:
            case Key.Down:
                // ↑ ↓ change the typed number by 1 and apply it right away.
                var stepped = Amount.Step(Amount.Parse(editor.Text) ?? value, e.Key == Key.Up ? 1 : -1);
                editor.Text = Amount.Plain(stepped);
                editor.SelectAll();
                value = stepped;
                AutomationProperties.SetName(display, Amount.Display(value));
                Committed?.Invoke(stepped);
                e.Handled = true;
                break;
        }
    }

    // A click anywhere outside the box ends typing (like the Mac).
    void OnWindowMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is DependencyObject d && IsInside(d, editor)) return;
        Finish(apply: true);
    }

    static bool IsInside(DependencyObject d, DependencyObject parent)
    {
        for (var p = d; p is not null; p = p is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(p) : LogicalTreeHelper.GetParent(p))
            if (p == parent) return true;
        return false;
    }

    public void Finish(bool apply)
    {
        if (!editing) return;
        editing = false;
        var window = Window.GetWindow(this);
        if (window is not null) window.PreviewMouseDown -= OnWindowMouseDown;
        var typed = editor.Text;
        editor.Visibility = Visibility.Collapsed;
        display.Visibility = Visibility.Visible;
        if (editor.IsKeyboardFocusWithin && window is not null)
        {
            // Give the focus back to the window so typing doesn't go anywhere unexpected.
            FocusManager.SetFocusedElement(window, null);
            Keyboard.ClearFocus();
        }
        Motion.To(pill, OpacityProperty, hovering ? 1 : 0, 0.15);
        var before = face.Text;
        if (apply)
        {
            if (Amount.Parse(typed) is double n)
            {
                var up = n > value;
                value = n;
                // Comes back as the new number, rolling in from the old one.
                face.Text = before;
                Show(roll: true, up: up);
                Committed?.Invoke(n);
                return;
            }
            SystemSounds.Beep.Play();
        }
        Show(roll: Amount.Display(value) != before);
    }
}
