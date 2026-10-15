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

## Second check: "it still sounds buzzy" (2026-10-14 evening, branch `v2-voice-buzz`)

Owner: "The audio still sounds buzzy. Is there a way to increase the sampling rate in a way that would help, or would
BlackHole limit the sampling rate?" Result:
- **No Rubber Band option and no higher sample rate makes it measurably better**, so the Rubber Band options stay as
  they are. Part of what is left is how Rubber Band works (all its modes, even its best offline one), and it grows
  with bigger shifts.
- **One real fault was found and fixed:** in Natural, going up, Rubber Band's short window (the low-delay mode we use)
  makes the voice louder than its own standard window and offline mode do: +1.6 dB on average, up to +4.9 dB (real
  voices, +3 … +15), peaks up to +8.7 dB on a high voice. With a mic peaking at −6 dBFS, loud words then went past full
  scale and were cut off hard (harsh, "fuzzy/buzzy"). Now the output is turned down by 0.25 dB per half-step the
  formants are moved (`voiceLevelGain`), and the shifted voice's loudest moments are eased (`softLimit`) instead of cut.
  Details in "The level fault" below.

### How it was tested (offline, no devices)
- Voices: the Mac's `say` voices (Samantha, Daniel, Flo, Reed), each also through 16 kHz and back (like a Bluetooth
  headset mic) and with −40 dBFS pink noise (room); 4 real recorded voices from Apple Loops "Vox Melodics" (Zane,
  Cole = male rap; Zoe, Ruby = female), which also have the top band (above 10 kHz) that the Mac voices lack; and two
  made-up voices (male, female: vocal-fold pulses with breath noise through moving formants) whose **perfect** shifted
  version can be made (same synthesis at the new pitch), so "how far from perfect" can be measured.
- Amounts +3, +5, +7, +10, +12, +15, −4; styles Natural (0), middle (0.5), Cartoon (1).
- A test program with the voice chain's own logic (512-sample callbacks, the ring with one callback + 20 ms cushion,
  dry-out and skip counters). With the current settings its output is sample-identical to `--render-voice`.
- Measures (voiced parts only): HNR (harmonics vs noise, 70–5000 Hz and 1.5–5 kHz); 3–8 kHz level and flatness
  (hiss/fizz); energy above 10 kHz (the old "Z"); a sharp wobble line at Rubber Band's frame rate in the 2–6 kHz
  loudness (a fixed-rate buzz would show up there); roughness (20–150 Hz loudness wobble); pitch error and jitter;
  "pulse clarity" (how much the 1–5 kHz loudness jumps once per vocal-fold pulse, which a phase-vocoder smears);
  and, for the made-up voices, the frame-by-frame spectrum shape error against the perfect result.
- Which measure fits which word: "Z on every word" = energy above 10 kHz (the old live shifter); "buzzy" = a
  frame-rate wobble line or more roughness; "metallic/phasey/too tonal" = HNR and flatness above what a perfect
  shift has, and lower pulse clarity.

### Results
Real recorded voices, Natural, +3/+5/+7/−4 (change vs the original voice; delay = processing only in the chain):

| setting | delay | HNR | 3–8 kHz flatness | above 10 kHz | frame-rate line | roughness | pitch error | CPU |
|---|---|---|---|---|---|---|---|---|
| **now** (R3, short window, HighConsistency) | 66 ms | +2.3 dB | −1.6 dB | −2.5 dB | 3.3 dB (noise level) | −0.8 dB | 1.0 cent | 2.2% |
| R3 standard window | 97 ms | +2.1 | −1.4 | −1.1 | 3.7 | −0.4 | 0.7 | 4.6% |
| R3 at 96 kHz (libsamplerate around it) | 69 ms | +2.4 | −1.9 | −2.8 | 2.2 | −0.9 | 0.7 | 7.2% |
| PitchHighQuality | 62 ms | +2.4 | −1.6 | −2.6 | 3.1 | −0.9 | 0.7 | 2.2% |
| PitchHighSpeed | 76 ms | +1.5 | −1.4 | −0.4 | 3.1 | −1.1 | 1.0 | 1.8% |
| R2 (EngineFaster), standard | 92 ms | +0.1 | +1.4 | −1.6 | – | +0.7 | 0.6 | 1.6% |
| R2 short window + PhaseIndependent | 57 ms | +1.5 | +0.9 | −2.9 | – | +0.1 | 0.7 | 1.4% |
| old live shifter (not allowed) | 60 ms | +1.4 | −1.4 | −0.4 (+4.5 at +10; now −3.2) | – | −1.2 | 0.9 | 2.3% |
| R3 offline, best (reference, not live) | – | +1.9 | +1.1 | −1.1 | – | 0.0 | 1.0 | 3.5% |

Made-up voices, Natural, +5/+10/−4 (difference from the perfect shifted voice):

| setting | shape error | 3–8 kHz level | HNR | flatness | pulse clarity (perfect 67%) | roughness |
|---|---|---|---|---|---|---|
| **now** | 2.98 dB | −2.5 dB | +2.1 dB | −2.4 dB | 46% | −0.9 dB |
| R3 standard window | 2.97 | −1.4 | +2.2 | −1.9 | 46% | −0.9 |
| R3 at 96 kHz | 3.01 | −2.5 | +2.5 | −2.7 | 46% | −1.1 |
| R3 offline, best | 2.98 | −1.5 | +2.2 | −1.8 | 46% | −0.8 |
| R2 standard | 3.77 | −1.0 | +0.7 | +0.5 | 51% | −0.7 |
| R2 short + PhaseIndependent | 3.96 | −1.4 | −0.2 | +0.2 | 68% | −0.1 |
| old live shifter | 2.78 | −1.5 | +1.7 | −2.3 | 46% | −2.2 |

- **There is no fixed-rate buzz.** Rubber Band's frames land at 48000/inhop Hz (with the short window and
  HighConsistency: about 112 Hz at +3, 125 at +5, 141 at +7, 86 at −4; the short window doubles the hop to 512, so it is
  not 256/187 Hz). The wobble line there is 2–4 dB above its neighbours, the same as the original voice shows at that
  frequency, with a depth of about 2% (input 4%). The standard window does show a real line at big shifts
  (12–15 dB at +12/+15, ~290 Hz), so it would be worse there.
- **Nothing is ≥ 3 dB better.** Every R3 option, 96 kHz included, is within about 0.5 dB of now on every measure.
  `OptionSmoothingOn` and `OptionChannelsTogether` give byte-identical output (R3 ignores smoothing; one channel has
  nothing to keep together); `FormantShifted` at Cartoon is byte-identical to Preserved + scale 1; feeding Rubber Band
  in pieces of 512 or 4096 gives the same samples. PitchHighQuality is identical to now when going up and can't change
  pitch smoothly ("Deeper when slow", the slider); PitchHighSpeed brings back the top-band seam (above 10 kHz: −0.4 vs
  −2.5 dB). R2 short + PhaseIndependent keeps the vocal-fold pulses and the breath noise (closest to perfect there) but
  gets the voice's shape wrong by more (+1 dB error, 3–8 kHz 3.5 dB duller on real voices, more noise between
  harmonics), is rougher than now on real voices, and R2 has no formant scale, so the Natural ↔ Cartoon slider could only
  do its two ends. Not a clear win, so not used.
- **What is left is how Rubber Band (a phase vocoder) works**, the same in its best offline mode: (1) the breath noise
  in the upper voice gets turned into "tone": HNR (1.5–5 kHz) above a perfect shift by +2 dB at +3, +3 at +5, +4 at +7,
  +5 at +10, +6 at +12/+15, with the 3–8 kHz band 1–6 dB "peakier" (a buzzy, reedy sound that grows with the amount);
  (2) the crisp once-per-pulse attack of the voice is smeared (pulse clarity 46% vs 67% perfect; going down −4: 42% vs
  84%). No Rubber Band option changes these by more than ~0.5 dB. Only a different kind of voice shifter (time-domain,
  PSOLA-style, which moves whole vocal-fold pulses) would keep them; that would be a new engine, not tried.
- Pitch is exact everywhere (≤ 1 cent median); no extra roughness or jitter.
- The ring: 0 dry-outs and 0 skips in every run (all voices, amounts −4 … +15, all styles), at 48 kHz with 512-sample
  callbacks (the MacBook mic's buffer) and at 16 kHz with 320 (the Bluetooth mic's buffer). Not a buzz source in steady use.
- Peaks: on the Mac's `say` voices the shifted voice's peak is at most +2.2 dB above the original's. On recorded
  voices it is much more in Natural; see the next section.

### The level fault (found and fixed)
- On the 4 recorded voices, Natural going up made the voice louder than the original with the short window, and more
  than Rubber Band's standard window and offline mode (level of loud parts, vs the original):

  | | +3 | +5 | +7 | +10 | +12 | +15 |
  |---|---|---|---|---|---|---|
  | short window (before), extra vs standard window | +0.8 | +1.2 | +1.7 | +2.6 | +3.1 | +3.9 dB |
  | short window (before), high female voice vs original | +2.2 | +3.9 | +5.2 | +6.1 | +5.5 | +3.1 dB |

  Fit over all voices, amounts and the middle style: **+0.256 dB per half-step the formants are moved back down**
  (formant move = pitch × (1 − style)), spread ±0.5 dB. Cartoon (formants not moved): the same level in all modes.
  Going down: the short window is slightly quieter (−0.7 dB at −4), which can't clip, so it is left alone.
- Where it comes from: R3's formant step (`analyseFormant`/`adjustFormant` in `R3Stretcher.cpp`) as run in the
  single-window mode. Moving only the formants down by 10 half-steps with no pitch change (formant scale 0.56) gives
  short +6.0 / +5.6 / +1.6 dB vs standard +2.8 / +1.4 / −1.2 vs offline +1.7 / +1.3 / −2.7 (high female recording /
  made-up female / male recording); moving them up does not make the short window louder. In that mode the envelope
  is taken from a Hann-windowed 2048 frame (standard mode: Niemitalo window), everything is rebuilt from that one FFT,
  and it has its own phase-lock bands (`Guide.h`, single-window: 1-bin locking below 1600 Hz). The exact line wasn't
  pinned; Rubber Band comes from Homebrew's static library, so it is corrected after Rubber Band instead.
- Made-up voices, Natural +10, level vs original: short +5.5 / 0.0 dB, standard +1.3 / −2.2 dB (female / male).
- Clipping: with the chain's hard cut at ±1, mic peaks of −12, −9, −6, −3 dBFS (Natural, +3 … +15, 4 voices):

  | | −12 | −9 | −6 | −3 dBFS |
  |---|---|---|---|---|
  | before: settings that clip / 100 ms moments cut | 0 / 0 | 0 / 0 | 3 / 16 | 6 / 93 |
  | after the level fix | 0 / 0 | 0 / 0 | 1 / 1 | 3 / 23 |
  | standard window, for reference | 0 / 0 | 0 / 0 | 0 / 0 | 3 / 7 |

  After the fix the level matches the standard window: +0.0 dB on average (−1.6 … +1.2), before +1.6 (up to +4.9).
- **The fix** (`VoiceShifter.swift`):
  - `voiceLevelGain(halfSteps:cartoon:)`: −0.25 dB per half-step of formant move, 0 dB in Cartoon and going down.
  - `VoiceStretcher.retrieve` applies it to what comes out of Rubber Band; it glides (30 ms) when the amount, the style
    or "Deeper when slow" changes. Largest change in 10 ms while the style slider moves: 0.17 dB.
  - `VoiceChain.render`: the shifted voice goes through `softLimit` (unchanged up to 0.7, eased to at most 0.95)
    instead of the hard cut at ±1; the voice at 0 (not shifted) still uses the plain ±1 cut.
  - `--render-voice … --voice-preset old` renders without the level fix: sample-identical to before (checked at
    +5/+10/−4, styles 0/0.5/1, two voices). The new output is exactly the old one times the gain; Cartoon and going
    down are byte-identical to before. HNR, flatness, roughness, frame-rate line, pitch: unchanged (a constant gain).
  - Delay and CPU: unchanged.
  - Windows: not changed (its voice engine is separate C++).

### Sample rates (answer to the owner's question)
- Pitch Shift Mic (BlackHole) supports 8, 16, 24, 44.1, 48, 88.2, 96, 176.4, 192, 352.8, 384, 705.6 and 768 kHz
  (`kSampleRates` in driver/BlackHole.c). **BlackHole does not limit anything.** Both of its sides share one rate.
- The voice chain runs at the **mic's** rate (`VoiceChain.init`: rate = `nominalRate(mic)`; Pitch Shift Mic is set to
  match; the app never changes the real mic). `--list` on this Mac: MacBook Pro Microphone 48 kHz (supports 44.1, 48,
  88.2, 96), Headphonez V3 (Bluetooth) mic 16 kHz only, G522 48 kHz only, iPhone mic 48 kHz only. So with the built-in
  mic everything is 48 kHz end to end; with a Bluetooth headset mic, Pitch Shift Mic itself drops to 16 kHz.
- Rubber Band scales its window with the rate (2048 samples at 48 kHz, 4096 at 96 kHz: both 43 ms), so at 96 kHz it
  "sees" the voice the same way; only its frames come twice as often (the hop stays 512 samples). Measured: no better
  (table above), +3 ms delay on average (+8 ms at +5), 3× the CPU. A voice has nothing above 20 kHz and Discord/Zoom
  send at most 20 kHz, so a higher rate can't add anything. **A higher rate would not help; a lower one hurts:** a 16 kHz
  Bluetooth mic loses everything above 8 kHz (thin), adds its own call-mode codec, and makes our chain 20 ms slower
  (87 vs 67 ms processing), and the headphones' own sound drops to call quality while their mic is open.

### Delay (unchanged)
- Processing in the chain now (512-sample callbacks): +3 66 ms, +5 60, +7 63, +10 61, +12 61, +15 59, −4 75 ms.
  The device path adds about 25 ms (the live tone test measured 87–103 ms end to end).
- Note: in real-time mode `rubberband_get_start_delay` is not where the sound lines up. Dropping it (as `--render-voice`
  does) leaves the output 20–34 ms early against the input; the real line-up is within ±6 ms of no shift at all.
  This only matters when comparing `--render-voice` output with its input.

### Not tested
- A device test (`--test-voice --mic "MacBook Pro Microphone"`): the MacBook mic and Pitch Shift Mic were in use the
  whole time (the owner was in a call), checked every 30 s for 10 min; after the fix the G522 headset mic was in use
  for another 10 min. So the live chain with the fix (softLimit included), the drift correction on the hidden feed (its
  quality is left at Core Audio's default) and real-time overloads under heavy load (this Mac had 9 GB of swap in use)
  were not measured.
- What call apps do to the voice afterwards (noise suppression such as Discord's Krisp, echo cancellation, automatic
  gain). These are made for natural voices and can chop or "buzz" a shifted one.

### What the owner can try
1. Use the MacBook mic (or a USB/wired mic), not a Bluetooth headset mic.
2. In Discord (Voice & Video) / Zoom: turn noise suppression off (or "None"), and try echo cancellation and automatic
   gain off.
3. Press Test in Pitch Shift: if the replay sounds clean but the call sounds buzzy, it is the call app's filters.
4. Smaller amounts sound cleaner (the "tone" effect grows with the amount); the style slider changes it little.
5. Keep the mic's input level moderate (System Settings → Sound → Input): loud words at big Natural amounts were the
   ones that got cut off before the fix.

### Tools (scratchpad `buzz/`, not in the repo)
`bench.cpp` (the chain's logic with any Rubber Band option, 96 kHz via libsamplerate, R2, live shifter, offline),
`measure.py` + `run.py` (measures), `synth.py` + `ideal.py` (made-up voices and their perfect shifts), `lagtest.py`
(true line-up), `same.py` (byte-identical checks), `rates.swift` (each device's supported rates and "running somewhere"),
`tables.py`, `clip.py` (clipping at mic levels), `lvl.py`/`lvl.sh` (formant-only vs pitch-only level), `check_fix.py`
(old preset = old code, new = old × gain), `glide_check.py` (gain glide when the style moves).
