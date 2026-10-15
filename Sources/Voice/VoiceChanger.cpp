// Voice changer, Natural mode (see VoiceChanger.h). Step 0: the shared contract only. These do nothing yet:
// analyse keeps the pitch and the voice shape, post leaves the sound as it is.
#include "VoiceChanger.h"

#include <cstring>
#include <new>

struct VoiceChanger {
    double sampleRate = 48000;
    int maxFrames = 0;
    VoiceChangerVoice voice{};
    bool hasVoice = false;
    float strength = 0;
};

extern "C" {

VoiceChanger *voicechanger_new(double sampleRate, int maxFrames) {
    if (sampleRate < 8000 || maxFrames <= 0) return nullptr;
    auto *changer = new (std::nothrow) VoiceChanger();
    if (!changer) return nullptr;
    changer->sampleRate = sampleRate;
    changer->maxFrames = maxFrames;
    return changer;
}

void voicechanger_delete(VoiceChanger *changer) { delete changer; }

void voicechanger_set(VoiceChanger *changer, const VoiceChangerVoice *voice, float strength) {
    if (!changer) return;
    changer->hasVoice = voice != nullptr;
    if (voice) changer->voice = *voice;
    changer->strength = voice ? strength : 0;
}

void voicechanger_reset(VoiceChanger *) {}

void voicechanger_analyse(VoiceChanger *, const float *, int, float, VoiceChangerPitch *out) {
    if (!out) return;
    std::memset(out, 0, sizeof(*out));
    out->pitchScale = 1;
    out->formantScale = 1;
}

void voicechanger_post(VoiceChanger *, float *, int, int) {}

int voicechanger_tune(VoiceChanger *, const char *, float) { return 0; }

void voicechanger_get_stats(const VoiceChanger *changer, VoiceChangerStats *out) {
    if (!out) return;
    std::memset(out, 0, sizeof(*out));
    if (changer) out->strength = changer->strength;
}

}  // extern "C"
