# Advanced processing: research notes

Research and build of the "Advanced processing" switch in the "What you hear" card (October 13-14, 2026).
The raw data, scripts and test sounds are in the research folder (scratchpad `advanced/`, session 8903a598):
`results/dsp.md` (no-AI work, rounds 1-4), `results/ai.md` (AI work), `results/metrics.md` (how the measures were
checked). The numbers below are copied from there.

## Summary

- **Pick: "balanced3" (no AI).** Going up, the bass is shifted an octave less so it stays bass; going down, the
  original's very top is kept; always, a slow tone control steers the long-term balance back toward the original.
- It fixes the "bracket": the tone balance error drops from 8.6 to 2.4 dB going up and from 6.8 to 3.3 dB going down
  (3 main test songs), and the deep bass going up is back (below 60 Hz: -23 dB → -1.7 dB).
- Same delay as normal mode for ±12 (about 200 ms in total on the MacBook speakers), about +15 % of one CPU core,
  no download, no AI, no license question beyond Rubber Band.
- **Runner-up: the same plus AI drum separation** (Sony X-UMXL, CC BY 4.0) that keeps drum hits unshifted. Punchier
  drums going up, but no better on the other measures, about 0.64 s total delay, ~2.5× the CPU and a 44 MB model.
  Built and tested, kept on the local branch `v2-advanced3-ai` (not pushed).

## The problem

At bigger shifts (about ±5 half-steps and more) music stops sounding right:
- some notes blur together;
- the song "falls into a bracket": squeezed high and thin when shifted up, low and muddy when shifted down;
- shifted up there is much less bass (worse on headphones with little bass); shifted down the top end goes dull.

What the measurements showed: a plain pitch shift moves the whole song's tone balance with it. At +8 the deep bass
(below 60 Hz) drops by about 23 dB, and at -8 everything above about 9 kHz is gone. No Rubber Band setting fixes this
(every option tried left the balance error at 7.7-8.7 dB going up).

Limits set by the owner: total delay with Advanced processing at most 0.8 s (sound in to ear, including the cushion and
the speakers); AI only if it is free (runs on the Mac, code and model weights may be bundled in a free
GPL-3.0-or-later app); Mac first; real time; reasonable CPU.

## How candidates were tested

- **Test songs:** 6 short songs mixed from Apple Loops: A hip hop (808 and sub bass), B funk band, C pop with female
  vocals, D rock band, E piano ballad (no bass instrument), F EDM drop (40 Hz sub bass). Because they are mixed from
  loops, every part (drums, bass, ...) is known exactly. The owner's own music was never used.
- **Shifts:** +5, +8, +12, -5, -8 (round 4 also +4 and +6; the engine also -24..+24).
- **Measures** (each compares the shifted song with the original, after matching loudness):
  - *tone balance* (tbDev): how far the long-term 1/3-octave spectrum is from the original's, in dB (0 = same);
  - *bass*: level below 60 Hz and 60-150 Hz; *bass on earbuds* (budBass/budNote): the low end as heard through a
    typical earbud that plays little below 100 Hz;
  - *top end*: level above 5 kHz, and "air" above 8 kHz;
  - *drum hits*: hit peak level (onsetPk, 0 = like the original) and smear before hits (preEcho, lower is better);
  - *note clarity*: blurF (notes smeared in pitch) and ringOn (notes ringing on), checked against a synthetic song
    whose perfect shift is known and against controlled damage (rank agreement 0.97 and 0.81). The old "chroma"
    clarity measure was dropped: it scored the perfect shift worse than today's normal mode.
  - *wrong-key leak*: sound left in the OLD key (ghost notes) when part of the song is kept unshifted
    (≤ -28 dB clean, -20 dB clearly audible; it reads known added levels back within 3 dB);
  - *pitch accuracy* (cents), *delay*, *CPU*.

## What was tried

| idea | result |
|---|---|
| Rubber Band options (R2/R3, window sizes, formants, transients, offline mode) | none fixes the balance (tbDev 7.7-8.7 dB going up vs 8.6 for normal) |
| Slow EQ toward the original balance | helps (8.6 → 6.5) but can't bring back bass that is an octave too high |
| Bass "fold": shift the bass band by N-12 so it stays bass | the big fix for going up |
| "Air": keep the original's very top when going down | fills the empty top end; leak -46 dB or lower (inaudible) |
| Keep drums unshifted with a harmonic/percussive split (no AI) | better drum hits but clear old-key ghost notes (-9 dB) |
| "Attack keeper": keep only the first 10 ms of hits unshifted | helped on 3 songs, worse on the other 3, leaks piano attacks (-25 dB); dropped |
| Headphone bass helper (added bass harmonics) | measures neutral; not needed once the fold is in |
| AI: split the song into parts and treat each part differently | see "AI" below |

## The pick: "balanced3"

How it works (for an amount of N half-steps):
- **Going up (N > +3): bass fold.** The bass band is shifted by N-12 instead of N, so the bass line stays in the bass
  range. Between +3 and +7 the fold comes in gradually by moving its crossover up (so nothing jumps by an octave and no
  bass note is doubled). A "fold floor" keeps bass that would land below 35 Hz on the normal path (EDM sub basses).
  At +12 the bass is simply the original bass. Beyond +15 a second fold (N-24) comes in the same way.
- **Going down (N < 0): air.** Above 15 kHz × 2^(N/12) (9.4 kHz at -8; never below 7 kHz) the original's top end is
  kept, so the song doesn't go dull.
- **Always: a slow tone control.** 10 gentle filters steer the long-term balance back toward the original's (within
  ±6 dB in the mids, up to 15 dB of cut below 100 Hz). It predicts the right setting from the amount, so it is right
  within about a second, and then corrects itself slowly from what it measures.
- **A safety limiter** at the end keeps the sound below full scale (the tone control can add a little level).

Results (tbDev and band levels in dB vs the original; up = mean of +5/+8/+12, down = mean of -5/-8):

| | tbDev up / down | <60 Hz up / down | air >8 kHz up / down | onsetPk up / down | preEcho up / down |
|---|---|---|---|---|---|
| normal (today), songs A-C | 8.59 / 6.80 | -23.4 / +4.1 | +1.6 / -4.7 | -1.45 / -1.10 | 2.20 / 1.48 |
| **balanced3**, songs A-C | **2.43 / 3.32** | -1.7 / -2.6 | +0.1 / -0.1 | -1.88 / -0.14 | 2.08 / 1.02 |
| normal, songs D-F | 8.97 / 8.80 | -16.0 / +10.8 | +2.0 / -6.0 | -1.29 / -1.74 | 1.42 / 0.83 |
| **balanced3**, songs D-F | **3.58 / 5.17** | +0.8 / +2.5 | 0.0 / -0.8 | -1.49 / -1.26 | 1.47 / 0.57 |

- Better than normal on tone balance in every song and shift tried (30 of 30 cases).
- Bass on earbuds stays within about 0.7 dB of the original going up (normal: 1.9 dB off on average, 2.9 dB for the
  bass notes).
- Note clarity above 300 Hz is the same as normal (within about 0.2 dB). Below that the fold moves bass notes an octave
  down on purpose, which the clarity measures count as "different"; a perfect fold scores the same way.
- No wrong-key ghosts: nothing is kept unshifted going up; the air band going down leaks -55 dB.
- Pitch accuracy: 0.1-0.7 cents (inaudible).
- Drum hits: about the same as normal (slightly softer going up, better going down).
- Weak spots left: an EDM sub bass at +8..+11 is still about 16 dB too strong at 32 Hz; on the piano song the left
  hand is partly doubled at +4..+6 and the low end is still +19 dB at -8 (normal: +25).

### In the app

- `Sources/Advanced/AdvancedChain.cpp` (C++, plain C API in `AdvancedChain.h`) does the work. The app's own
  `--render-file` output matches the research renders within 0.04 dB tone balance on all 15 test files.
- **Changing the amount while playing:** a running Rubber Band shifter changes its own delay by up to 31 ms when its
  pitch is changed, which would make the bass and the rest drift apart. So each new amount starts fresh shifters
  (from a pool of 7 made in advance), warms them up on recent sound, and crossfades over 80 ms. The new amount is
  heard about 0.2-0.3 s after the click. Tested: paths stay lined up within about 1 ms after changes, no clicks
  beyond normal, 0 underruns.
- **Delay is fixed** for the engine's life: 138 ms for amounts within ±12, 225 ms beyond (48 kHz; the app rebuilds
  the player with the bigger delay only when the amount goes past ±12). Measured live on this Mac (MacBook Pro
  speakers): about 200 ms total within ±12 (normal mode 205-217 ms), about 290 ms beyond.
- **Safety limiter:** the tone control can lift peaks a little (up to +1.7 dB over the original's peak on the test
  songs), so a 2 ms look-ahead limiter at the end keeps everything under -0.3 dBFS. It acted on 13 of 30 test files,
  at most 2 dB and about 1.4 % of the time; otherwise it leaves the sound untouched.
- **No memory is made on the sound threads:** the captured sound goes into a lock-free ring (`AudioRing.c`), a worker
  thread runs the engine, and a second ring with the usual 50-150 ms cushion feeds the speakers through an
  AVAudioSourceNode. Checked: 0 allocations inside the engine's process calls (malloc counter), 0 dropouts live.
- **CPU** (one core of the M3 Pro): the engine alone is 0.05-0.11 of real time within ±12 (0.14 at +15..+19). The whole
  app while playing at +8 (live test, other apps busy): about 42 % of one core vs 26 % in normal mode.
- **Download:** no change apart from the code (no model files).
- **Licenses:** only Rubber Band (GPL), as before.

## AI

### Free models and their licenses

| model | weights license | verdict |
|---|---|---|
| HTDemucs (Meta) | the author: "The model weights are not covered by the MIT license, and are provided only for scientific purposes." ([issue #327](https://github.com/facebookresearch/demucs/issues/327#issuecomment-1134828611), also #384, #508) | **not allowed** (quality reference only) |
| X-UMXL (Sony) | CC BY 4.0 ([Zenodo 7128659](https://zenodo.org/records/7128659)), trained on Sony's own data | allowed (credit needed) |
| MDX-Net onnx_A (KUIELab) | CC BY 4.0 ([Zenodo 5717356](https://zenodo.org/records/5717356)) | allowed by its license, but trained only on MUSDB18-HQ, whose terms say "educational purposes only" |
| Open-Unmix UMX-HQ | MIT | allowed, same MUSDB question, weaker |
| Open-Unmix UMX-L | CC BY-NC-SA (non-commercial) | not allowed |
| Spleeter (Deezer) | MIT (per the authors' paper) | allowed, not tested |

All of them can run on the Mac with Core ML (compiled when the app runs; no Xcode needed).

### What was tried with the parts
- Shift each part on its own: fixes nothing (the balance problem stays).
- Keep the whole drum part unshifted: good balance, but the AI's drum part carries some of the music, which is then
  heard in the old key (-16 to -25 dB ghosts).
- **Hybrid** (the runner-up): keep only the clearly percussive part of the AI drum part unshifted, run everything else
  through balanced3. X-UMXL put a plucked synth lead into its drum part on one song (ghosts at -11 to -14 dB); a
  "note-peak protection" (any narrow peak of the mix spectrum never stays unshifted) fixed that.

### Runner-up: balanced3 + X-UMXL drums (going up only)

Mean of the 6 songs, going up:

| | tbDev | onsetPk | preEcho | blurF >300 Hz | ringOn >300 Hz | wrong-key leak |
|---|---|---|---|---|---|---|
| balanced3 | 3.01 | -1.69 | 1.78 | -0.35 | 2.17 | (reference) |
| balanced3 + AI drums | 3.12 | **-0.64** | **1.18** | -0.04 | 2.09 | within +0.9 dB of balanced3 |

- Drum hits are clearly punchier on the funk and pop songs, a little on hip hop, rock and EDM, and not at all on the
  piano ballad. Going down there is no gain (slightly worse), so it would be used only going up.
- Tone balance and note clarity are slightly worse.
- Costs: delay about 0.64 s in total (separation 0.32 s + drum split 0.04 s on top of balanced3), CPU about 33 % of
  one core (model ~9 ms per 0.12 s on the CPU), a 44 MB model (8-bit weights), and Core ML at run time.
- Built and tested as `Sources/Separator/DrumKeeper.mm` (real-time safe: 0 allocations/locks in its process call,
  0 misses in 60 s live tests, also under load). Kept on the local branch `v2-advanced3-ai`.

## Why balanced3

- It fixes what the owner described: the bass going up, the dull top going down, and the "bracket" (tone balance
  error cut by 60-70 %), on all 6 songs, with no ghost notes.
- The AI version adds only one thing (punchier drums going up), is slightly worse on balance and clarity, does
  nothing on the piano song, triples the delay (0.64 s, close to the 0.8 s limit, more with Bluetooth headphones),
  uses 2.5× the CPU and adds a 44 MB download. Its separation also has to cope with real songs it has never seen.
- If the owner prefers the AI version by ear, it is ready on `v2-advanced3-ai`.

## Not verified yet

- Listening (all choices were made by measurements).
- Real songs (only Apple Loops mixes were used), Bluetooth headphones, other Macs (M1), long sessions.
- How fast clicking through amounts sounds (numbers only).
- Amounts beyond ±12 were tuned by numbers on the same 6 songs only.

## Listening samples

`~/Downloads/Pitch Shift advanced samples/` (made with the app's own `--render-file`, except D): 4 test songs at +5,
+8 and -5, each as A original, B normal, C advanced, and for + amounts D advanced with AI drums (research render).
All at the same loudness (-18 LUFS). README.txt in the folder says what to listen for.

## Checks

- `PitchShift --render-file IN OUT --steps N [--advanced] [--steps-at "4:8,8:-5"]`: shift a file with the app's own
  code (normal or advanced); `--steps-at` changes the amount while it plays.
- `PitchShift --test --pid N --steps N --advanced --watch [--record-out F.wav] [--steps-at ...]`: live test with a
  quiet tone; prints the delay parts every half second; `--record-out` saves what Advanced processing played.
