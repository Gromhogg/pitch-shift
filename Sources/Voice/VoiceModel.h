// Voice changer, "Realistic" mode: an AI voice model (RVC v2 style: a ContentVec encoder + one voice generator per
// voice) run with Core ML on its own worker thread. Apple silicon only; on Intel every call says so and the app keeps
// using Natural mode.
//   sound thread: voicestream_push (copies the mic + the pitch from voicechanger_analyse) and voicestream_pull (takes
//   the finished AI voice, a fixed delay later; while loading, on a late piece or an error it plays Natural mode's
//   sound delayed to the same fixed delay instead, crossfaded; never the raw mic). A new stream plays at its fixed
//   delay from the start: silence until Natural's sound reaches it, then the AI voice from its first piece.
//   worker thread (made by voicestream_new): resample, encoder, generator, crossfade into the output ring.
//
// Plain C API (Objective-C++ inside), so Swift can call it through the bridging header.
// Real-time safe: voicestream_push, voicestream_pull and voicestream_get_stats make no memory and take no locks.
#ifndef VOICE_MODEL_H
#define VOICE_MODEL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Which chips run the models (--compute). AUTO = what Gate 1 measured as best: the encoder on the Neural Engine and
// the voice generator on the GPU, falling back to the CPU if loading fails.
enum {
    VOICEMODEL_COMPUTE_AUTO = 0,
    VOICEMODEL_COMPUTE_CPU = 1,
    VOICEMODEL_COMPUTE_GPU = 2,   // CPU and GPU
    VOICEMODEL_COMPUTE_ANE = 3,   // CPU and Neural Engine
    VOICEMODEL_COMPUTE_ALL = 4,
};

typedef struct VoiceModel VoiceModel;    // the loaded models (shared by the streams that use them)
typedef struct VoiceStream VoiceStream;  // one running conversion (one per voice chain)

// Sizes of the pieces the worker converts (milliseconds). Defaults: 160 / 480 / 40 / 10 / 70 / 0 (the reserve was 60 before 3.1: the real-time pieces took up to 54-60 ms).
typedef struct VoiceStreamConfig {
    int hopMs;        // new sound per piece
    int contextMs;    // past sound the encoder also hears
    int crossfadeMs;  // crossfade between pieces
    int solaMs;       // how far the crossfade may search for the best fit
    int reserveMs;    // time kept in hand for a slow piece
    int lookaheadMs;  // sound after each piece the speech reader also hears (adds this much delay; 0 = none). Only
                      // models made in the look-ahead shape can use it (voicemodel_max_lookahead_ms); others use 0.
} VoiceStreamConfig;

typedef struct VoiceStreamStats {
    int loaded;              // 1 once the models are ready and the AI voice is playing
    int64_t hops;            // pieces converted
    int64_t misses;          // pieces that came too late (Natural mode played instead)
    double fallbackSeconds;  // time Natural mode played instead of the AI voice
    double averageHopMs;     // worker time per piece: average ...
    double worstHopMs;       // ... and worst
    double cpuShare;         // worker thread's share of one core
    int lookaheadMs;         // the look-ahead the pieces are made with now
    int64_t switches;        // look-ahead switches made (at quiet moments or after waiting 1.2 s)
    int aiNow;               // 1 = the AI voice is what plays now; 0 = Natural fills in (starting, loading, late)
} VoiceStreamStats;

// Loads the encoder and the voice (.mlmodelc folders). computeUnits: VOICEMODEL_COMPUTE_*. Slow the first time
// (macOS prepares the models; later loads are quick), so call it off the main and sound threads.
// Returns NULL and writes a short reason into err (errSize bytes) if it can't, e.g. "needs Apple silicon".
VoiceModel *voicemodel_load(const char *encoderPath, const char *voicePath, int computeUnits, char *err, int errSize);
void voicemodel_free(VoiceModel *model);  // only after every stream using it is deleted

// One line for logs and --changer-stats: which chips run it, hop and past sound, time per hop, load time.
const char *voicemodel_describe(const VoiceModel *model);

// The most look-ahead this model can use (ms): 0 for models made before the look-ahead shape.
int voicemodel_max_lookahead_ms(const VoiceModel *model);

// The fixed delay a stream would have (ms), the same sum voicestream_new makes: model NULL = the default 160 ms
// pieces on the GPU (a CPU-only model gets the bigger reserve). For the window's "Delay: about ..." line.
double voicestream_delay_ms(const VoiceModel *model, double chainRate, int maxFrames, int lookaheadMs);

// chainRate: the voice chain's sample rate. maxFrames: the largest `frames` given to push/pull (one callback; it is
// part of the fixed delay, so pass the real callback size, not a worst case). offline: 1 = convert inline in push (for
// --render-voice; never misses), 0 = live with a worker thread. config: NULL = defaults. With a model, the model's
// own hop, crossfade and search are used (they are built into the files) and a CPU-only model gets a 70 ms reserve.
// model may be NULL: the stream then plays Natural's sound at the fixed delay until voicestream_set_model gives it
// one (so turning Realistic on changes the delay once, not again when the models are ready).
VoiceStream *voicestream_new(VoiceModel *model, double chainRate, int maxFrames, int offline, const VoiceStreamConfig *config);
void voicestream_delete(VoiceStream *stream);

// Gives a stream made with model NULL its model (off the sound thread; the worker starts at the newest sound and
// crossfades in). Returns 0 if it doesn't fit this stream's hop / crossfade / search, reserve or voice sample rate (a stream
// made with no model expects 48 kHz); make a new stream then.
int voicestream_set_model(VoiceStream *stream, VoiceModel *model);

// Asks for another look-ahead (ms, rounded to 10 ms, limited to what the model can do) without making a new stream
// (any thread). The AI voice keeps playing; the switch is made between two pieces at the next quiet moment (so
// nothing is heard twice or lost), or after 1.2 s at the latest (then a crossfade; made within 1.5 s of the ask).
// Offline: right away.
void voicestream_set_lookahead(VoiceStream *stream, int lookaheadMs);

// The intonation the pitch frames were mapped with (1 + strength * (voice intonation - 1); 0 = unknown). The stream
// keeps the speaker's melody that much bigger but brings the small, fast moves (the wobble of a held note, the dips
// at consonants) back to the speaker's own size. Real-time safe (sound thread: from the chain's settings).
void voicestream_set_intonation(VoiceStream *stream, float intonation);

// Test settings (--changer-tune): "aiSlowMs" = extra time added to each piece (forces late pieces),
// "aiSlowEvery" = only every Nth piece, "aiGainMaxDb" = the most the loudness match may lift (default 18),
// "aiGainMs" = its window (50); the pitch the AI voice follows (with look-ahead): "aiSmoothFrames" (light smoothing,
// frames on each side, 1), "aiSlowFrames" (the melody line, 7), "aiIntonation" (as voicestream_set_intonation),
// "aiGapFrames" (unvoiced gaps up to this long inside a loud sound are bridged, 8), "aiOnsetFrames" (a vowel's
// unvoiced lead-in frames that take its first pitch, 3); "aiSolaMode" (-1 by look-ahead,
// 0 search, 1 keep the timing, 2 search near), "aiQuietDb" (a pause for look-ahead switches, -45),
// "aiLookaheadMs" (as voicestream_set_lookahead). Returns 1 if the key is known.
int voicestream_tune(VoiceStream *stream, const char *key, float value);

// The fixed delay from mic to output, in chain samples (with the look-ahead in use, or the one asked for).
int voicestream_latency_frames(const VoiceStream *stream);

// Sound thread: the next `frames` mic samples and the target pitch of the n 10 ms frames that finished
// (f0Hz 0 = not voiced; f0Pos = frame centres in mic samples, from VoiceChangerPitch). The positions must count the
// same samples as push does: reset the VoiceChanger when the stream is made (both then start at 0).
void voicestream_push(VoiceStream *stream, const float *mic, int frames, const float *f0Hz, const int64_t *f0Pos, int n);

// Sound thread: `frames` samples of output. naturalNow: Natural mode's output for the same callback, naturalDelay:
// its delay (samples), used to line it up for the fallback.
void voicestream_pull(VoiceStream *stream, const float *naturalNow, int naturalDelay, float *out, int frames);

void voicestream_get_stats(const VoiceStream *stream, VoiceStreamStats *out);

#ifdef __cplusplus
}
#endif

#endif
