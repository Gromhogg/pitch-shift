#include "dsp/voice_shifter.h"

#include "dsp/music_shifter.h"
#include "dsp/voice_settings.h"

#include <algorithm>
#include <cmath>

namespace ps {

using RubberBand::RubberBandStretcher;

VoiceShifter::VoiceShifter(int rate, double half_steps, double cartoon)
    : half_steps_(half_steps),
      cartoon_(std::clamp(cartoon, 0.0, 1.0)),
      cartoon_now_(cartoon_),
      glide_step_(1.0 / (voice_settings::kStyleGlideSeconds * rate)) {
    rb_ = std::make_unique<RubberBandStretcher>(size_t(rate), 1, voice_settings::options(), 1.0, pitch_scale(half_steps));
    rb_->setMaxProcessSize(voice_settings::kMaxProcess);
    rb_->setFormantScale(voice_settings::formant_scale(half_steps_, cartoon_now_));
    ready_.resize(voice_settings::kMaxProcess * 2);
}

VoiceShifter::~VoiceShifter() = default;

void VoiceShifter::set_half_steps(double value) {
    if (half_steps_ == 0 && value != 0) rb_->reset();  // clear out old sound
    rb_->setPitchScale(pitch_scale(value));
    half_steps_ = value;
    rb_->setFormantScale(voice_settings::formant_scale(half_steps_, cartoon_now_));
}

void VoiceShifter::set_cartoon(double cartoon) { cartoon_ = std::clamp(cartoon, 0.0, 1.0); }

void VoiceShifter::process(const float* in, size_t n, std::vector<float>& out) {
    // The style glides toward where it's heading (just a number for Rubber Band: no memory is made).
    if (cartoon_now_ != cartoon_) {
        const double step = glide_step_ * double(n);
        cartoon_now_ = std::fabs(cartoon_ - cartoon_now_) <= step ? cartoon_
                                                                   : cartoon_now_ + (cartoon_ > cartoon_now_ ? step : -step);
        rb_->setFormantScale(voice_settings::formant_scale(half_steps_, cartoon_now_));
    }
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
