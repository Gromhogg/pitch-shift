// Turns the quieted app sound back up (x1000 = +60 dB) before it is shifted.
// It also protects ears: if sound arrives that wasn't quieted (say, an app that just started
// and hasn't been turned down yet), the boost drops at once so nothing blasts, then slowly
// comes back up. Separately, limit() keeps the final sound from going past full scale.
#pragma once
#include <atomic>
#include <cstddef>
#include <cstdint>

namespace ps {

class Booster {
public:
    Booster(int channels, float boost);

    void set_boost(float boost) { boost_ = boost; }
    float boost() const { return boost_; }
    float current_gain() const { return gain_; }

    // Boosts interleaved sound in place.
    void process(float* data, size_t frames);
    uint64_t guarded() const { return guarded_; }  // how many pieces needed the lower boost

private:
    int channels_;
    std::atomic<float> boost_;
    float gain_;
    std::atomic<uint64_t> guarded_{0};
};

// Keeps every sample within -1..1. Returns how many samples had to be clipped.
size_t limit(float* data, size_t samples);

}  // namespace ps
