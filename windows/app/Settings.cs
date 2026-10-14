using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PitchShift;

// One app ticked in the "What you hear" picker.
public sealed class HearApp
{
    public string Exe { get; set; } = "";   // full program path, like C:\...\Spotify.exe
    public string Name { get; set; } = "";  // the name shown in the picker
}

// Everything the window remembers, saved in %APPDATA%\Pitch Shift\settings.json.
public sealed class Settings
{
    public bool HearOn { get; set; } = true;
    public bool HearAll { get; set; } = true;   // All sound (otherwise the ticked apps)
    public List<HearApp> HearApps { get; set; } = new();
    public double HearSteps { get; set; } = 2;

    public bool VoiceOn { get; set; }
    public double VoiceSteps { get; set; } = 3;
    public bool VoiceNatural { get; set; } = true;  // Natural (true) or Cartoon (false)
    public string VoiceMic { get; set; } = "";       // microphone id; empty = Windows' default

    public double? WindowLeft { get; set; }
    public double? WindowTop { get; set; }
    public double? WindowWidth { get; set; }   // the area inside the window, without the title bar
    public double? WindowHeight { get; set; }
    public bool TrayTipShown { get; set; }

    static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
        NumberHandling = JsonNumberHandling.AllowReadingFromString,
    };

    public static string DefaultPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Pitch Shift", "settings.json");

    // Reads the settings. A missing or broken file gives the defaults.
    public static Settings Load(string path)
    {
        Settings? s = null;
        try
        {
            if (File.Exists(path)) s = JsonSerializer.Deserialize<Settings>(File.ReadAllText(path), Options);
        }
        catch (Exception)
        {
            s = null;
        }
        return (s ?? new Settings()).Cleaned();
    }

    // Writes the settings (to a temporary file first, so a crash can't leave half a file).
    public void Save(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var temp = path + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(Cleaned(), Options));
        File.Move(temp, path, overwrite: true);
    }

    // Fixes values that are out of range or missing.
    public Settings Cleaned()
    {
        HearSteps = Amount.Clean(HearSteps);
        VoiceSteps = Amount.Clean(VoiceSteps);
        VoiceMic ??= "";
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        HearApps = (HearApps ?? new())
            .Where(a => a is not null && !string.IsNullOrWhiteSpace(a.Exe) && seen.Add(a.Exe))
            .Select(a => new HearApp { Exe = a.Exe, Name = string.IsNullOrWhiteSpace(a.Name) ? NameFromPath(a.Exe) : a.Name })
            .ToList();
        if (WindowLeft is double l && !double.IsFinite(l)) WindowLeft = null;
        if (WindowTop is double t && !double.IsFinite(t)) WindowTop = null;
        if (WindowWidth is double w && (!double.IsFinite(w) || w < 100)) WindowWidth = null;
        if (WindowHeight is double h && (!double.IsFinite(h) || h < 100)) WindowHeight = null;
        return this;
    }

    // Clicking an app in the picker ticks or unticks it. Coming from "All sound" starts a new list.
    public void ToggleApp(string exe, string name)
    {
        if (HearAll)
        {
            HearAll = false;
            HearApps.Clear();
        }
        var i = HearApps.FindIndex(a => string.Equals(a.Exe, exe, StringComparison.OrdinalIgnoreCase));
        if (i >= 0) HearApps.RemoveAt(i);
        else HearApps.Add(new HearApp { Exe = exe, Name = string.IsNullOrWhiteSpace(name) ? NameFromPath(exe) : name });
    }

    // Clicking "All sound".
    public void ChooseAll()
    {
        HearAll = true;
        HearApps.Clear();
    }

    public bool IsTicked(string exe) =>
        !HearAll && HearApps.Any(a => string.Equals(a.Exe, exe, StringComparison.OrdinalIgnoreCase));

    // "C:\...\Spotify.exe" -> "Spotify"
    public static string NameFromPath(string exe)
    {
        var name = exe;
        var slash = Math.Max(name.LastIndexOf('\\'), name.LastIndexOf('/'));
        if (slash >= 0) name = name[(slash + 1)..];
        if (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) name = name[..^4];
        return name;
    }
}
