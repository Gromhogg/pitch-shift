using System.Windows;

namespace PitchShift;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var window = new MainWindow();
        // "--screenshot file.png": draw the window into a picture and quit (used by the GitHub checks).
        var i = Array.IndexOf(e.Args, "--screenshot");
        if (i >= 0 && i + 1 < e.Args.Length) window.ScreenshotPath = e.Args[i + 1];
        window.Show();
    }
}
