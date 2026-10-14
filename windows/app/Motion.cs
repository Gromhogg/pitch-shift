using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;

namespace PitchShift;

// Short animations. When Windows' "Animation effects" is off (Settings → Accessibility → Visual effects),
// nothing slides or pulses; things only fade.
static class Motion
{
    public static bool Off { get; set; }  // forced off (for pictures)

    // Slides and pulses are allowed.
    public static bool Moves => !Off && SystemParameters.ClientAreaAnimation;

    public static readonly IEasingFunction EaseInOut = Frozen(new CubicEase { EasingMode = EasingMode.EaseInOut });
    public static readonly IEasingFunction EaseOut = Frozen(new CubicEase { EasingMode = EasingMode.EaseOut });

    static IEasingFunction Frozen(EasingFunctionBase e)
    {
        e.Freeze();
        return e;
    }

    // Animates a number property from where it is now to `to`. Without a window on screen, it just jumps.
    public static void To(IAnimatable target, DependencyProperty property, double to, double seconds, IEasingFunction? ease = null)
    {
        if (Off || seconds <= 0)
        {
            target.BeginAnimation(property, null);
            ((DependencyObject)target).SetValue(property, to);
            return;
        }
        var animation = new DoubleAnimation(to, TimeSpan.FromSeconds(seconds)) { EasingFunction = ease ?? EaseInOut };
        target.BeginAnimation(property, animation, HandoffBehavior.SnapshotAndReplace);
    }

    // Fades from how an element looks now to how it looks after the changes made right after this call.
    public static void Crossfade(FrameworkElement? element, double seconds = 0.2)
    {
        if (Off || element is null || !element.IsVisible || element.ActualWidth < 1 || element.ActualHeight < 1) return;
        var layer = AdornerLayer.GetAdornerLayer(element);
        if (layer is null) return;
        try
        {
            var dpi = VisualTreeHelper.GetDpi(element);
            var picture = new RenderTargetBitmap(
                Math.Max(1, (int)Math.Ceiling(element.ActualWidth * dpi.DpiScaleX)),
                Math.Max(1, (int)Math.Ceiling(element.ActualHeight * dpi.DpiScaleY)),
                dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
            var visual = new DrawingVisual();
            using (var dc = visual.RenderOpen())
                dc.DrawRectangle(new VisualBrush(element) { Stretch = Stretch.None, AlignmentX = AlignmentX.Left, AlignmentY = AlignmentY.Top },
                    null, new Rect(0, 0, element.ActualWidth, element.ActualHeight));
            picture.Render(visual);
            picture.Freeze();
            var ghost = new Ghost(element, picture);
            layer.Add(ghost);
            var fade = new DoubleAnimation(1, 0, TimeSpan.FromSeconds(seconds)) { EasingFunction = EaseInOut };
            fade.Completed += (_, _) => layer.Remove(ghost);
            ghost.BeginAnimation(UIElement.OpacityProperty, fade);
        }
        catch (Exception e)
        {
            Log.Write(e);
        }
    }

    // A picture of how an element looked a moment ago, drawn on top of it while it fades away.
    sealed class Ghost(UIElement element, ImageSource picture) : Adorner(element)
    {
        protected override void OnRender(DrawingContext dc) =>
            dc.DrawImage(picture, new Rect(0, 0, ((FrameworkElement)AdornedElement).ActualWidth, ((FrameworkElement)AdornedElement).ActualHeight));

        protected override HitTestResult? HitTestCore(PointHitTestParameters hitTestParameters) => null;
    }
}
