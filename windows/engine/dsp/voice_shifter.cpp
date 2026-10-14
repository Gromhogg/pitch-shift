#include "dsp/voice_shifter.h"

#include "dsp/music_shifter.h"
#include "dsp/voice_settings.h"

#include <algorithm>

namespace ps {

using RubberBand::RubberBandStretcher;

VoiceShifter::VoiceShifter(int rate, double half_steps, bool natural) : half_steps_(half_steps), natural_(natural) {
    rb_ = std::make_unique<RubberBandStretcher>(size_t(rate), 1, voice_settings::options(natural), 1.0,
                                                pitch_scale(half_steps));
    rb_->setMaxProcessSize(voice_settings::kMaxProcess);
    ready_.resize(voice_settings::kMaxProcess * 2);
}

VoiceShifter::~VoiceShifter() = default;

void VoiceShifter::set_half_steps(double value) {
    if (half_steps_ == 0 && value != 0) rb_->reset();  // clear out old sound
    rb_->setPitchScale(pitch_scale(value));
    half_steps_ = value;
}

void VoiceShifter::set_natural(bool natural) {
    if (natural == natural_) return;
    rb_->setFormantOption(voice_settings::formant_option(natural));
    natural_ = natural;
}

void VoiceShifter::process(const float* in, size_t n, std::vector<float>& out) {
    if (half_steps_ == 0) {  // unchanged voice
        out.insert(out.end(), in, in + n);
        return;
    }
    size_t done = 0;
    while (done < n) {
        const size_t count = std::min(voice_settings::kMaxProcess, n - done);
        const float* input = in + done;
        rb_->process(&input, count, false);
        done += count;
        for (;;) {
            const int available = rb_->available();
            if (available <= 0) break;
            if (ready_.size() < size_t(available)) ready_.resize(size_t(available));
            float* output = ready_.data();
            const size_t got = rb_->retrieve(&output, size_t(available));
            if (got == 0) break;
            out.insert(out.end(), ready_.begin(), ready_.begin() + std::ptrdiff_t(got));
        }
    }
}

}  // namespace ps
