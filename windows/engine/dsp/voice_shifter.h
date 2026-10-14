// Changes the pitch of a voice (one channel) with Rubber Band. Settings are in voice_settings.h.
// At 0 half-steps the voice passes through unchanged. The style (0 = Natural ... 1 = Cartoon) can change
// while it runs; it glides to the new value.
#pragma once
#include <memory>
#include <vector>

namespace RubberBand { class RubberBandStretcher; }

namespace ps {

class VoiceShifter {
public:
    VoiceShifter(int rate, double half_steps, double cartoon);
    ~VoiceShifter();
    VoiceShifter(const VoiceShifter&) = delete;
    VoiceShifter& operator=(const VoiceShifter&) = delete;

    void set_half_steps(double value);
    void set_cartoon(double cartoon);  // 0 = Natural ... 1 = Cartoon
    double half_steps() const { return half_steps_; }
    double cartoon() const { return cartoon_; }          // the style asked for
    double cartoon_now() const { return cartoon_now_; }  // the style in use (on its way there)

    // Takes any number of samples; adds whatever shifted sound is ready to `out`.
    void process(const float* in, size_t n, std::vector<float>& out);

private:
    std::unique_ptr<RubberBand::RubberBandStretcher> rb_;
    double half_steps_;
    double cartoon_;
    double cartoon_now_;
    double glide_step_;  // how much the style may move per sample
    std::vector<float> ready_;
};

}  // namespace ps
