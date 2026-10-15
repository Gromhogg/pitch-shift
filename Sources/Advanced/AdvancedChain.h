// Advanced processing engine for "What you hear": pitch shifting that keeps the music balanced at big shifts.
// Recipe ("balanced3", from the research rounds 2-4, with the bass fix and the tone fix made after 2.0.0): the bass is
// moved down an octave ("fold") for pitch-up, the original's top end ("air") is kept for pitch-down, and a gentle
// adaptive EQ steers the long-term tone back toward the original (going up, it no longer cuts bass notes that the fold
// moved; it knows which way the pitch went: going down it trims the deep bass, going up it keeps more of the top).
// Rubber Band (R3, real-time) does the shifting. A safety peak limiter at the very end keeps the output at or below
// -0.3 dBFS (it does nothing while the sound stays under that).
//
// Plain C API, so Swift can call it through the bridging header.
// Threading: create, use and delete from one thread at a time (the engine also runs one helper thread of its own
// that tidies up spare Rubber Band shifters; it never touches the sound).
// Real-time safe: advanced_process, advanced_set_semis, advanced_set_tone and advanced_reset make no memory, take no
// locks and do no file or console I/O. Everything is set up in advanced_new.
#ifndef ADVANCED_CHAIN_H
#define ADVANCED_CHAIN_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AdvancedChain AdvancedChain;

// Flags for advanced_new.
enum {
    ADVANCED_RANGE_12 = 1,  // only -12..+12 half-steps (larger amounts are clamped); lowers the delay to about 138 ms
};

// sampleRate: 44100, 48000, 96000 (others work too). channels: 1 or 2. maxFrames: the largest `frames` you will
// pass to advanced_process (e.g. 4096). Returns NULL if it can't be made.
AdvancedChain *advanced_new(double sampleRate, int channels, int maxFrames, int flags);
void advanced_delete(AdvancedChain *chain);

// The amount in half-steps (-24..+24, 0.01 steps). Call any time on the processing thread. The new amount is heard
// about 0.2-0.3 s later, faded in over 80 ms; quick repeated changes always end at the latest amount.
// At 0 the output is the delayed input, untouched.
void advanced_set_semis(AdvancedChain *chain, double semis);

// Bass and treble in dB (-12..+12 each, default 0): a low shelf at 150 Hz and a high shelf at 5 kHz on the finished
// sound, at every amount (0 too). Call any time on the processing thread. The gains glide 0.25 dB per 32 samples
// (about 16 ms for 6 dB), so moving them doesn't click; set before the first advanced_process, the glide is over
// before any sound comes out. At 0 and 0 the sound is exactly as without it.
void advanced_set_tone(AdvancedChain *chain, double bassDb, double trebleDb);

// Forget all sound (for example after a pause). Keeps the amount and the bass and treble.
void advanced_reset(AdvancedChain *chain);

// in: `channels` pointers to `frames` samples. keep: NULL, or `channels` pointers to a part of `in` that must stay
// unshifted (it is taken out, the rest is processed, and it is added back with the same delay).
// When keep starts (after being NULL or all zeros for 0.25 s) it is faded in over 30 ms, so switching it on mid-song
// doesn't click. Switching it off is up to the caller: going straight to NULL mid-sound is a hard step, so fade the
// keep signal to zero first (or keep passing it).
// out: `channels` pointers, gets exactly `frames` samples: the processed sound delayed by advanced_latency_frames().
// frames: 1..maxFrames. out may be the same memory as in.
void advanced_process(AdvancedChain *chain, const float *const *in, const float *const *keep, float *const *out, int frames);

// The delay in frames. It never changes during the engine's life, whatever the amount.
int advanced_latency_frames(const AdvancedChain *chain);

// For checks and the app's status line.
typedef struct {
    double heardSemis;     // the amount being heard now (the newest one once its fade is done)
    int changing;          // 1 while a new amount is getting ready or fading in
    long long underruns;   // times a shifter's sound was not ready in time (should stay 0)
    long long switches;    // amount changes that have been faded in
    int shiftersRunning;   // Rubber Band shifters in use right now (0-6)
} AdvancedInfo;
void advanced_get_info(const AdvancedChain *chain, AdvancedInfo *info);

#ifdef __cplusplus
}
#endif

#endif
