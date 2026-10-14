#include "dsp/cushion.h"

#include <algorithm>
#include <cstring>

namespace ps {

Cushion::Cushion(int channels, size_t start_frames, size_t max_frames)
    : channels_(channels),
      start_frames_(start_frames),
      max_frames_(max_frames),
      ring_((max_frames + 8192) * size_t(channels)) {}

void Cushion::push(const float* data, size_t frames) {
    if (frames == 0) return;
    if (queued_frames() + frames > max_frames_) {  // falling behind: skip a bit to catch up
        ++skips_;
        skipped_frames_ += frames;
        return;
    }
    ring_.write(data, frames * size_t(channels_));
}

void Cushion::pull(float* out, size_t frames) {
    const size_t ch = size_t(channels_);
    if (flush_.exchange(false)) {
        ring_.clear();
        playing_ = false;
    }
    const size_t queued = queued_frames();
    if (!playing_) {
        if (queued < start_frames_ || queued == 0) {
            std::memset(out, 0, frames * ch * sizeof(float));
            return;
        }
        playing_ = true;
    }
    const size_t take = std::min(frames, queued);
    ring_.read(out, take * ch);
    if (take < frames) {  // ran dry: go quiet and refill the cushion
        std::memset(out + take * ch, 0, (frames - take) * ch * sizeof(float));
        playing_ = false;
        ++dropouts_;
    }
}

}  // namespace ps
