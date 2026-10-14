using System.Media;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;

namespace PitchShift;

// The big number. Shows "+2" / "−1.5" / "0" in the icon's colors. Click it to type any amount from −24 to 24:
// Enter applies, Esc cancels. Typing "2,5", "−1.25" or "+3" all work.
sealed class AmountBox : Grid
{
    public event Action<double>? Committed;

    readonly Button display = new();
    readonly TextBlock plainText = new();     // the number in the normal text color
    readonly TextBlock gradientText = new();  // the same number painted with the purple-to-pink gradient
    readonly TextBox editor = new();
    double value;
    double strength = 1;
    bool editing;

    public AmountBox(string key)
    {
        Height = 72;
        var font = new FontFamily("Segoe UI Variable Display, Segoe UI");
        foreach (var t in new[] { plainText, gradientText })
        {
            t.FontFamily = font;
            t.FontSize = 52;
            t.FontWeight = FontWeights.Bold;
            t.HorizontalAlignment = HorizontalAlignment.Center;
            t.VerticalAlignment = VerticalAlignment.Center;
            Typography.SetNumeralAlignment(t, FontNumeralAlignment.Tabular);
        }
        plainText.SetResourceReference(TextBlock.ForegroundProperty, "PsText");
        gradientText.Foreground = Theme.Gradient;
        var both = new Grid();
        both.Children.Add(plainText);
        both.Children.Add(gradientText);

        display.Style = (Style)Application.Current.FindResource("PsBareButton");
        display.Content = both;
        display.HorizontalAlignment = HorizontalAlignment.Center;
        display.Padding = new Thickness(12, 0, 12, 0);
        display.Click += (_, _) => BeginEditing();
        AutomationProperties.SetAutomationId(display, key + "Amount");
        Children.Add(display);

        editor.Style = (Style)Application.Current.FindResource("PsBareTextBox");
        editor.FontFamily = font;
        editor.FontSize = 52;
        editor.FontWeight = FontWeights.Bold;
        editor.Background = Brushes.Transparent;
        editor.TextAlignment = TextAlignment.Center;
        editor.HorizontalAlignment = HorizontalAlignment.Stretch;
        editor.VerticalAlignment = VerticalAlignment.Center;
        editor.CaretBrush = Theme.MidBrush;
        editor.SetResourceReference(Control.ForegroundProperty, "PsText");
        editor.Visibility = Visibility.Collapsed;
        editor.PreviewKeyDown += OnEditorKey;
        editor.LostKeyboardFocus += (_, _) => { if (editing) Finish(apply: true); };
        AutomationProperties.SetAutomationId(editor, key + "AmountBox");
        AutomationProperties.SetName(editor, "Amount");
        Children.Add(editor);
        Show();
    }

    public bool IsEditing => editing;

    public double Value
    {
        get => value;
        set
        {
            this.value = Amount.Clean(value);
            if (!editing) Show();
        }
    }

    // 1 = full colors; lower = lighter (the chosen apps aren't running).
    public double Strength
    {
        get => strength;
        set
        {
            strength = value;
            Show();
        }
    }

    public string Hint
    {
        set => display.ToolTip = string.IsNullOrEmpty(value) ? null : value;
    }

    void Show()
    {
        var text = Amount.Display(value);
        plainText.Text = gradientText.Text = text;
        gradientText.Opacity = strength;
        plainText.Opacity = strength >= 1 ? 0 : 1;  // under the gradient only when it's see-through
        AutomationProperties.SetName(display, text);
    }

    public void BeginEditing(string? startText = null)
    {
        if (editing || !IsEnabled) return;
        editing = true;
        editor.Text = startText ?? Amount.Plain(value);
        display.Visibility = Visibility.Hidden;
        editor.Visibility = Visibility.Visible;
        var window = Window.GetWindow(this);
        if (window is not null) window.PreviewMouseDown += OnWindowMouseDown;
        editor.Focus();
        Keyboard.Focus(editor);
        if (startText is null) editor.SelectAll();
        else editor.CaretIndex = editor.Text.Length;
    }

    void OnEditorKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            Finish(apply: true);
            e.Handled = true;
        }
        else if (e.Key == Key.Escape)
        {
            Finish(apply: false);
            e.Handled = true;
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
        if (apply)
        {
            var number = Amount.Parse(typed);
            if (number is double n)
            {
                value = n;
                Show();
                Committed?.Invoke(n);
                return;
            }
            SystemSounds.Beep.Play();
        }
        Show();
    }
}
