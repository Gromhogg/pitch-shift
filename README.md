# Pitch Shift

Change the pitch of **what you hear** (any app, like Spotify, Apple Music or YouTube) and of **your voice** (as a mic called "Pitch Shift Mic" for Discord, Zoom and others), live, or turn your voice into a woman's or a man's (Mac). For Mac, and Windows (beta).

## Install on a Mac

**Download (double-click):**

1. Download **[PitchShift.pkg](https://github.com/Gromhogg/pitch-shift/releases/latest/download/PitchShift.pkg)** and double-click it.
2. Your Mac says it can't check the file. Click **Done**.
3. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**. Type your password.
4. Click **Continue**, then **Install**. Pitch Shift opens when it's done.
5. Click **Allow** when your Mac asks about recording audio and using the microphone.

If you think this is a virus, you can check the source code and throw it into an AI model– I make this purely for fun.

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
If you think this is a virus, you can check the source code and throw it into an AI model– I make this purely for fun.

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
- Press **Test** to record 5 seconds of your shifted voice and hear it back. With the AI voice changer on, Test waits for the AI voice's delay before it stops, so you hear all 5 seconds in the AI voice.
- Press **Sounds** for the Soundboard (Mac): add sound files with **+**, then click one to play it into your call. You hear it too; on your Mac's own speakers your voice is muted while it plays, so it can't echo.
- Drag sound files onto the Soundboard to add them. Right-click a sound to rename it, change its volume or remove it.
- The Soundboard works with **Your voice** off too: your mic then goes into the call unchanged.
- Use headphones in calls. If your voice cuts out, turn off the call app's noise suppression (like Krisp).

**Voice changer** (Mac)

- Turn it on and pick **Woman** (for a man's voice) or **Man** (for a woman's voice). It turns on **Your voice** too.
- Slide from **Light** to **Full** to choose how strong the change is.
- Slide **Faster ↔ More real** to choose between speed and realism. All the way to **Faster** is the plain voice changer, with almost no delay. Anywhere to the right, an AI voice says your words again in the new voice, so it sounds like a real person (Macs with Apple silicon). The further right, the more of what you say next it hears before it speaks, so words come out clearer and steadier, but your voice reaches the call later: the card shows the delay ("Delay: about 0.46 s"), up to about one second all the way right. It starts a quarter of the way along: the least delay that speaks smoothly. The first time, the AI voice takes up to a minute to get ready; the plain voice changer plays meanwhile. Whenever the plain voice changer stands in for the AI voice, the card says **backup voice** next to the delay. With the AI voice, the **Light**…**Full** slider moves only the pitch, from **Your pitch** to the voice's. Moving the slider changes the delay at your next short pause (so nothing is cut or repeated), or within 1.5 seconds if you don't pause.
- Holding a note ("aaah") keeps its pitch steady in both the plain and the AI voice changer.
- Only one at a time: a voice sets your pitch, so turning one on puts the amount at 0 and turns **Deeper when slow** off. Changing the amount or turning **Deeper when slow** on turns the voice changer off. The **Natural**…**Cartoon** slider is not used while a voice is on. **Test** and the Soundboard still work.
- Add your own voices with the **⋯** button next to the voice menu (see [Your own voices](#your-own-voices)).

All of them can be on at the same time. Closing the window keeps Pitch Shift running. Quit it with ⌘Q.

**Pitch Shift Pro ($5, Mac)**

- Free: **What you hear** with Advanced processing, and **Your voice** in the Cartoon style, with **Test**.
- Pro adds the **Voice changer** (with your own voices), the **Natural ↔ Cartoon** and **Bass ↔ Treble** sliders, **Auto EQ**, **Deeper when slow** and the **Soundboard**. They show a small lock until you unlock them.
- To get a key, click **Unlock Pro** at the top right, then **Email for a key** (or email cbsweetland@gmail.com). Paste the key you get back and click **Unlock**. It works on all your Macs, for good, with no internet needed.

## Your own voices (Mac)

The voice changer can also use voices you download. They sound best as an AI voice (Macs with Apple silicon): put the **Faster ↔ More real** slider anywhere right of **Faster**.

- **Where to find voices:** people share RVC voices on sites like [Hugging Face](https://huggingface.co/models?search=rvc) (search for "RVC v2"). You need the voice's `.pth` file (it often comes in a `.zip` with an `.index` file, which Pitch Shift doesn't need). Voices made at 32, 40 or 48 kHz work; older "v1" voices don't.
- **Turn it into a Pitch Shift voice:** open Terminal, paste this line, type a space, drag the `.pth` (or `.zip`) file onto the Terminal window, and press Return:

```
curl -fsSL https://raw.githubusercontent.com/Gromhogg/pitch-shift/main/tools/convert-voice.sh | bash -s --
```

- It asks how high the voice is (High for most women's voices, Low for most men's). The first time, it downloads what it needs (about 0.5 GB, a few minutes) into `~/Library/Application Support/Pitch Shift/Converter` (delete that folder to remove it). It never asks for your password. After that, each voice takes about half a minute.
- The new voice shows up in the Voice changer's voice menu. Pick it and move **Faster ↔ More real** right of **Faster**. A voice converted before Pitch Shift 3.1 still plays, but without hearing ahead (it can stutter a little more); convert its `.pth` again to fix that.
- **The Voices folder:** click the **⋯** button next to the voice menu, then **Open Voices Folder**. Each voice is a folder in there. In the same menu, **Add Voice…** adds a voice folder (or a `.zip` of one) that someone shared with you, and **Rename…** and **Remove** change the voice you picked. Built-in voices can't be removed.
- Voices copied from a real person, and fan-made voices of characters, are your own responsibility: only use voices you're allowed to use, and don't pretend to be someone you're not.

## If something goes wrong

- **The app you picked goes silent:** quit Pitch Shift and it plays normally again. Then turn Pitch Shift on in **System Settings → Privacy & Security → Screen & System Audio Recording** and open it again.
- **No "Pitch Shift Mic" in your call app:** restart your Mac.
- **Your voice is silent:** turn Pitch Shift on in **System Settings → Privacy & Security → Microphone**.
- **Soundboard sounds cut out in Discord:** Discord's noise filter (Krisp) treats sounds as noise. Use headphones, then in **User Settings → Voice & Video** set **Input Profile** to **Studio**. Or pick **Custom** and turn off **Noise Suppression**, **Echo Cancellation** and **Automatic Gain Control**.

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

`build.sh` builds `Pitch Shift.app` for Apple silicon and Intel (with Pitch Shift Mic inside), puts it in Applications and puts a shortcut on your Desktop. The first time, it downloads the source of Rubber Band and libsamplerate to build the Intel part (`libs/build.sh`), and the Realistic voice changer's AI model files (about 130 MB, listed in `voices/models.txt`; without them the app still builds and only the Natural voice changer works). `packaging/make-pkg.sh` makes the installer, and `./release.sh 1.2.3` posts a new version.

Pitch Shift Pro: the app's side is `Sources/Pro.swift` and `Sources/ProConfig.swift`, and keys are made with `tools/pro-keys.sh`. `build.sh` builds in the key secret from `~/Library/Application Support/Pitch Shift Keys/secret.txt` (or `PRO_KEY_SECRET`) when it's there; a build without it has nothing locked. The [server/](server/README.md) folder isn't used yet.

## How it works

- **What you hear:** a macOS audio tap grabs the app's sound and mutes the original. [Rubber Band](https://breakfastquay.com/rubberband/) changes the pitch, and the result plays on your current speakers or headphones. It never changes your Mac's sound settings.
- **Advanced processing:** going up, the bass is shifted an octave less so it stays bass; going down, the song's very top is kept; and a slow tone control keeps the song's overall balance like the original's. Details: [notes/advanced-processing-research.md](notes/advanced-processing-research.md).
- **Your voice:** your mic goes through Rubber Band's low-delay shifter (from 6 half-steps up or down: Pitch Shift's own pulse shifter, which moves each pulse of your voice whole, so big shifts don't buzz) into "Pitch Shift Mic", a virtual mic built from [BlackHole](https://github.com/ExistentialAudio/BlackHole) that comes with Pitch Shift (you don't need to install BlackHole). It only runs while an app is listening to Pitch Shift Mic.
- **Soundboard:** sounds are added to Pitch Shift Mic after your voice, at their normal pitch and an even loudness (very loud, squashed sounds are turned down to match the others); each sound also has its own volume (0–150%). While a sound plays, voice and sound are kept under −3 dBFS, so call apps don't get them clipped. On your Mac's own speakers, your mic is muted while a sound plays, so the call never hears it twice.
- **Voice changer:** Pitch Shift follows the pitch of your voice and moves it to a typical woman's or man's pitch (about 235 or 112 Hz, keeping your ups and downs, a bit bigger for Woman), and Pitch Shift's pulse shifter makes the change, moving each pulse of your voice whole (so the big move doesn't buzz) and changing the shape of the voice (its formants) the way a smaller or larger throat would. A light tone control then moves the sound toward the average woman's or man's voice. It adds no delay. It learns your usual pitch while you talk, but not while you hold a note, so a held note stays where you sing it.
- **Realistic voice changer:** an AI voice model (RVC v2 with the ContentVec speech reader) says your words again in the new voice. It runs on your Mac with Core ML (nothing goes online), only on Apple silicon. It works in pieces of 0.16 s and waits about 0.28 s to have enough of your voice to work with, plus up to 0.7 s more to hear what comes next (the **Faster ↔ More real** slider): with that, each piece is made knowing the sound after it, so the pieces join smoothly instead of stuttering, and it follows your pitch smoothly (holding a note stays steady). If it ever falls behind, the plain voice changer fills in, so the call never hears silence or your own voice. The voices are blends of 8 speakers each from a public speech collection (VCTK; Woman's are all American), not copies of a real person. Voices you add work the same way; ones made before Pitch Shift 3.1 play without the look-ahead (convert them again for it). Details: [notes/voice-changer-plan.md](notes/voice-changer-plan.md).

## Credits and license

GPL-3.0-or-later. See [LICENSE](LICENSE). Pitch Shift uses Rubber Band by Breakfast Quay (GPL). On Mac it also uses libsamplerate by Erik de Castro Lopo (BSD-2-Clause), and BlackHole by Existential Audio (GPL-3) for Pitch Shift Mic.

The voice changer's Woman and Man voices are made from the CSTR VCTK Corpus 0.92 (Centre for Speech Technology Research, University of Edinburgh, [CC BY 4.0](https://datashare.ed.ac.uk/handle/10283/3443)). Realistic mode uses [RVC v2](https://github.com/RVC-Project/Retrieval-based-Voice-Conversion-WebUI) and its pretrained models (MIT) and [ContentVec](https://github.com/auspicious3000/contentvec) (MIT). Details: [voices/CREDITS.txt](voices/CREDITS.txt).
