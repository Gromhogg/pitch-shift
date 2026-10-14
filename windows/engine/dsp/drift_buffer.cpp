#include "dsp/drift_buffer.h"

#include <algorithm>
#include <cstring>

namespace ps {

DriftBuffer::DriftBuffer(int rate, double min_ms, double target_ms, double max_ms)
    : rate_(rate),
      min_(size_t(rate * min_ms / 1000)),
      target_(size_t(rate * target_ms / 1000)),
      max_(size_t(rate * max_ms / 1000)),
      ring_(size_t(rate)) {}  // room for 1 s; we only ever keep about 60 ms

void DriftBuffer::push(const float* in, size_t n) {
    // Way too much waiting (the cable side stopped pulling): start over rather than overflow.
    if (ring_.queued() + n > ring_.capacity() / 2) {
        ++overflows_;
        flush_ = true;
        return;
    }
    ring_.write(in, n);
}

void DriftBuffer::pull(float* out, size_t n) {
    if (flush_.exchange(false)) {
        ring_.clear();
        started_ = false;
    }
    const size_t q = ring_.queued();
    if (!started_) {
        if (q < target_) {
            std::memset(out, 0, n * sizeof(float));
            return;
        }
        started_ = true;
    }
    const uint64_t r = ring_.read_pos();
    const size_t fade = std::min(kFade, n / 2);
    if (q > n + max_ && q >= n + fade) {
        // Too full: skip `fade` samples, crossfading from where we are to `fade` samples later.
        for (size_t i = 0; i < n; ++i) {
            if (i < fade) {
                const float a = float(i + 1) / float(fade + 1);
                out[i] = (1 - a) * ring_.at(r + i) + a * ring_.at(r + fade + i);
            } else {
                out[i] = ring_.at(r + fade + i);
            }
        }
        ring_.skip(n + fade);
        ++drops_;
        return;
    }
    if (q < n + min_ && q + fade >= n && r >= fade) {
        // Too empty: play the last `fade` samples again, crossfading back to them.
        for (size_t i = 0; i < n; ++i) {
            if (i < fade) {
                const float a = float(i + 1) / float(fade + 1);
                out[i] = (1 - a) * ring_.at(r + i) + a * ring_.at(r + i - fade);
            } else {
                out[i] = ring_.at(r + i - fade);
            }
        }
        ring_.skip(n - fade);
        ++repeats_;
        return;
    }
    if (q < n) {  // ran dry: go quiet and wait for the cushion again
        ring_.read(out, q);
        std::memset(out + q, 0, (n - q) * sizeof(float));
        started_ = false;
        ++dropouts_;
        return;
    }
    ring_.read(out, n);
}

}  // namespace ps
