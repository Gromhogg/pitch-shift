// Pulse shifter: changes the pitch and the voice shape (formants) of a voice by moving whole vocal-fold pulses
// (pitch-synchronous overlap-add, "PSOLA"), for the voice changer's Natural mode.
//
// Why: Rubber Band works on short spectra and loses the crisp once-per-pulse attack of a voice; at big moves (8 to
// 10 half-steps, what the voice changer does) that turns into a steady, reedy buzz ("sounds like a pitch shift").
// This keeps each pulse whole: it finds the pulses in the mic sound (one mark per pulse), cuts a two-pulse piece
// around each mark, and lays the pieces down again at the new pitch. The voice shape moves by squeezing or
// stretching each piece in time. Sounds without a pitch ("s", "f", breath) are only reshaped, never repeated.
//
// Output sample k is made from the mic sound around input sample k (no time stretch); it comes out once input
// k + latency has been given. Plain C API (C++17 inside, no Apple APIs) for Swift through the bridging header.
// Threading: new, tune and delete from one thread; set, process, available, retrieve, reset from the sound thread.
// Real-time safe: set, process, available, retrieve and reset make no memory, take no locks and do no I/O.
#ifndef PULSE_SHIFTER_H
#define PULSE_SHIFTER_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PulseShifter PulseShifter;

// sampleRate: 8000 ... 192000. Returns NULL if it can't be made.
PulseShifter *pulseshifter_new(double sampleRate);
void pulseshifter_delete(PulseShifter *shifter);

// Forgets all sound (output starts again `latency` samples after the next input).
void pulseshifter_reset(PulseShifter *shifter);

// The pitch scale (new pitch / old pitch) and the voice shape scale (1.21 = formants 21% higher) for the samples
// given next. Cheap: call once per callback.
void pulseshifter_set(PulseShifter *shifter, double pitchScale, double shapeScale);

// Gives the next `frames` mic samples.
void pulseshifter_process(PulseShifter *shifter, const float *in, int frames);

// How many shifted samples are ready, and takes up to `frames` of them into `out` (returns how many it took).
int pulseshifter_available(const PulseShifter *shifter);
int pulseshifter_retrieve(PulseShifter *shifter, float *out, int frames);

// The fixed delay in samples (output sample k needs input up to k + latency).
int pulseshifter_latency(const PulseShifter *shifter);

// Counts since the last reset: pieces laid down (voiced ones), pieces that had to use an older pulse because the
// delay was too short to see the next one ("guessed"), and times the output had to wait for sound ("waited").
typedef struct PulseShifterCounts {
    long long pieces, voicedPieces, guessed, waited;
} PulseShifterCounts;
void pulseshifter_get_counts(const PulseShifter *shifter, PulseShifterCounts *out);

// Changes a setting by name (tuning, before use; call pulseshifter_reset after). Keys and defaults in
// PulseShifter.cpp (pulseLatencyMs, pulseWinMs, ...). Returns 1 if the key is known, else 0.
int pulseshifter_tune(PulseShifter *shifter, const char *key, float value);

#ifdef __cplusplus
}
#endif

#endif
