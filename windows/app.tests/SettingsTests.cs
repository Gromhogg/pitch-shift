using Xunit;

namespace PitchShift.Tests;

public sealed class SettingsTests : IDisposable
{
    readonly string folder = Path.Combine(Path.GetTempPath(), "ps-tests-" + Guid.NewGuid().ToString("N"));
    string FilePath => Path.Combine(folder, "Pitch Shift", "settings.json");

    public void Dispose()
    {
        if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true);
    }

    [Fact]
    public void MissingFileGivesDefaults()
    {
        var s = Settings.Load(FilePath);
        Assert.True(s.HearOn);
        Assert.True(s.HearAll);
        Assert.Empty(s.HearApps);
        Assert.Equal(2, s.HearSteps);
        Assert.False(s.VoiceOn);
        Assert.Equal(3, s.VoiceSteps);
        Assert.True(s.VoiceNatural);
        Assert.Equal("", s.VoiceMic);
        Assert.Null(s.WindowLeft);
    }

    [Fact]
    public void SaveThenLoadKeepsEverything()
    {
        var s = new Settings
        {
            HearOn = false,
            HearAll = false,
            HearSteps = -1.25,
            VoiceOn = true,
            VoiceSteps = 7.5,
            VoiceNatural = false,
            VoiceMic = "{0.0.1.00000000}.{abc}",
            WindowLeft = 120,
            WindowTop = 80,
        };
        s.HearApps.Add(new HearApp { Exe = @"C:\Program Files\Spotify\Spotify.exe", Name = "Spotify" });
        s.HearApps.Add(new HearApp { Exe = @"C:\Games\osu!.exe", Name = "osu!" });
        s.Save(FilePath);

        var back = Settings.Load(FilePath);
        Assert.False(back.HearOn);
        Assert.False(back.HearAll);
        Assert.Equal(-1.25, back.HearSteps);
        Assert.True(back.VoiceOn);
        Assert.Equal(7.5, back.VoiceSteps);
        Assert.False(back.VoiceNatural);
        Assert.Equal("{0.0.1.00000000}.{abc}", back.VoiceMic);
        Assert.Equal(120, back.WindowLeft);
        Assert.Equal(80, back.WindowTop);
        Assert.Equal(new[] { "Spotify", "osu!" }, back.HearApps.Select(a => a.Name));
        Assert.False(File.Exists(FilePath + ".tmp"));
    }

    [Fact]
    public void FileUsesPlainNames()
    {
        new Settings { HearSteps = 4 }.Save(FilePath);
        var text = File.ReadAllText(FilePath);
        Assert.Contains("\"hearSteps\": 4", text);
        Assert.Contains("\"voiceNatural\": true", text);
        Assert.DoesNotContain("windowLeft", text);  // not saved until the window moves
    }

    [Theory]
    [InlineData("")]
    [InlineData("not json")]
    [InlineData("[1,2,3]")]
    [InlineData("{\"hearSteps\": \"loud\"}")]
    public void BrokenFileGivesDefaults(string content)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        File.WriteAllText(FilePath, content);
        var s = Settings.Load(FilePath);
        Assert.Equal(2, s.HearSteps);
        Assert.True(s.HearAll);
    }

    [Fact]
    public void OutOfRangeValuesAreFixed()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        File.WriteAllText(FilePath, """
            {
              "hearSteps": 99,
              "voiceSteps": -1.23456,
              "voiceMic": null,
              "hearApps": [ {"exe": "C:\\a\\Spotify.exe"}, {"exe": "C:\\A\\SPOTIFY.EXE", "name": "x"}, {"exe": ""}, null ],
            }
            """);
        var s = Settings.Load(FilePath);
        Assert.Equal(24, s.HearSteps);
        Assert.Equal(-1.23, s.VoiceSteps);
        Assert.Equal("", s.VoiceMic);
        var app = Assert.Single(s.HearApps);
        Assert.Equal("Spotify", app.Name);  // name made from the file name
    }

    [Fact]
    public void OlderFileWithMissingFieldsKeepsDefaults()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        File.WriteAllText(FilePath, "{\"voiceOn\": true}");
        var s = Settings.Load(FilePath);
        Assert.True(s.VoiceOn);
        Assert.True(s.HearOn);
        Assert.Equal(3, s.VoiceSteps);
    }

    [Fact]
    public void TickingApps()
    {
        var s = new Settings();  // starts on All sound
        s.ToggleApp(@"C:\x\Spotify.exe", "Spotify");
        Assert.False(s.HearAll);
        Assert.True(s.IsTicked(@"c:\X\spotify.exe"));

        s.ToggleApp(@"C:\x\chrome.exe", "Google Chrome");
        Assert.Equal(2, s.HearApps.Count);

        s.ToggleApp(@"C:\X\SPOTIFY.EXE", "Spotify");  // untick (any letter case)
        Assert.Equal("Google Chrome", Assert.Single(s.HearApps).Name);

        s.ChooseAll();
        Assert.True(s.HearAll);
        Assert.Empty(s.HearApps);
        Assert.False(s.IsTicked(@"C:\x\chrome.exe"));

        s.ToggleApp(@"C:\x\chrome.exe", "");  // from All sound: a new list with just this app
        Assert.Equal("chrome", Assert.Single(s.HearApps).Name);
    }

    [Theory]
    [InlineData(@"C:\Program Files\Spotify\Spotify.exe", "Spotify")]
    [InlineData("osu!.exe", "osu!")]
    [InlineData(@"C:\tools\player", "player")]
    public void NameFromPath(string exe, string name) => Assert.Equal(name, Settings.NameFromPath(exe));
}
