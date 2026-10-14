# Pitch Shift for Windows (beta)

Work in progress. This folder holds the Windows version of Pitch Shift. It is built and tested
only on GitHub's Windows computers (see `.github/workflows/windows.yml`), on both x64 and ARM64.

## Folders

- `engine/dsp/` – the sound math (Rubber Band pitch shifting, tone measuring, WAV files). No Windows code, so its tests also run on a Mac.
- `engine/win/` – Windows sound: devices, app recording ("process loopback"), playing, app volumes.
- `engine/api/` – the small C interface the window app calls (`PitchShiftEngine.dll`).
- `tool/` – `PitchShiftTool.exe`: setup, repair and test commands (`diag`, `tonegen`, `probe`, `restore`, `selftest`).
- `tests/` – tests for the sound math.
- `app/` – the window (C# / WPF).
- `ci/` – scripts used only by the GitHub checks (installing the virtual cable, taking pictures).

## Building

Windows (Visual Studio 2022 or newer, CMake, .NET 10 SDK):

```
cmake -S windows -B build -A x64
cmake --build build --config Release
ctest --test-dir build -C Release
dotnet publish windows/app/PitchShift.csproj -c Release -r win-x64 -p:EngineDir=%CD%\build\out\Release -o dist
```

Mac (sound math tests only; needs `brew install cmake rubberband`):

```
cmake -S windows -B build-mac && cmake --build build-mac && ./build-mac/dsp_tests
```

## Credits

- [Rubber Band Library](https://breakfastquay.com/rubberband/) (GPL) does the pitch shifting.
- [VB-CABLE](https://vb-audio.com/Cable/) by VB-Audio (donationware) provides the virtual microphone.

License: GPL-3.0-or-later (same as the rest of Pitch Shift).
