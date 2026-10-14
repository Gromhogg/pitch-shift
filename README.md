# Pitch Shift

Play songs from the Music app higher or lower, live, on your Mac. It works with Apple Music songs too.

## Install

Open **Terminal**, paste this line, and press Return:

```
curl -fsSL https://raw.githubusercontent.com/Gromhogg/pitch-shift/main/install.sh | bash
```

Pitch Shift appears on your Desktop and opens. The first time, your Mac asks if Pitch Shift can record audio. Click **Allow**. It uses this only to grab the Music app's sound and change its pitch. Nothing is recorded or saved.

Run the same line again any time to update.

**Needs:** a Mac with Apple silicon (M1 or newer) and macOS 14.4 or newer.

## How to use it

- **Higher** / **Lower** move the pitch by one half-step. **Normal** goes back to the original.
- **Exact amount:** type any number from -24 to 24 (like `2.5` or `-1.25`) and press Return. 12 half-steps is one octave.
- **Music only:** changes just the Music app. Calls (Discord, Zoom, and others) and other apps sound normal.
- **All sound:** changes everything on your Mac, including calls. Sound from other apps arrives about a quarter second late.
- Switch speakers or headphones any time. Pitch Shift follows whatever is picked in the Sound menu, and the volume keys work like normal.
- Your mic is never changed.
- Closing the window keeps it running. Click the app again to bring the window back. Click **Quit Pitch Shift** to stop.

## If something goes wrong

- **Music is silent while Pitch Shift is open:** quit Pitch Shift, and Music plays normally again. Then turn Pitch Shift on in **System Settings → Privacy & Security → Screen & System Audio Recording**, and open it again.
- **"Pitch Shift can't be opened":** install it with the Terminal line above instead of downloading the file in a web browser.

## Uninstall

Quit Pitch Shift and drag it to the Trash.

## Build it yourself

```
xcode-select --install
brew install rubberband
./build.sh
```

`build.sh` builds `Pitch Shift.app` and puts a copy on your Desktop. `./release.sh 1.2.3` posts a new version for `install.sh` to download.

## How it works

Pitch Shift uses a macOS audio tap (macOS 14.4+) to grab the Music app's sound and mute the original. It changes the pitch with [Rubber Band](https://breakfastquay.com/rubberband/) (its "R3" mode, which keeps bass and drums sounding clean), and plays the result to your current speakers or headphones. It never changes your Mac's sound settings.

## License

GPL-2.0-or-later, because Pitch Shift includes Rubber Band, which uses the GPL. See [LICENSE](LICENSE).
