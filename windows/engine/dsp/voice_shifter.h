// Changes the pitch of a voice (one channel) with Rubber Band. Settings are in voice_settings.h.
// At 0 half-steps the voice passes through unchanged.
#pragma once
#include <memory>
#include <vector>

namespace RubberBand { class RubberBandStretcher; }

namespace ps {

class VoiceShifter {
public:
    VoiceShifter(int rate, double half_steps, bool natural);
    ~VoiceShifter();
    VoiceShifter(const VoiceShifter&) = delete;
    VoiceShifter& operator=(const VoiceShifter&) = delete;

    void set_half_steps(double value);
    void set_natural(bool natural);
    double half_steps() const { return half_steps_; }
    bool natural() const { return natural_; }

    // Takes any number of samples; adds whatever shifted sound is ready to `out`.
    void process(const float* in, size_t n, std::vector<float>& out);

private:
    std::unique_ptr<RubberBand::RubberBandStretcher> rb_;
    double half_steps_;
    bool natural_;
    std::vector<float> ready_;
};

}  // namespace ps
