#include "dsp/drift_buffer.h"

#include "dsp/voice_settings.h"

#include <algorithm>
#include <cstring>

namespace ps {

DriftBuffer::DriftBuffer(int rate) : rate_(rate), ring_(size_t(rate)) {}  // room for 1 s

void DriftBuffer::push(const float* in, size_t n) {
    // Way too much waiting (the cable side stopped pulling): start over rather than overflow.
    if (ring_.queued() + n > ring_.capacity() / 2) {
        ++overflows_;
        flush_ = true;
        return;
    }
    ring_.write(in, n);
}

// Reads n samples, but moves `jump` samples further ahead (or back, if negative) along the way,
// crossfading across the jump so it doesn't click.
void DriftBuffer::read_with_jump(float* out, size_t n, long long jump) {
    const uint64_t r = ring_.read_pos();
    const size_t fade = std::min<size_t>(std::min<size_t>(ms(5), n / 2), size_t(std::llabs(jump)) * 4 + 48);
    for (size_t i = 0; i < n; ++i) {
        const uint64_t jumped = uint64_t((long long)(r + i) + jump);
        if (i < fade) {
            const float a = float(i + 1) / float(fade + 1);
            out[i] = (1 - a) * ring_.at(r + i) + a * ring_.at(jumped);
        } else {
            out[i] = ring_.at(jumped);
        }
    }
    ring_.skip(size_t((long long)n + jump));
}

void DriftBuffer::pull(float* out, size_t n) {
    if (flush_.exchange(false)) {
        ring_.clear();
        started_ = false;
        pending_jump_ = 0;
    }
    size_t q = ring_.queued();
    const size_t spare = ms(voice_settings::kSpareMs);
    if (!started_) {
        if (q < n + spare) {
            std::memset(out, 0, n * sizeof(float));
            return;
        }
        started_ = true;
        window_count_ = 0;
        window_min_ = SIZE_MAX;
        if (first_start_ && q > n + spare) {  // start with the smallest delay
            ring_.skip(q - (n + spare));
            q = n + spare;
        }
        first_start_ = false;
    }
    if (q < n) {  // ran dry: a gap; send silence and wait for the cushion again
        ring_.read(out, q);
        std::memset(out + q, 0, (n - q) * sizeof(float));
        started_ = false;
        ++dropouts_;
        return;
    }
    const uint64_t r = ring_.read_pos();
    if (pending_jump_ > 0 && q >= n + size_t(pending_jump_)) {
        read_with_jump(out, n, pending_jump_);
        ++trims_;
        q -= n + size_t(pending_jump_);
    } else if (pending_jump_ < 0 && r >= uint64_t(-pending_jump_) && (long long)n + pending_jump_ > 0) {
        read_with_jump(out, n, pending_jump_);
        ++repeats_;
        q -= size_t((long long)n + pending_jump_);
    } else {
        ring_.read(out, n);
        q -= n;
    }
    pending_jump_ = 0;

    // Every 0.5 s: look at the smallest extra seen, and trim or repeat a little.
    window_min_ = std::min(window_min_, q);
    window_count_ += n;
    if (window_count_ >= size_t(rate_ / 2)) {
        if (window_min_ >= ms(voice_settings::kTrimAboveMs)) pending_jump_ = (long long)(window_min_ - spare);
        else if (window_min_ < ms(voice_settings::kLowMs)) pending_jump_ = -(long long)(ms(10) - window_min_);
        window_count_ = 0;
        window_min_ = SIZE_MAX;
    }
}

}  // namespace ps
