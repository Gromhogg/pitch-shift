// The small cushion of sound between the pitch shifter and the speakers, with the same rules as the
// Mac app: start playing once 50 ms is waiting; if more than 150 ms would be waiting, drop the new
// sound (we've fallen behind); if it runs dry, go quiet and wait for 50 ms again.
// One thread puts sound in (push), another takes it out for the speakers (pull).
// Running dry counts as a dropout only when sound comes back afterwards (a gap). When the app playing just quit,
// the sound has ended: nothing is missing, so that isn't counted.
#pragma once
#include "dsp/ring.h"

#include <atomic>
#include <cstdint>

namespace ps {

class Cushion {
public:
    Cushion(int channels, size_t start_frames, size_t max_frames);

    // Adds sound (interleaved). If it would go over the limit, it's dropped and counted as a skip.
    void push(const float* data, size_t frames);
    // Always fills `frames` frames: queued sound while playing, silence while filling up.
    void pull(float* out, size_t frames);
    // Throws away what's queued (from the reader side) and waits to fill up again.
    void flush() { flush_ = true; }

    size_t queued_frames() const { return ring_.queued() / size_t(channels_); }
    bool playing() const { return playing_; }
    uint64_t dropouts() const { return dropouts_; }   // ran dry while playing, then sound came back
    uint64_t skips() const { return skips_; }         // pieces dropped because too much was waiting
    uint64_t skipped_frames() const { return skipped_frames_; }
    void reset_counts() { dropouts_ = 0; skips_ = 0; skipped_frames_ = 0; ran_dry_ = false; }

private:
    int channels_;
    size_t start_frames_, max_frames_;
    SampleRing ring_;
    std::atomic<bool> playing_{false}, flush_{false}, ran_dry_{false};
    std::atomic<uint64_t> dropouts_{0}, skips_{0}, skipped_frames_{0};
};

}  // namespace ps
