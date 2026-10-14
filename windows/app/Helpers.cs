using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace PitchShift;

// A small log for problems (%LOCALAPPDATA%\Pitch Shift\app-log.txt). The diagnostics report includes it.
static class Log
{
    public static string PathName => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Pitch Shift", "app-log.txt");

    static readonly object Gate = new();

    public static void Write(object? what)
    {
        if (what is null) return;
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(System.IO.Path.GetDirectoryName(PathName)!);
                var info = new FileInfo(PathName);
                if (info.Exists && info.Length > 256 * 1024) info.Delete();  // keep it small
                File.AppendAllText(PathName, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {what}{Environment.NewLine}");
            }
        }
        catch (Exception)
        {
        }
    }
}

// Program icons for the app picker (16 px).
static class AppIcons
{
    static readonly Dictionary<string, ImageSource?> Cache = new(StringComparer.OrdinalIgnoreCase);

    public static ImageSource? For(string exe)
    {
        if (string.IsNullOrEmpty(exe)) return null;
        if (Cache.TryGetValue(exe, out var cached)) return cached;
        ImageSource? image = null;
        try
        {
            if (File.Exists(exe))
            {
                var info = new SHFILEINFO();
                var result = SHGetFileInfo(exe, 0, ref info, (uint)Marshal.SizeOf<SHFILEINFO>(), SHGFI_ICON | SHGFI_SMALLICON);
                if (result != IntPtr.Zero && info.hIcon != IntPtr.Zero)
                {
                    var bitmap = Imaging.CreateBitmapSourceFromHIcon(info.hIcon, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                    bitmap.Freeze();
                    image = bitmap;
                    DestroyIcon(info.hIcon);
                }
            }
        }
        catch (Exception e)
        {
            Log.Write(e);
        }
        Cache[exe] = image;
        return image;
    }

    const uint SHGFI_ICON = 0x100, SHGFI_SMALLICON = 0x1;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SHFILEINFO
    {
        public IntPtr hIcon;
        public int iIcon;
        public uint dwAttributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr SHGetFileInfo(string path, uint attributes, ref SHFILEINFO info, uint size, uint flags);

    [DllImport("user32.dll")]
    static extern bool DestroyIcon(IntPtr icon);
}

// Command-line options, like "--preview hear-on --screenshot shot.png".
sealed class Args(string[] items)
{
    public bool Has(string flag) => items.Any(a => string.Equals(a, flag, StringComparison.OrdinalIgnoreCase));

    public string? Get(string flag)
    {
        for (var i = 0; i + 1 < items.Length; i++)
            if (string.Equals(items[i], flag, StringComparison.OrdinalIgnoreCase)) return items[i + 1];
        return null;
    }
}
