// Voice changer, Realistic mode: lets sounds that are not a voice through as they are (3.4).
// Claps, finger snaps, knocks, taps, keyboard keys and mouse clicks (short, sharp sounds that die away fast, with
// quiet or other such sounds around them) and whistles (a near-pure tone, about 0.6-4.5 kHz, with nothing at a
// voice's pitch under it) are heard as the original mic sound, at the same delay, instead of what the AI voice makes
// of them. Everything else (speech, breaths, laughs, coughs, sneezes, sniffs, hums, sighs, a click while talking)
// stays the AI voice: when in doubt, the gate stays shut.
//
// It listens to the mic as it comes in (VoiceStream's push) and decides with up to ~0.2 s of look-ahead, which the AI
// voice's fixed delay already gives: the stream reads the gate's weight for the mic sample it is playing.
//
// Plain C API (C++17 inside, no Apple APIs). Create, tune and delete on one thread; push, weights and get_stats on the
// sound thread. Real-time safe: push and weights make no memory, take no locks and do no I/O.
#ifndef SOUND_GATE_H
#define SOUND_GATE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SoundGate SoundGate;

typedef struct SoundGateStats {
    int64_t taps;          // short sounds let through
    int64_t tapsHeld;      // short sounds kept as the AI voice (something else near them, or not short enough)
    int64_t whistles;      // whistles let through
    double passedSeconds;  // time the original sound was heard (weight above 0.5)
} SoundGateStats;

// One decision, for tests (soundgate_events).
typedef struct SoundGateEvent {
    int64_t start, end;    // mic samples (end: one past; -1 = not ended yet)
    int kind;              // 1 = short sound, 2 = whistle
    int passed;            // 1 = let through, 0 = kept as the AI voice
    int reason;            // why not: 1 = sound before it, 2 = sound after it, 3 = it doesn't die away fast enough,
                           // 4 = a voice in it, 5 = too late to decide, 6 = too early (the room's noise not known yet),
                           // 7 = its sound gathers at a few pitches like a voice's (a click's is spread out)
    float peakDb, floorDb;
} SoundGateEvent;

// rate: the mic's sample rate (8000 ... 384000). Returns NULL if it can't be made.
SoundGate *soundgate_new(double rate);
void soundgate_delete(SoundGate *gate);

// Look-ahead the gate needs (mic samples): a sample's weight is final once the gate has heard this much after it.
int soundgate_lookahead_frames(const SoundGate *gate);

// Fits the gate to the look-ahead it will have (mic samples between the newest pushed sample and the one whose weight
// is read; the AI voice's smallest fixed delay less one callback): the lead-in is shortened if needed. Returns 0 if
// even that is too little (then every weight is 0). Call before the first push.
int soundgate_fit(SoundGate *gate, int lookaheadFrames);

// Sound thread: the next mic samples (positions count from 0 on the first call).
void soundgate_push(SoundGate *gate, const float *mic, int frames);

// Sound thread: the weight of the original sound (0 = the AI voice ... 1 = the original) for mic samples
// [pos, pos + n), crossfaded (10 ms). pos must not go back. Returns 1 if any weight is above 0.
int soundgate_weights(SoundGate *gate, int64_t pos, int n, float *weights);

void soundgate_get_stats(const SoundGate *gate, SoundGateStats *out);

// Tests: copies up to max of the latest decisions (oldest first); returns how many.
int soundgate_events(const SoundGate *gate, SoundGateEvent *out, int max);

// Tuning keys (all start with "sg"; see SoundGate.cpp). Returns 1 if the key is known.
int soundgate_tune(SoundGate *gate, const char *key, float value);

#ifdef __cplusplus
}
#endif

#endif
