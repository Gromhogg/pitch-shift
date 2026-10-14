#include "dsp/music_shifter.h"

#include <rubberband/RubberBandStretcher.h>

#include <algorithm>
#include <cmath>

namespace ps {

using RubberBand::RubberBandStretcher;

double pitch_scale(double half_steps) { return std::pow(2.0, half_steps / 12.0); }

MusicShifter::MusicShifter(int rate, int channels, double half_steps)
    : channels_(channels), half_steps_(half_steps) {
    const auto options = RubberBandStretcher::OptionProcessRealTime | RubberBandStretcher::OptionEngineFiner |
                         RubberBandStretcher::OptionChannelsTogether;
    rb_ = std::make_unique<RubberBandStretcher>(size_t(rate), size_t(channels), options, 1.0, pitch_scale(half_steps));
    rb_->setMaxProcessSize(kMaxChunk);
    in_.assign(size_t(channels), std::vector<float>(kMaxChunk));
    out_.assign(size_t(channels), std::vector<float>(kMaxChunk * 4));
}

MusicShifter::~MusicShifter() = default;

size_t MusicShifter::start_delay() const { return rb_->getStartDelay(); }

void MusicShifter::set_half_steps(double value) {
    if (half_steps_ == 0 && value != 0) rb_->reset();  // clear out old sound
    rb_->setPitchScale(pitch_scale(value));
    half_steps_ = value;
}

void MusicShifter::process(const float* interleaved, size_t frames, std::vector<float>& out) {
    const size_t ch = size_t(channels_);
    if (half_steps_ == 0) {
        out.insert(out.end(), interleaved, interleaved + frames * ch);
        return;
    }
    std::vector<float*> in_ptrs(ch), out_ptrs(ch);
    size_t done = 0;
    while (done < frames) {
        const size_t count = std::min(kMaxChunk, frames - done);
        for (size_t c = 0; c < ch; ++c) {
            for (size_t i = 0; i < count; ++i) in_[c][i] = interleaved[(done + i) * ch + c];
            in_ptrs[c] = in_[c].data();
        }
        rb_->process(in_ptrs.data(), count, false);
        done += count;
        // Collect whatever is ready.
        for (;;) {
            const int available = rb_->available();
            if (available <= 0) break;
            const size_t take = std::min(size_t(available), out_[0].size());
            for (size_t c = 0; c < ch; ++c) out_ptrs[c] = out_[c].data();
            const size_t got = rb_->retrieve(out_ptrs.data(), take);
            if (got == 0) break;
            const size_t start = out.size();
            out.resize(start + got * ch);
            for (size_t i = 0; i < got; ++i)
                for (size_t c = 0; c < ch; ++c) out[start + i * ch + c] = out_[c][i];
        }
    }
}

}  // namespace ps
