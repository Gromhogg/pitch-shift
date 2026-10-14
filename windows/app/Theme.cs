using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Microsoft.Win32;

namespace PitchShift;

// Colors. Purple to pink from the app icon; the rest follows Windows' light or dark mode.
static class Theme
{
    public static readonly Color Purple = Color.FromRgb(115, 64, 242);   // rgb(0.45, 0.25, 0.95)
    public static readonly Color Pink = Color.FromRgb(242, 77, 153);     // rgb(0.95, 0.30, 0.60)
    public static readonly Color Mid = Color.FromRgb(179, 70, 198);      // halfway between them

    public static readonly Brush PurpleBrush = Frozen(new SolidColorBrush(Purple));
    public static readonly Brush MidBrush = Frozen(new SolidColorBrush(Mid));
    public static readonly Brush Gradient = Frozen(new LinearGradientBrush(Purple, Pink, new Point(0, 0.5), new Point(1, 0.5)));
    public static readonly Brush Red = Frozen(new SolidColorBrush(Color.FromRgb(232, 60, 60)));
    public static readonly Brush Green = Frozen(new SolidColorBrush(Color.FromRgb(52, 199, 89)));

    // null = follow Windows; true/false = forced dark/light (for screenshots).
    public static bool? Forced { get; set; }
    public static bool IsDark { get; private set; }

    static T Frozen<T>(T brush) where T : Freezable
    {
        brush.Freeze();
        return brush;
    }

    // Windows' "app mode": dark or light.
    public static bool SystemIsDark()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int light && light == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }

    // Puts the right colors into the app's resources (the window uses them by name).
    public static void Apply(Application app)
    {
        IsDark = Forced ?? SystemIsDark();
#pragma warning disable WPF0001
        if (Forced is bool dark) app.ThemeMode = dark ? ThemeMode.Dark : ThemeMode.Light;
#pragma warning restore WPF0001
        void Set(string key, Color light, Color darkColor) =>
            app.Resources[key] = Frozen(new SolidColorBrush(IsDark ? darkColor : light));
        Set("PsWindowBack", Color.FromRgb(243, 243, 243), Color.FromRgb(32, 32, 32));
        Set("PsCardBack", Color.FromRgb(255, 255, 255), Color.FromRgb(43, 43, 43));
        Set("PsCardBorder", Color.FromRgb(229, 229, 229), Color.FromRgb(58, 58, 58));
        Set("PsText", Color.FromRgb(27, 27, 27), Color.FromRgb(255, 255, 255));
        Set("PsTextSecondary", Color.FromRgb(110, 110, 110), Color.FromRgb(160, 160, 160));
        Set("PsTrackOff", Color.FromRgb(200, 200, 200), Color.FromRgb(90, 90, 90));
        Set("PsSegmentBack", Color.FromRgb(234, 234, 234), Color.FromRgb(58, 58, 58));
        Set("PsSegmentHover", Color.FromRgb(222, 222, 222), Color.FromRgb(70, 70, 70));
        Set("PsDotOff", Color.FromRgb(180, 180, 180), Color.FromRgb(110, 110, 110));
        foreach (Window w in app.Windows) DarkTitleBar(w);
    }

    // Makes the title bar match (dark title bar in dark mode).
    public static void DarkTitleBar(Window window)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero) return;
        int on = IsDark ? 1 : 0;
        DwmSetWindowAttribute(hwnd, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, ref on, sizeof(int));
    }

    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
}
