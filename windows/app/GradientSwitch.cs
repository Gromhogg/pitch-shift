using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;

namespace PitchShift;

// An on/off switch in the icon's colors: the track fills with the purple-to-pink gradient when on, grey when off,
// with a white knob that slides (0.18 s) and stretches a little while pressed.
// It's a ToggleButton underneath, so the keyboard (Space) and screen readers work as usual.
sealed class GradientSwitch : ToggleButton
{
    // 0 = off (knob left), 1 = on (knob right). Animated.
    public static readonly DependencyProperty KnobProperty = DependencyProperty.Register(
        nameof(Knob), typeof(double), typeof(GradientSwitch), new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));

    // How wide the knob is: 1 normally, 1.25 while pressed. Animated.
    public static readonly DependencyProperty StretchProperty = DependencyProperty.Register(
        nameof(Stretch), typeof(double), typeof(GradientSwitch), new FrameworkPropertyMetadata(1.0, FrameworkPropertyMetadataOptions.AffectsRender));

    public double Knob
    {
        get => (double)GetValue(KnobProperty);
        set => SetValue(KnobProperty, value);
    }

    public double Stretch
    {
        get => (double)GetValue(StretchProperty);
        set => SetValue(StretchProperty, value);
    }

    public GradientSwitch()
    {
        Template = new ControlTemplate(typeof(GradientSwitch));  // draws itself (OnRender)
        Background = Brushes.Transparent;
        FocusVisualStyle = null;
        Cursor = Cursors.Hand;
        Size = new Size(40, 22);
        Checked += (_, _) => Slide();
        Unchecked += (_, _) => Slide();
        IsEnabledChanged += (_, _) => InvalidateVisual();
        IsKeyboardFocusedChanged += (_, _) => InvalidateVisual();
        Theme.Changed += InvalidateVisual;
    }

    public Size Size
    {
        get => new(Width, Height);
        set
        {
            Width = value.Width;
            Height = value.Height;
        }
    }

    void Slide()
    {
        var target = IsChecked == true ? 1.0 : 0.0;
        if (IsLoaded && IsVisible && Motion.Moves) Motion.To(this, KnobProperty, target, 0.18);
        else Motion.To(this, KnobProperty, target, IsLoaded && IsVisible ? 0.12 : 0);
    }

    protected override void OnIsPressedChanged(DependencyPropertyChangedEventArgs e)
    {
        base.OnIsPressedChanged(e);
        Motion.To(this, StretchProperty, IsPressed && Motion.Moves ? 1.25 : 1.0, 0.12);
    }

    protected override void OnRender(DrawingContext dc)
    {
        var w = ActualWidth;
        var h = ActualHeight;
        if (w <= 0 || h <= 0) return;
        var alpha = IsEnabled ? 1.0 : 0.4;
        var track = new Rect(1, 1, w - 2, h - 2);
        var r = track.Height / 2;
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(0, 0, w, h));  // whole area clickable
        dc.PushOpacity(alpha);
        dc.DrawRoundedRectangle((Brush)FindResource("PsTrackOff"), null, track, r, r);
        if (Knob > 0)
        {
            dc.PushOpacity(Knob);
            dc.DrawRoundedRectangle(Theme.Gradient, null, track, r, r);
            dc.Pop();
        }
        dc.Pop();

        // The knob, with a soft shadow under it.
        var size = track.Height - 4;
        var knobWidth = size * Stretch;
        var x = track.Left + 2 + Knob * (track.Width - knobWidth - 4);
        var knob = new Rect(x, track.Top + 2, knobWidth, size);
        var shadow = knob;
        shadow.Offset(0, 1);
        shadow.Inflate(0.5, 0.5);
        dc.DrawRoundedRectangle(Shadow, null, shadow, shadow.Height / 2, shadow.Height / 2);
        dc.PushOpacity(IsEnabled ? 1 : 0.7);
        dc.DrawRoundedRectangle(Brushes.White, null, knob, size / 2, size / 2);
        dc.Pop();

        if (IsKeyboardFocused)
        {
            var ring = new Rect(-1.5, -1.5, w + 3, h + 3);
            dc.DrawRoundedRectangle(null, new Pen((Brush)FindResource("PsText"), 2), ring, ring.Height / 2, ring.Height / 2);
        }
    }

    static readonly Brush Shadow = MakeShadow();

    static Brush MakeShadow()
    {
        var b = new SolidColorBrush(Color.FromArgb(60, 0, 0, 0));
        b.Freeze();
        return b;
    }
}
