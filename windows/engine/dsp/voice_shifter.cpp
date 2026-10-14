#include "dsp/voice_shifter.h"

#include "dsp/music_shifter.h"
#include "dsp/voice_settings.h"

#include <algorithm>

namespace ps {

VoiceShifter::VoiceShifter(int rate, double half_steps, bool natural) : half_steps_(half_steps), natural_(natural) {
    rb_ = rubberband_live_new(unsigned(rate), 1, voice_settings::options(natural));
    rubberband_live_set_pitch_scale(rb_, pitch_scale(half_steps));
    if (voice_settings::kFormantScale != 1.0) rubberband_live_set_formant_scale(rb_, voice_settings::kFormantScale);
    block_ = rubberband_live_get_block_size(rb_);
    in_block_.assign(block_, 0.0f);
    out_block_.assign(block_, 0.0f);
}

VoiceShifter::~VoiceShifter() { rubberband_live_delete(rb_); }

unsigned VoiceShifter::start_delay() const { return rubberband_live_get_start_delay(rb_); }

void VoiceShifter::set_half_steps(double value) {
    if (half_steps_ == 0 && value != 0) rubberband_live_reset(rb_);  // clear out old sound
    rubberband_live_set_pitch_scale(rb_, pitch_scale(value));
    half_steps_ = value;
}

void VoiceShifter::set_natural(bool natural) {
    if (natural == natural_) return;
    rubberband_live_set_formant_option(rb_, voice_settings::options(natural));
    natural_ = natural;
}

void VoiceShifter::process(const float* in, size_t n, std::vector<float>& out) {
    size_t used = 0;
    while (used < n) {
        const size_t take = std::min(n - used, block_ - filled_);
        std::copy(in + used, in + used + take, in_block_.begin() + std::ptrdiff_t(filled_));
        filled_ += take;
        used += take;
        if (filled_ < block_) break;
        filled_ = 0;
        if (half_steps_ == 0) {
            out.insert(out.end(), in_block_.begin(), in_block_.end());
            continue;
        }
        const float* inputs[1] = {in_block_.data()};
        float* outputs[1] = {out_block_.data()};
        rubberband_live_shift(rb_, inputs, outputs);
        out.insert(out.end(), out_block_.begin(), out_block_.end());
    }
}

}  // namespace ps
