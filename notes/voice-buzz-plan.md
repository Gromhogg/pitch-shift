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
  (Replaced on 2026-10-14 by the smaller wait described under "Delay work" below.)
- Sound quality otherwise unchanged (HNR, noise between harmonics, wobble within ~1 dB on speech). On steady
  made-up vowels at +10/+15 the standard window is a bit smoother between harmonics, but costs 20–60 ms more delay
  (−3: 112 ms processing alone), so the short window was kept. Sample 7 lets the owner compare.

### Delay (as of 2026-10-13; newer numbers under "Delay work" at the end)
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

## Delay work (2026-10-14, branch v2-voice-delay)

Owner: "The voice pitch filter causes a lot of delay." Measured with `--test-voice --mic "MacBook Pro Microphone"
--tone 440 --watch --seconds 60`: a made-up tone replaces the mic sound at the start of the chain, plays half of every
second, and the time from each tone start (the mic's own time stamp) to it arriving in Pitch Shift Mic is measured.
The mic's own hardware delay is not in these numbers (the MacBook mic reports 30 ms on top).

### Where the delay came from (+3, before)
| part | ms | can it shrink? |
|---|---|---|
| callbacks of 512 samples: one on the way in, one on the way out (+ 1.5 ms safety) | ~22 | yes: 128 samples → ~6 |
| Rubber Band itself (R3 short window: it needs ~53 ms of sound before it can hand back the middle of it) | ~50 | no, not without changing the sound |
| sound waiting in the ring ("one callback + 20 ms cushion"; the lowest point sat at ~16 ms) | ~16 | yes: ~2 |
| total, mic → Pitch Shift Mic | **88** | |
| (not measured above) the MacBook mic's own delay | 30 | no |

- It did **not** grow: 60 s at +3, −5 and +7, the delay stayed within ±2 ms, no dry-outs, no skips.
- Rubber Band's own part depends on the amount: +3 50 ms, −5 65 ms, +7 46 ms, +12 41 ms, −12 84 ms
  (`getStartDelay` − `getPreferredStartPad` + the most it ever holds back). It is the same at any callback size and
  at any sample rate (its window is a fixed length in time).
- Handing Rubber Band pieces of up to 4096 samples did not add delay: the callbacks were 512 samples, so it got 512
  at a time anyway, and everything it had ready was taken out right away.
- No sample-rate conversion in the chain: Pitch Shift Mic runs at the mic's rate; only the tiny clock correction.
- Rubber Band's "high quality" pitch option would cut 16 ms at −5 and 43 ms at −12 (up shifts unchanged), but it
  changes the Natural sound a lot (some bands differ by 15–29 dB, a hole around 6–10 kHz), so it was not used.
- Bluetooth headsets in call mode add their own 150–300 ms (handled on `v2-bluetooth-mic`), and the call app
  (Discord, FaceTime, a browser) adds its own on top. Neither is measured here.

### What changed
- Callbacks of 128 samples (256 above 48 kHz) instead of the usual 512 for the voice's private combined device.
  Other apps using the same mic keep theirs (checked: a second app recording the mic saw no change, no gaps).
- `VoiceRing.swift` (new): the waiting sound. It still starts at one callback + 20 ms (safe), but once the lowest
  point has been steady for 2 s it drops everything beyond a 2 ms margin, with a 5 ms crossfade (never a hard jump).
  If the sound left over gets very low (Rubber Band slowly falling behind, which happens at 16 kHz −1), it replays a
  few ms with a crossfade instead of running dry, and keeps a bigger margin. If it ever runs dry it fades out and back
  in (no click). When the amount changes, or "Deeper when slow" slides the pitch, Rubber Band can pause for a moment
  (most of all when the pitch leaves exactly 0), so the waiting sound is topped up to 12 ms at the start of a change
  (crossfaded) and only trimmed back after 6 s with no change; dips in that time don't grow the margin.
- The shifter itself is unchanged: `--render-voice` output is byte-identical to before (male/female, +3, +3
  Cartoon, +3 middle style, −5, +7, +7 Cartoon).
- `--test-voice --watch` prints the delay parts at the start and, once a second, the waiting sound, dry-outs,
  trims, replays, overloads and the measured delay. `--buffer N` asks for another callback size.

### Offline model (the app's own VoiceRing.swift + real Rubber Band, speech, 60 s)
- 48 kHz, 16 amounts × 6 callback sizes: no dry-outs; one trim at ~2 s; 4 runs needed small replays (big callbacks
  or ±1 near-unity amounts). Rubber Band + waiting at 128 samples: +3 52 ms (was 66 at 512), −5 66 (80), +7 47 (62),
  +12 42, −12 84, +24 36.
- 16/24/44.1/96 kHz: 9 dry-outs in 384 runs, all in the first 0.1 s at −12/−24 (the old logic has the same ones)
  or with 1024-sample callbacks.
- Amount changes while talking: one-step changes are smooth; only huge jumps (24+ half-steps at once) can still run
  dry once (faded), like before.
- "Deeper when slow" (pitch sliding 5 or 8 half-steps down and back every 2.5 s, from +3, 0, ±0.5, +1, +7, −5):
  no dry-outs, about one top-up and one trim a minute, delay at most 63–81 ms while sliding (old ring: 72–84 ms).
  Without the 12 ms top-up it ran dry up to 11 times a minute when the set amount was 0.
- The ring adds no clicks: same peak and same largest sample-to-sample step as Rubber Band's own output.

### Before / after (mic → Pitch Shift Mic, built-in mic, 48 kHz)
| amount | before: delay | before: Rubber Band + waiting | after: delay | after: Rubber Band + waiting |
|---|---|---|---|---|
| +3 Natural | 88 ms (87–89 over 60 s) | 66 ms | **57–58 ms** (live, 60 s) | 52 ms |
| −5 | 98 ms (96–100) | 80 ms | ≈72 ms (model) | 66 ms (model) |
| +7 | 82 ms (81–84) | 62 ms | ≈53 ms (model) | 47 ms (model) |
| +3 Cartoon / middle style | 88–90 ms | 66 ms | same as +3 (style doesn't change timing) | 52 ms |

- Before: callbacks of 512, 0 dry-outs and 0 skips in 60 s at +3/−5/+7, no growth.
- After (live, +3, 60 s): callbacks of 128, 0 dry-outs, 1 overload at start-up only, one trim at 2 s, no growth, pitch
  523.5 Hz (expected 523.3). The "model" numbers are Rubber Band + waiting from the offline model (the app's own
  VoiceRing.swift with the real Rubber Band) plus the ~6 ms of 128-sample callbacks measured live.
- Not re-run live after the merge with 2.0.1 (the Pitch Shift app stayed open, so the new test guard refused for 15
  minutes): −5, +7, Cartoon, middle style, the 220 Hz pitch check, speech through Pitch Shift Mic vs the offline
  render, and `--test-button`.

### Test safety (2026-10-14 call echo)
- During earlier voice tests the owner, in a browser call (Firefox, MacBook mic, Sony headphones in call mode),
  heard their own voice echo. The system log showed the tests did not change any default device, sample rate or
  another app's settings, Firefox never opened Pitch Shift Mic, and Firefox's mic stream ran unbroken through the
  tests after the call had started. Another test's `--test-button` did play two 5 s test-tone recordings into the
  headphones during the call. Firefox restarted its echo canceller about 10 times in 8 s at the start of the call
  (switching between the headphones' mic and the MacBook mic): the most likely source, along with the far end.
- Now the device tests (`--test`, `--test-voice`, `--test-button`, `--test-sounds`, `--test-default-mic`) refuse to
  start while Pitch Shift Mic, the built-in mic or any Bluetooth mic is in use by another app, or while the Pitch
  Shift app is open (with "Your voice" on it would wake on the real mic as soon as a test reads Pitch Shift Mic).
  `--list` marks devices in use.
