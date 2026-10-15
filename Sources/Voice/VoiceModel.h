// Voice changer, "Realistic" mode: an AI voice model (RVC v2 style: a ContentVec encoder + one voice generator per
// voice) run with Core ML on its own worker thread. Apple silicon only; on Intel every call says so and the app keeps
// using Natural mode.
//   sound thread: voicestream_push (copies the mic + the pitch from voicechanger_analyse) and voicestream_pull (takes
//   the finished AI voice, a fixed delay later; while loading, on a late piece or an error it plays Natural mode's
//   sound delayed to the same fixed delay instead, crossfaded; never silence and never the raw mic).
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

// Sizes of the pieces the worker converts (milliseconds). Defaults: 160 / 480 / 40 / 10 / 60.
typedef struct VoiceStreamConfig {
    int hopMs;        // new sound per piece
    int contextMs;    // past sound the encoder also hears
    int crossfadeMs;  // crossfade between pieces
    int solaMs;       // how far the crossfade may search for the best fit
    int reserveMs;    // time kept in hand for a slow piece
} VoiceStreamConfig;

typedef struct VoiceStreamStats {
    int loaded;              // 1 once the models are ready and the AI voice is playing
    int64_t hops;            // pieces converted
    int64_t misses;          // pieces that came too late (Natural mode played instead)
    double fallbackSeconds;  // time Natural mode played instead of the AI voice
    double averageHopMs;     // worker time per piece: average ...
    double worstHopMs;       // ... and worst
    double cpuShare;         // worker thread's share of one core
} VoiceStreamStats;

// Loads the encoder and the voice (.mlmodelc folders). computeUnits: VOICEMODEL_COMPUTE_*. Slow the first time
// (macOS prepares the models; later loads are quick), so call it off the main and sound threads.
// Returns NULL and writes a short reason into err (errSize bytes) if it can't, e.g. "needs Apple silicon".
VoiceModel *voicemodel_load(const char *encoderPath, const char *voicePath, int computeUnits, char *err, int errSize);
void voicemodel_free(VoiceModel *model);

// chainRate: the voice chain's sample rate. maxFrames: the largest `frames` given to push/pull. offline: 1 = convert
// inline in push (for --render-voice; never misses), 0 = live with a worker thread. config: NULL = defaults.
VoiceStream *voicestream_new(VoiceModel *model, double chainRate, int maxFrames, int offline, const VoiceStreamConfig *config);
void voicestream_delete(VoiceStream *stream);

// The fixed delay from mic to output, in chain samples.
int voicestream_latency_frames(const VoiceStream *stream);

// Sound thread: the next `frames` mic samples and the target pitch of the n 10 ms frames that finished
// (f0Hz 0 = not voiced; f0Pos = frame centres in mic samples, from VoiceChangerPitch).
void voicestream_push(VoiceStream *stream, const float *mic, int frames, const float *f0Hz, const int64_t *f0Pos, int n);

// Sound thread: `frames` samples of output. naturalNow: Natural mode's output for the same callback, naturalDelay:
// its delay (samples), used to line it up for the fallback.
void voicestream_pull(VoiceStream *stream, const float *naturalNow, int naturalDelay, float *out, int frames);

void voicestream_get_stats(const VoiceStream *stream, VoiceStreamStats *out);

#ifdef __cplusplus
}
#endif

#endif
