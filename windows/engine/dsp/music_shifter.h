// Changes the pitch of music with Rubber Band, using the same settings as the Mac app:
// the "finer" (R3) engine in real-time mode, channels kept together, chunks of at most 1024 frames.
// At 0 half-steps the sound skips Rubber Band entirely.
#pragma once
#include <memory>
#include <vector>

namespace RubberBand { class RubberBandStretcher; }

namespace ps {

class MusicShifter {
public:
    MusicShifter(int rate, int channels, double half_steps);
    ~MusicShifter();
    MusicShifter(const MusicShifter&) = delete;
    MusicShifter& operator=(const MusicShifter&) = delete;

    void set_half_steps(double value);
    double half_steps() const { return half_steps_; }

    // Takes `frames` of interleaved sound and adds whatever shifted sound is ready to `out` (interleaved).
    void process(const float* interleaved, size_t frames, std::vector<float>& out);

    // What Rubber Band reports as its delay, in frames (the real delay is longer, about 110 ms).
    size_t start_delay() const;

    static constexpr size_t kMaxChunk = 1024;

private:
    std::unique_ptr<RubberBand::RubberBandStretcher> rb_;
    int channels_;
    double half_steps_;
    std::vector<std::vector<float>> in_, out_;
};

// 2^(n/12): how much faster the sound waves get for n half-steps.
double pitch_scale(double half_steps);

}  // namespace ps
