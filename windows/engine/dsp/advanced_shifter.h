// "Advanced processing" for What you hear (made for music). At big shifts a plain pitch shift squeezes a song:
// going up the bass disappears, going down the top end goes dull. This keeps the song balanced:
//   - going up, the bass is shifted an octave less, so it stays bass;
//   - going down, the song's top end is kept unshifted;
//   - always, a slow tone control steers the sound back toward the original's balance, then a safety limiter.
// The work is done by the Mac app's own engine, shared (not copied): ../Sources/Advanced/AdvancedChain.cpp.
// Same rules as the Mac app:
//   - made for -12..+12 (delay about 140 ms); bigger amounts need a "full range" one (delay about 227 ms);
//   - exactly as many frames come out as go in, delayed by latency_frames() (it never changes);
//   - a new amount is heard about 0.2-0.3 s later, faded in.
// Research and numbers: notes/advanced-processing-research.md.
#pragma once
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <utility>
#include <vector>

struct AdvancedChain;

namespace ps {

class AdvancedShifter {
public:
    // Throws std::runtime_error if the engine can't be made. Takes a moment (it gets its shifters ready):
    // make it away from the sound threads.
    AdvancedShifter(int rate, int channels, double half_steps, bool full_range);
    ~AdvancedShifter();
    AdvancedShifter(const AdvancedShifter&) = delete;
    AdvancedShifter& operator=(const AdvancedShifter&) = delete;

    // Amounts beyond -12..+12 need a full range one (with more delay).
    static bool needs_full_range(double half_steps) { return std::fabs(half_steps) > 12.0; }

    // On the processing thread. A -12..+12 one holds amounts beyond that at +-12.
    void set_half_steps(double value);
    double half_steps() const { return half_steps_; }
    bool full_range() const { return full_range_; }
    size_t latency_frames() const;

    // `frames` frames of interleaved sound in, the same number out (`out` may be `in`). Any number of frames.
    // Makes no memory, takes no locks: safe on a sound thread.
    void process(const float* in, float* out, size_t frames);

    // What the engine is doing (call on the processing thread).
    struct Info {
        double heard = 0;         // the amount being heard now
        bool changing = false;    // a new amount is getting ready or fading in
        int64_t underruns = 0;    // times a shifter wasn't ready in time (should stay 0)
        int64_t switches = 0;     // amount changes faded in so far
        int shifters = 0;         // Rubber Band shifters in use right now
    };
    Info info() const;

    static constexpr size_t kMaxChunk = 2048;

private:
    AdvancedChain* chain_ = nullptr;
    int channels_;
    double half_steps_;
    bool full_range_;
    std::vector<float> in_[2], out_[2];
};

// Shifts a whole recording offline with the same code as live, like the Mac app's --render-file: the output lines
// up with the input (the delay is taken out) and has the same length. Always 2 channels out (a mono input is used
// for both). `changes`: (seconds, half-steps) pairs, to change the amount while it plays (like --steps-at).
// Normal mode works like the Mac's normal mode (Rubber Band with the app's settings).
std::vector<float> render_offline(const std::vector<float>& interleaved, int channels, int rate, double half_steps,
                                  bool advanced, const std::vector<std::pair<double, double>>& changes = {});

}  // namespace ps
