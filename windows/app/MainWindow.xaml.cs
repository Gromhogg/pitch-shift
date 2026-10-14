using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace PitchShift;

public partial class MainWindow : Window
{
    public string? ScreenshotPath { get; set; }

    public MainWindow()
    {
        InitializeComponent();
        Loaded += (_, _) => EngineText.Text = $"Engine {Engine.Version}";
        ContentRendered += (_, _) =>
        {
            if (ScreenshotPath is null) return;
            // Wait a moment so everything has been drawn, then save a picture and quit.
            var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            timer.Tick += (_, _) =>
            {
                timer.Stop();
                SavePicture(ScreenshotPath);
                Application.Current.Shutdown();
            };
            timer.Start();
        };
    }

    // Draws the window's contents (without the title bar) into a PNG file.
    void SavePicture(string path)
    {
        var content = (FrameworkElement)Content;
        var dpi = VisualTreeHelper.GetDpi(this);
        var bitmap = new RenderTargetBitmap(
            (int)Math.Ceiling(content.ActualWidth * dpi.DpiScaleX),
            (int)Math.Ceiling(content.ActualHeight * dpi.DpiScaleY),
            dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
        // Paint the window background first, so the picture isn't see-through.
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            Brush back = Background is SolidColorBrush { Color.A: 255 } solid ? solid : SystemColors.WindowBrush;
            dc.DrawRectangle(back, null, new Rect(0, 0, content.ActualWidth, content.ActualHeight));
            dc.DrawRectangle(new VisualBrush(content), null, new Rect(0, 0, content.ActualWidth, content.ActualHeight));
        }
        bitmap.Render(visual);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        using var file = File.Create(path);
        encoder.Save(file);
    }
}
