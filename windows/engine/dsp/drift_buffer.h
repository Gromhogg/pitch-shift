// Sits between the microphone and the virtual cable. They run on separate clocks that drift
// apart a little, so this keeps 10-60 ms of voice waiting: when it gets too full it drops about
// 1 ms, and when it gets too empty it repeats about 1 ms, each with a short crossfade so it
// doesn't click. One channel; one thread pushes (mic), another pulls (cable).
#pragma once
#include "dsp/ring.h"

#include <atomic>
#include <cstdint>

namespace ps {

class DriftBuffer {
public:
    DriftBuffer(int rate, double min_ms = 10, double target_ms = 30, double max_ms = 60);

    void push(const float* in, size_t n);
    // Always fills n samples (silence until enough voice is waiting).
    void pull(float* out, size_t n);
    void flush() { flush_ = true; }

    double queued_ms() const { return double(ring_.queued()) * 1000.0 / rate_; }
    bool started() const { return started_; }
    uint64_t drops() const { return drops_; }        // times ~1 ms was dropped (too full)
    uint64_t repeats() const { return repeats_; }    // times ~1 ms was repeated (too empty)
    uint64_t dropouts() const { return dropouts_; }  // ran completely dry
    uint64_t overflows() const { return overflows_; }

    static constexpr size_t kFade = 48;  // 1 ms at 48 kHz

private:
    double rate_;
    size_t min_, target_, max_;
    SampleRing ring_;
    std::atomic<bool> started_{false}, flush_{false};
    std::atomic<uint64_t> drops_{0}, repeats_{0}, dropouts_{0}, overflows_{0};
};

}  // namespace ps
