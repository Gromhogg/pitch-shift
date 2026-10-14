// Changes the pitch of a voice (one channel) with Rubber Band's live shifter, which works in
// fixed-size blocks with low delay. Settings are in voice_settings.h. At 0 half-steps the voice
// skips Rubber Band.
#pragma once
#include <vector>

struct RubberBandLiveState_;

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

    // Takes any number of samples; adds shifted samples to `out` one block at a time.
    void process(const float* in, size_t n, std::vector<float>& out);

    size_t block_size() const { return block_; }
    unsigned start_delay() const;

private:
    RubberBandLiveState_* rb_;
    size_t block_;
    double half_steps_;
    bool natural_;
    std::vector<float> in_block_, out_block_;
    size_t filled_ = 0;
};

}  // namespace ps
