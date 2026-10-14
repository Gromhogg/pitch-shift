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

Run either one again any time to update. Needs a Mac with Apple silicon (M1 or newer) and macOS 14.4 or newer.

## Install on Windows (beta)

Coming soon.

## How to use it

**What you hear**

- Pick an app, or **All sound**.
- Click the big number to type an exact amount, like `2.5` or `-1.25`. 12 is one octave. Or use **−**, **0** and **+**.

**Your voice**

- Pick your mic, turn it on, and choose **Natural** (sounds like a different person) or **Cartoon** (chipmunk or monster).
- In Discord, Zoom or any other app, choose **Pitch Shift Mic** as your microphone.
- Press **Test** to record 5 seconds of your shifted voice and hear it back.
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

`build.sh` builds `Pitch Shift.app` (with Pitch Shift Mic inside), puts it in Applications and puts a shortcut on your Desktop. `packaging/make-pkg.sh` makes the installer, and `./release.sh 1.2.3` posts a new version.

## How it works

- **What you hear:** a macOS audio tap grabs the app's sound and mutes the original. [Rubber Band](https://breakfastquay.com/rubberband/) changes the pitch, and the result plays on your current speakers or headphones. It never changes your Mac's sound settings.
- **Your voice:** your mic goes through Rubber Band's low-delay live shifter into "Pitch Shift Mic", a virtual mic built from [BlackHole](https://github.com/ExistentialAudio/BlackHole). It only runs while an app is listening to Pitch Shift Mic.

## Credits and license

GPL-3.0-or-later. See [LICENSE](LICENSE). Pitch Shift uses Rubber Band by Breakfast Quay (GPL), and on Mac, BlackHole by Existential Audio (GPL-3) for Pitch Shift Mic.
