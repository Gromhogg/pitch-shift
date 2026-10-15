# Pitch Shift

Change the pitch of **what you hear** (any app, like Spotify, Apple Music or YouTube) and of **your voice** (as a mic called "Pitch Shift Mic" for Discord, Zoom and others), live. For Mac, and Windows (beta).

## Install on a Mac

**Download (double-click):**

1. Download **[PitchShift.pkg](https://github.com/Gromhogg/pitch-shift/releases/latest/download/PitchShift.pkg)** and double-click it.
2. Your Mac says it can't check the file. Click **Done**.
3. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**. Type your password.
4. Click **Continue**, then **Install**. Pitch Shift opens when it's done.
5. Click **Allow** when your Mac asks about recording audio and using the microphone.

**Or with Terminal** (skips steps 2 and 3): open Terminal, paste this line, and press Return.

```
curl -fsSL https://raw.githubusercontent.com/Gromhogg/pitch-shift/main/install.sh | bash
```

Run either one again any time to update. Works on Macs with Apple silicon or Intel and macOS 14.4 or newer. Nothing else to install: Pitch Shift Mic comes with it.

## Install on Windows (beta)

**Beta:** tested on GitHub's Windows computers, not yet on many real PCs. Needs Windows 11 (x64 or ARM).

Open **PowerShell** (click Start, type `PowerShell`, press Enter), paste this line, and press Enter:

```
irm https://raw.githubusercontent.com/Gromhogg/pitch-shift/main/install.ps1 | iex
```

- Click **Yes** when Windows asks to allow changes.
- If a **VB-Audio** window opens, click **Install Driver**. This adds **Pitch Shift Mic**.

Or download **[PitchShift-Setup.exe](https://github.com/Gromhogg/pitch-shift/releases/latest/download/PitchShift-Setup.exe)** and open it. If Windows says **"Windows protected your PC"**, click **More info**, then **Run anyway**.

More help: [windows/README.md](windows/README.md).

## How to use it

**What you hear**

- Pick an app, or **All sound**.
- Click the big number to type an exact amount, like `2.5` or `-1.25`. 12 is one octave. Or use **−**, **0** and **+**.
- Turn on **Advanced processing** for music at bigger amounts: going up, the bass stays deep; going down, the top stays bright. A new amount takes a moment longer to kick in.
- With Advanced processing on, slide from **Bass** to **Treble** to suit your headphones (Mac). Pitch Shift remembers it for each pair of headphones or speakers.
- Turn on **Auto EQ** (Mac, with Advanced processing on) to keep the deep bass, mids and highs balanced like the original song. Its five small sliders move by themselves; drag one to nudge it, and double-click it or press **Auto** to go back. It's remembered for each pair of headphones or speakers too.

**Your voice**

- Pick your mic, turn it on, and slide from **Natural** (sounds like a different person) to **Cartoon** (chipmunk or monster). On Windows, choose Natural or Cartoon.
- Turn on **Deeper when slow** and your voice goes lower while you talk slowly, then back when you talk normally (Mac).
- In Discord, Zoom or any other app, choose **Pitch Shift Mic** as your microphone.
- Press **Test** to record 5 seconds of your shifted voice and hear it back.
- Press **Sounds** for the Soundboard (Mac): add sound files with **+**, then click one to play it into your call. You hear it too; on your Mac's own speakers your voice is muted while it plays, so it can't echo.
- Use headphones in calls. If your voice cuts out, turn off the call app's noise suppression (like Krisp).

Both can be on at the same time. Closing the window keeps Pitch Shift running. Quit it with ⌘Q.

## If something goes wrong

- **The app you picked goes silent:** quit Pitch Shift and it plays normally again. Then turn Pitch Shift on in **System Settings → Privacy & Security → Screen & System Audio Recording** and open it again.
- **No "Pitch Shift Mic" in your call app:** restart your Mac.
- **Your voice is silent:** turn Pitch Shift on in **System Settings → Privacy & Security → Microphone**.

## Uninstall (Mac)

```
curl -fsSL https://raw.githubusercontent.com/Gromhogg/pitch-shift/main/uninstall.sh | bash
```

## Build it yourself (Mac)

```
xcode-select --install
brew install rubberband
./build.sh
```

`build.sh` builds `Pitch Shift.app` for Apple silicon and Intel (with Pitch Shift Mic inside), puts it in Applications and puts a shortcut on your Desktop. The first time, it downloads the source of Rubber Band and libsamplerate to build the Intel part (`libs/build.sh`). `packaging/make-pkg.sh` makes the installer, and `./release.sh 1.2.3` posts a new version.

## How it works

- **What you hear:** a macOS audio tap grabs the app's sound and mutes the original. [Rubber Band](https://breakfastquay.com/rubberband/) changes the pitch, and the result plays on your current speakers or headphones. It never changes your Mac's sound settings.
- **Advanced processing:** going up, the bass is shifted an octave less so it stays bass; going down, the song's very top is kept; and a slow tone control keeps the song's overall balance like the original's. Details: [notes/advanced-processing-research.md](notes/advanced-processing-research.md).
- **Your voice:** your mic goes through Rubber Band's low-delay live shifter into "Pitch Shift Mic", a virtual mic built from [BlackHole](https://github.com/ExistentialAudio/BlackHole) that comes with Pitch Shift (you don't need to install BlackHole). It only runs while an app is listening to Pitch Shift Mic.
- **Soundboard:** sounds are added to Pitch Shift Mic after your voice, at their normal pitch and an even loudness. On your Mac's own speakers, your mic is muted while a sound plays, so the call never hears it twice.

## Credits and license

GPL-3.0-or-later. See [LICENSE](LICENSE). Pitch Shift uses Rubber Band by Breakfast Quay (GPL). On Mac it also uses libsamplerate by Erik de Castro Lopo (BSD-2-Clause), and BlackHole by Existential Audio (GPL-3) for Pitch Shift Mic.
