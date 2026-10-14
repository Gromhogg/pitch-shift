// The cushion between the shifted voice and the virtual cable, with the same rules as the Mac app:
//   - start sending once one piece (what the cable asks for) + 20 ms is waiting; the first time,
//     anything above that is trimmed away;
//   - if it runs dry, send silence and wait for one piece + 20 ms again;
//   - every 0.5 s, if the extra never dropped below 25 ms, skip back down to 20 ms.
// The microphone and the cable also run on separate clocks that drift apart a little, so if the
// extra dropped below 5 ms, a few ms are played again. Skips and repeats use a short crossfade.
// One channel; one thread pushes (the voice), another pulls (the cable).
#pragma once
#include "dsp/ring.h"

#include <atomic>
#include <cstdint>

namespace ps {

class DriftBuffer {
public:
    explicit DriftBuffer(int rate);

    void push(const float* in, size_t n);
    // Always fills n samples (silence while filling up).
    void pull(float* out, size_t n);
    void flush() { flush_ = true; }

    double queued_ms() const { return double(ring_.queued()) * 1000.0 / rate_; }
    bool started() const { return started_; }
    uint64_t trims() const { return trims_; }        // times the extra was skipped back down
    uint64_t repeats() const { return repeats_; }    // times a few ms were played again
    uint64_t dropouts() const { return dropouts_; }  // ran dry (a gap in the voice)
    uint64_t overflows() const { return overflows_; }
    void reset_counts() { trims_ = 0; repeats_ = 0; dropouts_ = 0; overflows_ = 0; }

private:
    size_t ms(double v) const { return size_t(rate_ * v / 1000); }
    void read_with_jump(float* out, size_t n, long long jump);

    double rate_;
    SampleRing ring_;
    std::atomic<bool> started_{false}, flush_{false};
    bool first_start_ = true;
    size_t window_count_ = 0, window_min_ = SIZE_MAX;
    long long pending_jump_ = 0;  // >0 skip ahead, <0 play again
    std::atomic<uint64_t> trims_{0}, repeats_{0}, dropouts_{0}, overflows_{0};
};

}  // namespace ps
