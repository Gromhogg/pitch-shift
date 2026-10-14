# Voice "buzz" in Natural style: plan

Owner's report: "In the natural voice, my voice sounds 'buzzy' or 'fuzzy' like I'm saying Z with every word."
Natural = formants kept (Rubber Band live shifter, `FormantPreserved`). Cartoon = formants shifted (check it too).

## Likely causes (to check, most likely first)
1. **Rubber Band's formant keeping with the short window.** The live shifter with `WindowShort` looks at very
   short pieces of sound (about 10–20 ms). That is too short to see the separate harmonics of a low voice, so the
   "voice shape" (formant envelope) it measures wobbles from piece to piece. The wobble repeats at the shifter's
   step rate (about 100–400 times a second), which is exactly what a buzz or "z" sounds like.
2. **Our own code** around the shifter: the block/ring buffer hand-off, the ring start, the mono mix,
   clamping to ±1 (clipping would add buzz on loud words), and the reset when coming back from 0.
3. **Something in the live chain** (sample rate mismatch, drift correction, dropouts). Less likely: these would
   also hurt Cartoon and the plain tone test.

## Tests
- Speech from `say -o` (a male and a female voice, sentences with lots of voiced sounds and "z"/"s"),
  plus a made-up steady vowel (known pitch, so harmonics are easy to measure).
- Offline Swift test program (`scratchpad/voice-fix/`), same settings as `VoiceChain`:
  +3, −3 and +5 half steps, Natural and Cartoon.
- Rule out our code: live shifter called directly vs the same sound through a copy of our `render`/ring logic
  with callback sizes 512, 480, 1024 and odd sizes (333, 17, 1); the outputs should match sample for sample
  (after the one-block ring delay). Also check clamping (how often the output goes past ±1), stereo mixing,
  and the reset path.

## How to measure "buzz"
On voiced parts only (where the original has a clear pitch):
- **Noise between harmonics**: we know the pitch of the original at every moment, so we know where the shifted
  harmonics should be. Energy between the harmonics vs energy on them (in dB, lower is cleaner), 100 Hz–4 kHz.
- **Hiss/fizz**: 3–8 kHz energy compared to the original.
- **Step-rate wobble**: how much the loudness in bands wobbles at the shifter's block/step rates
  (e.g. 93.75, 187.5, 375 Hz) compared to the original.
- Also a "clean" offline reference (Rubber Band R3 offline, long window) to see what good looks like.

## Fixes to compare (and the delay each adds)
- Live shifter `WindowShort` vs `WindowMedium`.
- Formant scale tweaks (`rubberband_live_set_formant_scale`).
- Full R3 real-time stretcher (`rubberband_new` with RealTime | EngineFiner | FormantPreserved, and window options).
- R2 real-time stretcher (`EngineFaster`) with FormantPreserved.
- Aim: clean sound with total delay about 120 ms or less (it's for voice calls).

## How to verify
- Listening samples in `~/Downloads/Pitch Shift voice samples/`.
- After the fix: `--test-voice --file speech.aiff --steps 3 --out …` before/after through the real Pitch Shift Mic,
  run the same buzz measures on those recordings; `--test-voice --tone 440 --steps 3` must still read ≈523.3 Hz
  (and a Cartoon tone); measure the delay (tone start → first sound); `--test-button` still works.
- Keep: Natural/Cartoon switch while running, bypass at 0, live amount changes, no memory made on the sound
  thread, start only when an app listens.

## Results (2026-10-13)

Owner's saved setting at the time: +15 half steps (later +10). Mic: G522 LIGHTSPEED (USB, 48 kHz).

### Cause 1 (the buzz): Rubber Band's live shifter stops keeping formants at about 10 kHz
- Our own code was not the problem: the copy of `render`/ring gave exactly the same samples as calling the live
  shifter directly (callback sizes 512, 480, 1024, odd sizes), never clipped, and a live recording through Pitch Shift
  Mic matched the offline output sample for sample (match 0.9998) once cause 2 was fixed.
- Harmonics, noise between harmonics and wobble were all fine (as good as Rubber Band's best offline mode).
- But above ~10 kHz the live shifter does not correct formants in Natural: everything up there is moved up exactly like
  Cartoon (there is a visible seam at ~9.6 kHz). So every voiced word gets a hiss band above 10 kHz that the real
  voice doesn't have, which sounds like a "z". The more the amount goes up, the louder it gets.
- Energy above 10 kHz on voiced parts, vs the whole voice (male TTS voice; original −46 dB):

  | amount | live shifter (before) | new (after) |
  |---|---|---|
  | +3 | −31 dB | −45 dB |
  | +5 | −30 dB | −44 dB |
  | +10 | −30 dB | −45 dB |
  | +15 | −32 dB | −50 dB |

  Female voice (original −44.5 dB): +3 −30 → −43, +5 −27 → −43, +15 −27 → −48. Down shifts (−3) were fine
  before and after (nothing above 10 kHz). Same numbers through the real Pitch Shift Mic recordings.
- Rubber Band's R3 real-time stretcher with `PitchHighSpeed` has the same seam; `PitchHighConsistency` /
  `PitchHighQuality` don't. `WindowMedium` live shifter and formant scale tweaks don't help (same −32 dB at +15).
  R2 (`EngineFaster`) fixes the top band but is rougher (HNR 2–10 dB worse on vowels).

### Cause 2 (cut-outs): the voice chain restarted itself every few seconds
- Creating or closing our private combined device fires the "device list changed" listener, which rebuilt the
  chain, which fired it again. Gaps of 130–150 ms every 0.7 s at first, then every ~3.5 s, and the shifter
  started over each time. Fixed: rebuild only when the mic, Pitch Shift Mic, or a sample rate really changed.

### The fix
- Voice now uses `rubberband_new(rate, 1, RealTime | EngineFiner | WindowShort | PitchHighConsistency |
  FormantPreserved (Natural) or FormantShifted (Cartoon), 1.0, 2^(steps/12))`, `rubberband_set_max_process_size(4096)`.
  Live changes: `rubberband_set_pitch_scale`, `rubberband_set_formant_option`; `rubberband_reset` when leaving 0.
- Each callback: process the callback's samples, retrieve everything available into a ring. Start sending once the
  ring holds one callback + 20 ms (trim any overshoot the very first time); if it runs dry, wait for that again;
  every 0.5 s, if the ring never dipped below 20 ms + 5 ms, skip the extra. Checked offline at 16/24/44.1/48/96 kHz,
  amounts −24…+24, callbacks 1…4096 samples: no dry-outs or skips in steady use (only right after big amount jumps).
- Sound quality otherwise unchanged (HNR, noise between harmonics, wobble within ~1 dB on speech). On steady
  made-up vowels at +10/+15 the standard window is a bit smoother between harmonics, but costs 20–60 ms more delay
  (−3: 112 ms processing alone), so the short window was kept. Sample 7 lets the owner compare.

### Delay
- Processing only (offline, 512-sample callbacks): before 58–83 ms, after 56–85 ms
  (+3: 59 → 66, −3: 60 → 76, +5: 62 → 60, +10: 73 → 62, +15: 83 → 60, −12: 74 → 85).
- Mic to Pitch Shift Mic, measured live with `--test-voice --tone 440` (same measuring code on both):
  +3: 87 → 92 ms, −3: 86 → 103 ms, +15: 99 → 79 ms.
- R3 standard window would be +3: 94 ms, −3: 112 ms, −12: 144 ms processing alone (too slow for calls).

### Checks done
- Tone pitch through the real chain (before the owner's call started): +3 Natural 523.5 Hz (expected 523.3),
  +3 Cartoon 523.5, +15 1046.5 (1046.5), −12 220.0, +2.37 504.5 (504.6). Speech recordings through Pitch Shift Mic
  at +3/+15 (male/female): no gaps, top band fixed, other numbers same as offline.
- Not run (owner was in a Discord call): `--test-button` and repeat device checks; see the report for commands.

### Listening samples
`~/Downloads/Pitch Shift voice samples/` (male voice; 2/5 are the old sound, 3/6 the fix, 7 the slower option,
9 a real recording from Pitch Shift Mic of the app as it was, with the cut-outs).

### Tools (scratchpad, not in the repo)
`rbtest.swift` (offline shifter variants), `sim.swift` (the new chain logic), `cushion.swift`, `buzz.py` (measures),
`lts.py`, `wavalign.py`, `gaps.py`, `final.py`.
