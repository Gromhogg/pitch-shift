#include "dsp/booster.h"

#include <algorithm>
#include <cmath>

namespace ps {

namespace {
constexpr float kTrigger = 2.0f;   // boosted peaks above this mean sound that wasn't quieted
constexpr float kHeadroom = 0.9f;  // then the boost is lowered so peaks land here
constexpr float kRise = 1.25f;     // how fast the boost comes back per piece (about 10 ms each)
}  // namespace

Booster::Booster(int channels, float boost) : channels_(channels), boost_(boost), gain_(boost) {}

void Booster::process(float* data, size_t frames) {
    const size_t n = frames * size_t(channels_);
    if (n == 0) return;
    float peak = 0;
    for (size_t i = 0; i < n; ++i) peak = std::max(peak, std::fabs(data[i]));
    const float boost = boost_;
    // Normal (quieted) sound gets the full boost. Much louder sound only gets enough to reach the headroom.
    const float allowed = peak * boost > kTrigger ? kHeadroom / peak : boost;
    float target;
    if (allowed < gain_) {
        target = allowed;  // too loud: lower at once (from the start of this piece)
        gain_ = allowed;
        if (peak * boost > kTrigger) ++guarded_;
    } else {
        target = std::min(allowed, gain_ * kRise);  // come back up slowly
    }
    // Glide from the old gain to the new one across the piece, so it doesn't click.
    const float start = gain_;
    const float step = (target - start) / float(frames);
    for (size_t f = 0; f < frames; ++f) {
        const float g = start + step * float(f + 1);
        for (int c = 0; c < channels_; ++c) data[f * size_t(channels_) + size_t(c)] *= g;
    }
    gain_ = target;
}

size_t limit(float* data, size_t samples) {
    size_t clipped = 0;
    for (size_t i = 0; i < samples; ++i) {
        if (data[i] > 1.0f) {
            data[i] = 1.0f;
            ++clipped;
        } else if (data[i] < -1.0f) {
            data[i] = -1.0f;
            ++clipped;
        } else if (std::isnan(data[i])) {
            data[i] = 0.0f;
            ++clipped;
        }
    }
    return clipped;
}

}  // namespace ps
