# Plan: "Voice changer" — a third card that turns a man's voice into a woman's and a woman's into a man's

## Context
The owner wants one more widget in Pitch Shift: a **Voice changer** with two voices first — **Woman** (for a man's voice) and **Man** (for a woman's voice) — that sound **real**, work **live** in calls, keep the **48 kHz** path, cost **nothing** to anyone (no paid services, no cloud), may use **AI** if it is local, free and convincing, and are **expandable** so more voices can be added later. Built by a workflow of **at most 5 Opus agents** (research → plan → implement).

Decisions the owner made (2026-10-14/15): a **third card in the main window**; **AI "Realistic" mode on Apple silicon, non-AI mode as the Intel fallback and the default**; the **user chooses the delay/quality trade-off** ("let the user choose, do all"); part of the **free app** (committed locally, then pushed as a PR like the other features); AI voices **bundled in the installer** (a big installer is fine).

What exploration found (two read-only agents, Oct 2026):
- The voice engine already separates pitch and formants (Rubber Band R3's formant scale is applied on top of the pitch change: envelope ratio F with pitch ratio P = `set_formant_scale(F/P)`), glides values click-free (`VoiceStretcher`), and has an offline twin (`--render-voice`) that shares the same code — so a non-AI "Natural" changer is an extension of `Sources/VoiceShifter.swift`, not a new engine. At 0 half-steps the chain bypasses Rubber Band; a changer must force it on.
- Research says pitch AND formants must move together (≈82 % perceived-sex flip), with a **target median pitch** (≈190–210 Hz for Woman, ≈105–120 Hz for Man) rather than a fixed shift, formants ×1.15–1.20 / ×0.85, breathiness, a small "smile" lift above ~1.5 kHz, intonation range ×1.1–1.3 / ×0.8–0.9, creak (vocal fry) smoothing, and an automatic tone EQ toward a target-gender spectrum. The DSP ceiling: usually heard as the other sex, but a man rarely becomes a "real woman" — the glottal pulses survive. Only resynthesis (AI) replaces them.
- Free, bundleable AI that fits: **RVC v2** (MIT code and base weights trained on VCTK CC BY 4.0; a 48 kHz generator exists; pitch is an explicit input so our pitch mapping plugs in; one model per voice — we train our own Woman and Man voices on CC BY 4.0 data, multi-speaker so no real person is cloned; content encoder ContentVec, MIT; run through **Core ML** on a worker thread, a pattern already proven in this repo). Expected ~200–300 ms end to end, Apple silicon only. Prototype voice available now: `KoeAI/llvc_models f_8312_32k` (MIT). Out for licence reasons: Seed-VC, MeanVC, RAVE, DDSP-SVC's vocoder, so-vits, Beatrice, NISQA.
- Free realism measures: a gender classifier (MIT, 98.7 %), ECAPA speaker-embedding distance (Apache), Distill-MOS (MIT) for ranking, Praat statistics, Whisper word-error rate, and a blind listening set for the owner. Pitch alone fools classifiers, so several measures are used together.
- The window code assumes exactly two cards (`measure/allowed/bestScale/arrange`); a third card needs new layout rules; `ShiftCard` always builds a big number and − 0 +; previews are hidden and focus-free.

## Queued while in plan mode (not part of the Voice changer; done right after approval)
- **Soundboard: drag and drop.** Dragging audio files from Finder onto the Soundboard window adds them (same copy-into-Application-Support path as the + button; several files at once; a highlight while hovering; non-audio files refused). Goes to the Soundboard agent on `v2-voice-tweaks` with its three leftover steps (commit the popover fix, device tests when the mic is free, detach).
- Resume the paused agents: `v2-voice-delay` (rebuild, live checks, commit, push, PR), `v2-voice-buzz` (confirm the Natural-mode level rise/clipping lead, fix in `VoiceStretcher`, commit), the Auto EQ workflow (engine commit → tune → app; local only).

## Order of work
1. **First finish 2.0.2** (the paused branches above → PRs → merge → release). The changer hooks into exactly the code those branches rewrite (`VoiceChain.render/shift`, `pushParams`, the voice card), so starting earlier means doing it twice.
2. **Start A2's AI research right away** (it lives in `research/voicechanger/`, not in the app) and the voice training, which takes hours.
3. After 2.0.2 is on main: Step 0, then A1 + A3 in parallel, then A4.

**Owner must provide:** either ~15 GB of free disk for overnight training on this Mac (only ~5 GB free now) or a Kaggle sign-in for a free GPU (3–5 h per voice, press "Run all").

## Design

### Files
- New `Sources/Voice/VoiceChanger.{h,cpp}` — Natural mode DSP, plain C++17 with a C API, no Apple APIs (not under `Sources/Advanced/`, so no Windows CI). New `Sources/Voice/VoiceModel.{h,mm}` — Realistic mode, Core ML, Objective-C++; real code under `#if __arm64__`, x86_64 gets stubs that say "needs Apple silicon". New `Sources/VoiceLibrary.swift` — voice manifests (built-in + user folder) and `VoiceModelStore` (loads/frees models in the background). `voices/woman.json`, `voices/man.json`, `voices/CREDITS.txt` → `Contents/Resources/Voices/`.
- Changed: `VoiceShifter.swift` (VoiceParams, VoiceStretcher, VoiceChain, VoiceShifter, renderVoiceFile), `Window.swift`, `main.swift`, `Bridging.h`, `build.sh` (per-arch loop: compile `Sources/Voice/*.cpp` and `*.mm -fobjc-arc`, link `-framework CoreML`, copy the voices), README credits.

### Natural mode (DSP, every Mac, default)
Order in `render()`: mic → `voicechanger_analyse` (pitch tracker, pitch mapping, creak) sets Rubber Band's pitch + formant scale → Rubber Band R3 (forced on) → ring → `voicechanger_post` (sibilance → tone EQ → presence → breath) → silent/Soundboard mix/clamp → Pitch Shift Mic. Analysis runs alongside the sound and post uses only IIR filters: **adds no delay** (acceptance: = plain voice ± 2 ms). All buffers made in `voicechanger_new`; analyse/post allocate nothing and take no locks.
- **C API (fixed at Step 0):** `VoiceChangerVoice {targetHz, assumedInputHz, intonation, formant, breathDb, presenceDb, sibilanceKeep, eqAmount, ltas[21]}`; `VoiceChangerPitch {pitchScale, formantScale, voiced, f0In, f0Target, newFrames, frameHz[64], framePos[64]}`; `voicechanger_new/delete/set(voice|NULL, strength)/reset/analyse(in, frames, extraSemitones, out)/post(io, frames, delayFrames)/tune(key, value)/get_stats`.
- **Pitch tracker:** YIN on a ÷3 downsampled copy (÷6 at 96 kHz, none at 16 kHz), 32 ms window, 10 ms hop, 55–600 Hz, threshold 0.12, parabolic interpolation, octave-jump rejection against the running median, median of 3; ~0.1 ms per hop on the sound thread. Voiced = aperiodicity < 0.25 and level > floor + 10 dB and > −50 dBFS.
- **Pitch mapping (target median, like Praat):** median from a 4 s histogram of voiced frames (¼-semitone bins, seeded by `assumedInputHz`); `off = 12·log2(targetHz/median)`; `dev = clamp(st(f0) − st(median), ±12)`; `P_st = s·(off + (intonation − 1)·dev) + extraSemitones`, limited to ±15; smoothed 25 ms, held through unvoiced frames.
- **Creak:** f0 < 70 Hz, or < 0.62 × median, or jitter > 8 % over 3 frames, or aperiodicity 0.25–0.45 → hold the last good pitch, count `creakShare` (the fry itself survives in Natural; Realistic removes it).
- **Formants:** `Feff = formant^(s·clamp(|off|/|12·log2(targetHz/assumedInputHz)|, 0, 1))` (a woman choosing Woman gets almost no formant change), 150 ms glide; Rubber Band formant scale = `Feff / 2^(P_st/12)`.
- **Sibilance (Man):** split at 4.5 kHz; in unvoiced frames crossfade the top band toward the original's top band from a delay line at `delayFrames` by `sibilanceKeep·s`.
- **Tone EQ:** output long-term spectrum (6 s) vs the voice's 21-band `ltas` (from VCTK, `research/voicechanger/make_ltas.py`), normalised over 500 Hz–2 kHz, smoothed ±1 band, × `eqAmount·s`, limited ±6 dB; 8 octave peaking filters 125 Hz–16 kHz (Q 1.41), updated every 256 samples, ≤ 0.05 dB per step.
- **Presence ("smile"):** +`presenceDb·s` peak at 3 kHz, Q 0.9. **Breath:** noise in 4 bands (1.5–2.5, 2.5–4, 4–6, 6–9 kHz), each following the output's own band loudness (5/30 ms), × 10^(breathDb/20)·s, only when voiced.
- **Start values:** Woman {200 Hz, assumed 120, intonation 1.2, formant 1.18, breath −30 dB, presence +2.5, sibilanceKeep 0, eq 0.5}; Man {112 Hz, assumed 205, 0.85, 0.85, off, 0, 0.7, 0.5}.
- **Swift wiring:** `VoiceParams` gets `changer: UnsafePointer<VoiceChangerVoice>?` (points into VoiceLibrary's app-lifetime table) and `strength`; `VoiceStretcher.running = halfSteps != 0 || slowDeeper || changerActive`, `set(changer:)`, `set(changerPitch:formantScale:)` every callback, strength glides 0.15 s on/off; `VoiceChain` owns the `VoiceChanger*` and passes `stretcher.extra` (Deeper when slow) as `extraSemitones`; `VoiceShifter.changer {on, voiceID, strength, realistic}`, sent only when the voice switch and the changer are on (the Soundboard-only pass-through never runs it); `changerState` for the window: off / natural / loading / realistic / fallback(misses) / unavailable(reason); `renderVoiceFile(..., changer:)` uses the same classes.
- **With a voice on (changed 2026-10-15 evening, the owner's rule "only one at a time"):** turning a voice on sets the amount to 0 and "Deeper when slow" off (saved); the number and − 0 + still work and a non-zero amount turns the changer off (tooltip says so); "Deeper when slow" is greyed out and turning it on also turns the changer off; the Natural↔Cartoon slider is ignored and dimmed; the engine never sends an amount or "Deeper when slow" with a voice on; the Soundboard mixes in after the changer; Test plays back the changed voice.

### Realistic mode (AI, Apple silicon only)
- **Model:** RVC v2 style — one shared ContentVec encoder (768-dim, layer 12, 50 frames/s at 16 kHz) + one 48 kHz NSF-HiFiGAN generator per voice; pitch is an explicit input driven by our mapping (creak held at a normal pitch → the model sings through it: fry gone).
- **Runtime: Core ML** on its own pthread (QOS user-interactive), preallocated MLMultiArrays/outputBackings, rings indexed by sample position, libsamplerate resampling (the DrumKeeper pattern on `v2-advanced3-ai`). audio.cpp is plan B if conversion fails. Conversion: move the NSF sine/noise source out of the model (full-precision phase computed in C++), fixed seeded noise, fixed shapes, 8-bit weights, macOS 14 target, no faiss index.
- **API:** `voicemodel_load(encoderPath, voicePath, computeUnits, err)` / `voicemodel_free`; `voicestream_new(model, chainRate, maxFrames, offline, config{hopMs 160, contextMs 480, crossfadeMs 40, solaMs 10, reserveMs 60})` / `delete` / `latency_frames` (fixed) / `push(mic, frames, f0Hz, f0Pos, n)` (sound thread, copies only) / `pull(naturalNow, naturalDelay, out, frames)` / `get_stats`.
- **Per hop (worker):** resample to 16 kHz → ContentVec on context + hop → ×2 frame rate → align pitch → generator renders hop + crossfade + search + ~60 ms margin → resample back → SOLA crossfade → output ring. **Delay ≈ 275 ms fixed** (a 100 ms hop gives ≈ 215 ms at ~1.6× compute; A2 picks the hop so 99 % of hops finish within 60 % of the hop time).
- **Fallback, never silence and never the raw mic:** Natural keeps running, delayed to the same fixed latency, crossfaded in (10 ms) while loading, on a late hop, or on error; misses counted; the card shows it.
- **Compute units:** A2 measures CPU / GPU / Neural Engine / all and defaults to the steadiest within budget (`--compute` overrides). ~300 MB memory while on; `VoiceModelStore` loads once in the background, frees when off; switching voice/quality rebuilds the chain once loaded (0.1–0.3 s, Natural meanwhile). A 16 kHz Bluetooth mic works (worse).
- **Model files — bundled in the installer (owner's choice):** `Contents/Resources/Voices/{contentvec, woman, man}.mlmodelc` (~95 + 28 + 28 MB, 8-bit) + CREDITS; the pkg grows to ~160 MB; no download code. Intel Macs carry the files unused.
- **Adding voices later:** a folder with `voice.json` {id, name, version, natural{…}, realistic{model, encoder, rate, eqAmount}, credits} in `Resources/Voices/` (built-in) or `~/Library/Application Support/Pitch Shift/Voices/<id>/`; a voice with only a `natural` block works on every Mac; bad folders are skipped and listed by `--list-voices`.
- **Training our two voices:** VCTK 0.92 (CC BY 4.0, 48 kHz): Woman = 8 female speakers with median pitch 185–220 Hz, Man = 8 male at 100–125 Hz, mixed accents, ~20 min each, pooled under one speaker id (a blend, nobody cloned), 4 + 4 speakers held out for tests; files fetched one by one. Base: RVC v2 pretrained 48 kHz (MIT), ~200 epochs. Scripts (git-ignored) in `research/voicechanger/`: `train/{pick_speakers.py, prep_vctk.py, train_rvc.sh, kaggle.ipynb}`, `convert/{convert_contentvec.py, convert_generator.py, verify_coreml.py}`, `pack_voices.sh`. Credits (README + CREDITS): VCTK (CSTR, University of Edinburgh, CC BY 4.0), RVC (MIT), ContentVec (MIT). Research only, never shipped: single-speaker base models, LLVC f_8312_32k.

### The third card, "Voice changer"
- `ShiftCard.init(title:extraRows:showsAmount: Bool = true)`: with `false` no big number and no − 0 + (`keyViews = [toggle, picker]`, `spread()` adjusts, `show(on:active:)` overload); `show(…, amountActive:)` dims only the voice card's number and buttons while a voice is on.
- Contents: header "Voice changer" + switch; picker Woman, Man, then added voices (no "Off" item — the switch does that); Strength `GradientSlider(left: "Light", right: "Full")` default 1; `switchRow("Realistic", …)` hidden on Intel (Natural = that switch off; tooltip shows fallback). Turning the changer on also turns "Your voice" on; turning the voice off dims the changer card.
- **Realistic alert** (Advanced-style, first time only unless `hideChangerAlert`): "Realistic voices add delay" / "Your voice reaches the call about a quarter second later." Buttons Turn On / Cancel / Don't show again (saved only on Turn On). No alert when turning off or restoring at launch.
- **Settings (per user):** `changerOn` false, `changerVoice` "woman", `changerStrength` 1, `changerQuality` "natural"|"realistic", `hideChangerAlert` false. Previews never write.
- **Layout:** replace `minSide/minStacked/stacked` with `enum Layout { row, split, stack }`: row = three side by side (min 870×369); split = What you hear left full height, Your voice with Voice changer under it on the right (min 588×575); stack = one column (min 306×844). `measure()`: contentMin (306, 369), contentMax (1300, max(640, stack height + 96)) limited to the screen; if stack doesn't fit the screen, drop it and require ≥ 588 wide. `allowed(size)` accepts any layout's minimum, else grows to the closest (prefer the current). `bestScale(size, layout)`: row width (W−72)/3, height max(h1,h2,h3); split width (W−56)/2, height max(h1, h2+16+h3); stack width W−40, height h1+h2+h3+32. `arrange()` picks the largest scale, keeps the current layout unless another beats it by 0.05; `settle()` animates voice and changer cards. An old 588×369 window opens as 588×575.
- `menuNeedsUpdate`: three branches (hear / mic / changer → `rebuildChangerMenu()` rescans the voice folders). Tab order: `… + changerCard.keyViews + [strength, realisticSwitch]`. `refresh()`: changer card active when `changerOn && voiceOn && installed && hasMic`. Preview states: `changer`, `changer-man`, `changer-realistic`, `changer-alert`, `changer-fallback`, `changer-intel` (work with `light`, `resize`, `--size`).

### Command line and measurement
- Flags: `--voice Woman|Man|<id>`, `--strength S`, `--quality natural|realistic`, `--compute cpu|gpu|ane|all`, `--voices-dir DIR`, `--changer-tune "k=v,…"`, `--changer-stats`, `--list-voices`. `--render-voice … --voice Woman --quality realistic` runs the model inline (never misses) and prints per-second stats; `--test-voice … --voice Woman [--quality realistic] [--watch] [--seconds 60]` prints delay, dropouts, overloads, AI misses/fallback time, CPU (measure delay with a speech file that starts after 1 s of silence, not a sine).
- Harness in `research/voicechanger/` (own venv): `make_set.py` (`say` voices: female Samantha, Karen, Moira, Tessa, Flo, Shelley, Sandy; male Daniel, Fred, Ralph, Eddy, Reed, Rocko, Grandpa; 10 Harvard sentences each; the held-out VCTK speakers = the main set; Apple Loops "Vox Melodics" sung clips for listening only; everything in the scratchpad, deleted after), `render_all.sh` (original, plain shift +10/−8, Natural Woman/Man, Realistic Woman/Man), `measure.py` (JaesungHuh gender classifier MIT; SpeechBrain ECAPA similarity to source and to target/source-gender averages; Distill-MOS; Whisper base.en WER; Parselmouth: median pitch, range, F1–F3, H1–H2, CPP, creak share, jitter) → CSV + `results/*.md`.
- **Pass marks (each mode and direction):** ≥ 80 % of clips judged the target gender AND ECAPA margin toward the target gender beats the plain shift on ≥ 80 % of clips AND Distill-MOS ≤ 0.3 below the plain shift AND WER ≤ original + 2 points; median pitch within ±10 % of target; creak share ≤ original (Realistic: ≤ half). Never judge by the classifier alone.
- **Blind listening set** `~/Downloads/Pitch Shift voice changer samples/`: 6 held-out VCTK clips (3 men, 3 women) × {original, plain shift, Natural, Realistic} + 4 genuine recordings, shuffled `01.m4a`…`28.m4a` (< 30 MB), `rate.txt` ("man or woman", "sounds real 1–5"), answers in a separate folder. Pass: ≥ 80 % target gender and "real" within 1 point of the genuine recordings.

## The workflow (Opus; 4 agents + an optional 5th, within the owner's "no more than 5")
**Step 0 (main session, no agent, after 2.0.2 merges):** branch `v2-voice-changer` from main; commit the contract (both headers with do-nothing stubs, `voices/*.json` start values, `VoiceParams` fields + VoiceShifter stubs, build.sh changes, this plan as `notes/voice-changer-plan.md`); check the build is byte-identical with the changer off.

| Agent | Delivers | Hand-off gate | Sessions |
|---|---|---|---|
| **A2 AI** (starts now, in `research/voicechanger/`; later `VoiceModel.mm`) | Gate 1: a research-only prototype (f_8312 / base RVC) converted to Core ML and running offline + live through the VoiceModel API; timings per compute unit; if Core ML fails try audio.cpp; if neither fits, stop and report (Natural ships alone). Gate 2: our Woman and Man trained, converted to 8-bit, checked against PyTorch; `results/realistic.md`; the `.mlmodelc` files for `Resources/Voices/`; `VoiceModelStore` | delay fixed ≤ 300 ms; 99 % of hops within 60 % of hop time; 60 s live with no misses after loading; forced misses (`aiSlowMs=200`) fall back with no frame at the speaker's own pitch; pass marks met or the shortfall in numbers | 3–4 (+ training running) |
| **A1 DSP + CLI + harness** (after Step 0) | `VoiceChanger.cpp`, Swift wiring, flags, `make_ltas.py` + tables, harness, `results/natural.md` (plain shift vs Natural) | changer off byte-identical; Natural delay = plain ± 2 ms; analyse + post ≤ 0.2 ms per 10 ms of audio (never > 0.5); 60 s no dropouts; no allocation/locks on the sound thread (reviewed) | 2 |
| **A3 card + layout + voice library** (parallel with A1) | section "The third card", manifests, `--list-voices` | hidden screenshots of every changer preview at 870×369, 588×575, 306×844, 1300×640 and light; resizing through all three layouts without jumps; nothing activates; Intel preview hides Realistic | 1.5 |
| **A4 integration + tuning + samples + checks** | merges dsp → ui → ai; connects card ↔ engine; ≤ 3 tuning rounds with `--changer-tune`, final values into voice.json; blind set; all end-to-end checks; README credits; notes; plain-words report; commit; push `v2-voice-changer`; PR to main | every check below passes or each miss is named with numbers | 1.5–2 |
| A5 (optional, owner's OK) | Intel/Rosetta hardening, installer size/packaging of the voices, docs | | ≤ 1 |

Rules for all: device tests only with the delay branch's guards (refuse while any mic is busy or the app is open), `--mic "MacBook Pro Microphone"`, hidden previews, never Apple Music or the owner's recordings, `nice -n 15`, renders in the scratchpad and deleted (stop below 3 GB free), Windows untouched, commits in plain words with the Opus co-author line, one push at the end (free app → PR).

## End-to-end checks
1. Changer off changes nothing: `--render-voice` on 3 files × {`--steps 3`; `--steps -4 --cartoon-amount 0.5`; `--steps 0 --slow-deeper`; `--steps 5 --cartoon`} + `--render-file` normal and advanced, all byte-identical to the base build; `--test-voice --tone 440 --steps 3` matches.
2. Delay: Natural = base ± 2 ms (~57 ms once the delay fix is in); Realistic fixed and ≤ 300 ms.
3. CPU (M3 Pro): Natural stage ≤ 2 % of one core; Realistic ≤ 35 % of one core (or Neural Engine equivalent).
4. 60 s runs per mode and voice: no dropouts, overloads or AI misses after loading.
5. Harness pass marks for both modes and directions; blind set delivered.
6. Intel: `lipo -info` shows both slices; the Intel slice renders Natural under Rosetta; `--quality realistic` there says "needs Apple silicon" and falls back.
7. Windows untouched: `git diff --stat main...v2-voice-changer -- windows/ Sources/Advanced/` empty.
8. No leak of the real voice: while falling back, loading or switching, no output frame at the speaker's unchanged pitch.

## Effort and risks
~8–10 agent sessions plus 5–10 hours of training running. Natural mode will fool the classifier but people may still hear "a man with a high voice" (Rubber Band keeps the speaker's own pulses); only Realistic replaces them — if Natural misses the 80 % listener mark, say so. Training needs GPU time (Kaggle sign-in or ≥ 15 GB free disk here); blended voices may sound "averaged" and need a second round; 8-bit Neural Engine models may lose quality (audio.cpp is plan B). The installer grows to ~160 MB. Neural Engine stutter on 8 GB/fanless Macs → brief switches to Natural (default to CPU if it fits, shorter-hop option, miss counter). ~250–275 ms Realistic delay feels laggy; the user chooses it, Natural stays the default. Our voices are blends, not real people; no cloning of named people.

## What was built (2026-10-15)

**For the user:** a third card "Voice changer" with a switch, a voice picker (Woman, Man, then any voices added to
`~/Library/Application Support/Pitch Shift/Voices/`), a Light…Full Strength slider and a "Realistic" switch (hidden on
Intel Macs). Turning it on also turns "Your voice" on, sets the amount to 0 and "Deeper when slow" off (only one at a
time; see "Fixes after the first listen"); the Soundboard mixes in after it. Smallest windows: three cards in a
row 870×369, two columns 588×548, one column 306×817 (the card is 163 pt tall, not the planned 190).

- **Natural mode** (every Mac, the default): `Sources/Voice/VoiceChanger.{h,cpp}`, as designed above. No added delay
  (offline: Woman 45.0 ms vs 44.6 ms for a plain shift at the same pitch, Man 71.4 vs 70.7), 0.024–0.030 ms of work
  per 10 ms of sound (worst 0.074; 0.27 under Rosetta), no memory taken and no locks while the sound runs.
- **Realistic mode** (Apple silicon): `Sources/Voice/VoiceModel.{h,mm}` + `Sources/VoiceModelStore.swift`. **No
  training was needed:** the RVC v2 48 kHz base model (MIT) already holds all 109 VCTK speakers; Woman and Man are
  blends of the same 8 + 8 speakers the plan picked for training. Core ML, 8-bit (zero-point mode), 160 ms pieces
  with 1 s of past sound. Fixed delay 275.5 ms (285.5 ms on the CPU only; 214 ms in offline renders). Default:
  speech reader on the Neural Engine, voice model on the GPU. If a piece is late, Natural fills in with 10 ms
  crossfades (never silence, never the raw mic). First load on a Mac 13–30 s (macOS prepares the models), then
  0.4–2.3 s; 4–6 % of one core; 270–330 MB while on.
- **Model files** (133 MB zipped, 145 MB unpacked) are not in git. `build.sh` takes them from `build/voices/` or
  `research/voicechanger/models/` (this or the main checkout), or downloads them from the addresses in
  `voices/models.txt`, checks their SHA-256 sums and unpacks them into `Contents/Resources/Voices/`. The release tag
  in `voices/models.txt` is still `PLACEHOLDER` (filled in when the files are uploaded at release time). Without the
  files the app builds and only Natural works.

### Final voice values (`voices/*.json`, Natural block)

| | target pitch | assumed input | intonation | formant | breath | presence | sibilance kept | tone EQ |
|---|---|---|---|---|---|---|---|---|
| Woman | 200 Hz | 120 Hz | 1.2 | **1.21** (start 1.18) | −30 dB | +2.5 dB | 0 | 0.5 |
| Man | 112 Hz | 205 Hz | **0.75** (start 0.85) | 0.85 | off | 0 | **0** (start 0.7) | 0.5 |

### How the values were picked (three rounds with `--changer-tune`, offline, warmed up with 8 s of the same speaker)

Two sets: held-out VCTK speakers (4 men, 4 women, 10 sentences each; never used for the tone tables) and the Mac's
`say` voices (7 + 7, 10 sentences each). "Voice print" = how often the ECAPA voice print moves further toward the new
sex than the plain shift does (mark 80 %). Word errors are Whisper's (mark: original + 2 points).

| men → Woman | VCTK: judged woman / voice print / word errors / creak | `say`: judged woman / voice print / word errors / creak |
|---|---|---|
| start values | 92 % / 90 % / 6.1 % / 0.056 | 67 % / 89 % / 22.9 % / 0.034 |
| **formant 1.21 (chosen)** | **95 % / 92 % / 5.7 % / 0.055** | **71 % / 87 % / 23.5 % / 0.034** |
| intonation 1.1 | 92 % / 85 % / 5.7 % / 0.048 | 67 % / 89 % / 21.9 % / 0.030 |
| plain shift +10 | 35 % / — / 6.1 % / 0.042 | 27 % / — / 18.7 % / 0.032 |
| original men | 0 % / — / 3.3 % / 0.060 | 0 % / — / 12.7 % / 0.054 |

| women → Man | VCTK: judged man / voice print / word errors / creak | `say`: judged man / voice print / word errors / creak |
|---|---|---|
| start values | 100 % / 78 % / 9.2 % / 0.074 | 96 % / 84 % / 22.2 % / 0.025 |
| sibilance kept 0 | 100 % / 90 % / 8.1 % / 0.073 | 96 % / 84 % / 18.2 % / 0.025 |
| **sibilance kept 0 + intonation 0.75 (chosen)** | **100 % / 90 % / 8.1 % / 0.069** | **94 % / 83 % / 19.4 % / 0.023** |
| plain shift −8 | 2 % / — / 8.1 % / 0.069 | 46 % / — / 16.8 % / 0.030 |
| original women | 0 % / — / 4.6 % / 0.072 | 1 % / — / 9.2 % / 0.018 |

Why: Woman formant 1.21 is best on the VCTK set and does not lower the `say` set's "judged woman" below the start
values. Man intonation 0.75 brings the creak share under the original's on VCTK (0.069 vs 0.072, the only VCTK mark
it missed) and keeps more clips inside ±10 % of the target pitch (95 % vs 88 %); on the `say` set it is one clip lower
on "judged man" and on the voice print and +1.2 points on word errors, which was not counted as clearly worse. Quality
(Distill-MOS) stays within 0.15 of the plain shift in every version above, and the median pitch lands at 189–191 Hz / 110–111 Hz.

### Realistic mode numbers (each clip rendered from a cold start; `research/voicechanger/results/realistic.md`)

| direction, set | judged target | voice print | quality vs plain | word errors (mark) | pitch | creak (mark) |
|---|---|---|---|---|---|---|
| women → Man, VCTK | 100 % | 100 % | +0.25 | 3.6 % (≤ 3.8) | 113 Hz | 0.015 (≤ 0.041): **all marks met** |
| men → Woman, VCTK | 100 % | 98 % | +0.18 | **10.2 %** (≤ 5.4) | 199 Hz | **0.029** (≤ 0.024) |
| men → Woman, `say` | 100 % | 90 % | +0.88 | **23.8 %** (≤ 14.7) | **174 Hz** (cold start) | 0.018 |
| women → Man, `say` | 100 % | 97 % | +1.20 | **21.5 %** (≤ 11.2) | 105 Hz | **0.014** (≤ 0.009) |

### End-to-end checks

| check | result |
|---|---|
| 1. Changer off changes nothing | 14/14 offline renders byte-identical to main (3 speech files × 4 voice settings + music normal and Advanced), re-run after the final values |
| Natural unchanged by the AI merge | 21/21 renders byte-identical |
| 2–4. Delay, CPU, 60 s runs (offline) | Natural adds ≤ 1 ms; Realistic fixed 275.5 ms live estimate / 214 ms offline, 0 late pieces in 75 s with the app's own code (A2's real-time test program) |
| 5. Blind listening set | made: `~/Downloads/Pitch Shift voice changer samples/` (28 clips + `rate.txt`), answers in `… - answers/` |
| 6. Intel | both halves in the app; under Rosetta `--quality realistic` says "Realistic mode: needs Apple silicon; Natural mode is used"; its Natural output matches Apple silicon's (largest difference 0.00009) |
| 7. Windows untouched | no change under `windows/`, `Sources/Advanced/`, `.github/` |
| 8. No leak of the real voice | forced late pieces: Natural filled in with 0 frames at the speaker's own pitch (A2's real-time test program) |
| Build | clean, the same compiler warnings as main |
| Live device tests | **not run yet**: the guard refused every time because the Pitch Shift app was open (the scripts are ready, see below) |

### Fixes after the first listen (2026-10-15 evening)

The owner tried the test build: "voice cracks on the high end for the female voice (I think at the e's it was
struggling) and sudden voice drops for the guy, at the same e soundings", in **Realistic** mode, saying "testing
testing".

**Cause (measured):** the pitch reader's octave fix compared each 10 ms frame with the median of the last 2 s of
raw pitch and doubled any frame more than 9 half-steps below it. A real fall at the end of a word ("testing",
"sweets", "these": the "i"/"ee" sounds) goes that low, so it was read an octave too high for several frames. The AI
voice follows the read pitch directly, so it jumped an octave there (Woman: a crack upward; Man: a jump out of the
low voice). Natural showed it smaller (only through the intonation part). Example, Daniel's "sweets": real pitch
95 → 67 Hz, read as 133 Hz; the Man voice's pitch went 79 → 120 Hz. A second, smaller cause: a new chain starts
the speaker's median from a guess (Woman 120 Hz, Man 205 Hz) and the median jumped to the real one after about a
second, moving the whole pitch at once.

**Fix (`Sources/Voice/VoiceChanger.cpp`, `voicechanger_analyse`):** the median-based fix is gone. Each voiced frame's
pitch may be YIN's value, half or double it; a small running path search picks the one that moves least from frame
to frame (1 point per half-step; taking double costs 3.5, half 4.5; past 10 half-steps from a known median 0.5 per
half-step), and a frame's choice is settled when the next frame is in (the same one-frame lag as before, so no
delay is added). The pitch handed to the AI voice: through creak it moves with a gradual fall (not below 0.62 × the
median) and holds through a sudden drop or rough frames; an aperiodic moment up to 80 ms after voice holds it but
never starts it; it is eased into 9 (at most 12) half-steps above and 6 (at most 9) below the voice's own pitch, and
moves at most 2 half-steps per 10 ms while singing. The speaker's median glides (0.3 half-steps per 10 ms) instead
of jumping; its first guess is still worth 1 s of voice, but frames more than 7 half-steps from it wear it off 40
times faster, so a guess that doesn't fit (a man using the Man voice) is gone after ~0.1 s (a light guess for
everyone cost Natural Man's voice print 90 → 82 %); a new chain starts from the median the last one measured
(`voicechanger_set_speaker`, so switching voices in Realistic doesn't start from a guess again). Tuning keys:
`octUpCost octDownCost jumpCost rangeSt rangeCost contFrames gapFrames warmFrames seedFarSt seedFarFade medianGlideSt
aiBandSt aiMaxSt aiBandLowSt aiMinSt aiHoldFrames aiSlewSt`.

**Numbers** (test set: "testing testing, one two three, easy peasy, see me eat these sweets, testing testing" by
Samantha, Daniel, Eddy, Shelley, Reed, Flo + 8 held-out VCTK speakers with many "e" sounds; Praat as reference;
crack = the output pitch jumps more than 6 half-steps within 30 ms while the input stays within 3 for ±30 ms):

| | before | after |
|---|---|---|
| Realistic Woman cracks (14 clips, offline, cold start) | 11 | 4 |
| Realistic Man cracks | 5 | 2 |
| Realistic, real-time test program (input looped, 20 s each) | Woman 8 in 46 s, Man 13 in 54 s | Woman 4 in 44 s, Man 1 in 53 s |
| Natural Woman / Man cracks | 5 / 5 | 1 / 3 |
| tracker octave errors vs Praat (all 14 clips, cold) | 181 (165 where Praat reads creak) | 65 (51) |
| AI pitch jumps > 6 half-steps in 30 ms, Woman / Man (cold; warmed up) | 22 / 14; 22 / 18 | 4 / 0; 2 / 3 |

What is left: Realistic still turns very creaky word ends into a short whisper (the reader calls them unvoiced;
singing them with YIN's rough pitch was tried and made it worse), a sound that starts with two misread frames glides
up for ~40 ms, and once the voice model itself rendered a low word end an octave down (the pitch it was given was
smooth). Natural's ones are the speaker's own creak passed through. Natural delay unchanged (live-sim, 3 clips × 2
voices: 44.1–71.7 ms vs 44.4–72.3 before; Man 1.8 and 3.4 ms lower on two clips), changer off 14/14 byte-identical,
Realistic offline 214 ms fixed and 0 late pieces, live test program 275.5 ms and 0 late pieces, no new compiler
warnings, the Intel half matches (Natural, largest difference 0.00006).

Natural marks after the fix (VCTK held-out set, warmed up, same measures as above):

| | judged | voice print | quality vs plain | word errors | pitch | creak |
|---|---|---|---|---|---|---|
| Woman, before → after | 95 → 95 % | 92 → 92 % | +0.03 → +0.02 | 5.7 → 6.1 % | 189 → 199 Hz | 0.055 → 0.055 |
| Man, before → after | 100 → 100 % | 90 → 88 % (one clip) | −0.13 → −0.15 | 8.1 → 8.5 % | 111 → 111 Hz | 0.069 → 0.067 |

**Only one at a time (owner's rule, same evening):** a voice from the Voice changer and a pitch change can't be on
together. Turning a voice on sets the amount to 0 and "Deeper when slow" off (saved; they stay so when the changer
goes off); a non-zero amount (− 0 + or typing) or turning "Deeper when slow" on turns the changer off (tooltips say
so; "Deeper when slow" is greyed out but still works); the engine never sends an amount or "Deeper when slow" with a
voice on; settings saved with both on: the changer wins. In Realistic mode the Light…Full slider only moves the pitch
(the AI voice always sounds like the voice), so it reads "Your pitch … Woman's pitch" there (relabelled rather than
hidden: hiding it would change the card's height and the window's layouts). Command line: `--steps` and
`--slow-deeper` are ignored with `--voice` (a note is printed). `--test-button --voice Woman [--quality realistic]
[--file F]` records and plays back the changed voice (not run: it plays sound out loud; the live tests were refused
for 15 minutes because the Pitch Shift app was open).

### Shortfalls, in plain words
- **Natural** fools the man/woman classifier, but a voice print still hears the same person: "a man with a
  convincing high voice". Two of the Mac's `say` men almost never pass (Ralph 0 of 10 clips, Rocko 1 of 10), which
  keeps the `say` set's Woman at 71 %; the other five `say` men pass on 48 of 50 clips.
- **Word errors** miss the mark in every version, the plain shift too: changing the pitch this far makes some words
  harder to make out.
- **Realistic Woman** slurs some words (10 % word errors vs 3.4 % for the original voices). The cause is converting
  live without hearing ahead; only more delay would fix it (1 s of past sound was the best setting measured).
- **A game using the GPU** can make Realistic fall behind; Natural then fills in and the card shows it.
- **Nobody has listened yet**, and the live microphone tests still have to run with the Pitch Shift app quit.

### Tools (git-ignored, in `research/voicechanger/`)
`a1/harness/` (render, measure, pass-mark tables), `a4/` (`tune.sh`, `check1.sh`, `blind.py`, `devtests.sh`,
`live_fallback.py`; tuning tables in `a4/results/r1…r3*/set_*.md`), `pretrained/` (voice blends), `convert/` (Core ML),
`bench/` (real-time test program), `results/` (A2's reports).
