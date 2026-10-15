// Voice changer, Realistic mode (see VoiceModel.h). Step 0: stubs only. Nothing loads yet, so the app always uses
// Natural mode. The Core ML code will live in the Apple silicon half below; Intel Macs keep the stubs for good.
#include "VoiceModel.h"

#include <cstdio>
#include <cstring>

namespace {
void say(char *err, int errSize, const char *text) {
    if (err && errSize > 0) std::snprintf(err, (size_t)errSize, "%s", text);
}
}  // namespace

extern "C" {

#if __arm64__

// Apple silicon: the Core ML voice models (not built yet).
VoiceModel *voicemodel_load(const char *, const char *, int, char *err, int errSize) {
    say(err, errSize, "not available yet");
    return nullptr;
}

#else

// Intel Macs: the AI voices need Apple silicon.
VoiceModel *voicemodel_load(const char *, const char *, int, char *err, int errSize) {
    say(err, errSize, "needs Apple silicon");
    return nullptr;
}

#endif

void voicemodel_free(VoiceModel *) {}

VoiceStream *voicestream_new(VoiceModel *, double, int, int, const VoiceStreamConfig *) { return nullptr; }
void voicestream_delete(VoiceStream *) {}
int voicestream_latency_frames(const VoiceStream *) { return 0; }
void voicestream_push(VoiceStream *, const float *, int, const float *, const int64_t *, int) {}

void voicestream_pull(VoiceStream *, const float *naturalNow, int, float *out, int frames) {
    if (out && naturalNow && out != naturalNow && frames > 0) std::memcpy(out, naturalNow, sizeof(float) * (size_t)frames);
}

void voicestream_get_stats(const VoiceStream *, VoiceStreamStats *out) {
    if (out) std::memset(out, 0, sizeof(*out));
}

}  // extern "C"
