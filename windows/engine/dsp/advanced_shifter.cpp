#include "dsp/advanced_shifter.h"

#include "AdvancedChain.h"

#include <rubberband/RubberBandStretcher.h>

#include <algorithm>
#include <memory>
#include <stdexcept>

namespace ps {

AdvancedShifter::AdvancedShifter(int rate, int channels, double half_steps, bool full_range)
    : channels_(std::clamp(channels, 1, 2)), half_steps_(half_steps), full_range_(full_range) {
    chain_ = advanced_new(double(rate), channels_, int(kMaxChunk), full_range ? 0 : ADVANCED_RANGE_12);
    if (!chain_) throw std::runtime_error("Could not start Advanced processing.");
    for (int c = 0; c < channels_; ++c) {
        in_[c].assign(kMaxChunk, 0.0f);
        out_[c].assign(kMaxChunk, 0.0f);
    }
    advanced_set_semis(chain_, half_steps);
}

AdvancedShifter::~AdvancedShifter() { advanced_delete(chain_); }

void AdvancedShifter::set_half_steps(double value) {
    if (value == half_steps_) return;
    half_steps_ = value;
    advanced_set_semis(chain_, value);
}

size_t AdvancedShifter::latency_frames() const { return size_t(advanced_latency_frames(chain_)); }

void AdvancedShifter::process(const float* in, float* out, size_t frames) {
    const size_t ch = size_t(channels_);
    const float* ins[2] = {in_[0].data(), ch > 1 ? in_[1].data() : nullptr};
    float* outs[2] = {out_[0].data(), ch > 1 ? out_[1].data() : nullptr};
    size_t done = 0;
    while (done < frames) {
        const size_t n = std::min(kMaxChunk, frames - done);
        for (size_t c = 0; c < ch; ++c)
            for (size_t i = 0; i < n; ++i) in_[c][i] = in[(done + i) * ch + c];
        advanced_process(chain_, ins, nullptr, outs, int(n));
        for (size_t c = 0; c < ch; ++c)
            for (size_t i = 0; i < n; ++i) out[(done + i) * ch + c] = out_[c][i];
        done += n;
    }
}

AdvancedShifter::Info AdvancedShifter::info() const {
    AdvancedInfo raw{};
    advanced_get_info(chain_, &raw);
    Info i;
    i.heard = raw.heardSemis;
    i.changing = raw.changing != 0;
    i.underruns = raw.underruns;
    i.switches = raw.switches;
    i.shifters = raw.shiftersRunning;
    return i;
}

// The same steps as the Mac app's renderFile (Sources/AdvancedShifter.swift), so the two can be compared.
std::vector<float> render_offline(const std::vector<float>& interleaved, int channels, int rate, double half_steps,
                                  bool advanced, const std::vector<std::pair<double, double>>& changes) {
    if (channels < 1 || rate <= 0) return {};
    const size_t length = interleaved.size() / size_t(channels);
    // Left and right (a mono file is used for both).
    std::vector<float> in[2];
    for (int c = 0; c < 2; ++c) {
        in[c].resize(length);
        const size_t from = size_t(std::min(c, channels - 1));
        for (size_t i = 0; i < length; ++i) in[c][i] = interleaved[i * size_t(channels) + from];
    }
    std::vector<float> out(length * 2, 0.0f);
    auto amount = [&](long long frame) {
        double value = half_steps;
        for (const auto& [seconds, steps] : changes)
            if ((long long)(seconds * rate) <= frame) value = steps;
        return value;
    };
    const long long len = (long long)length;
    const int block = 1024;
    std::vector<float> inL(block), inR(block), outL(block), outR(block);

    if (advanced) {
        double biggest = std::fabs(half_steps);
        for (const auto& c : changes) biggest = std::max(biggest, std::fabs(c.second));
        AdvancedChain* chain = advanced_new(double(rate), 2, block, biggest > 12 ? 0 : ADVANCED_RANGE_12);
        if (!chain) return {};
        double current = amount(0);
        advanced_set_semis(chain, current);
        const long long latency = advanced_latency_frames(chain);
        long long position = 0, written = -latency;
        while (written < len) {
            const int n = int(std::min<long long>(block, std::max<long long>(1, len + latency - position)));
            const double value = amount(position);
            if (value != current) {
                current = value;
                advanced_set_semis(chain, value);
            }
            const long long take = std::max<long long>(0, std::min<long long>(n, len - position));
            // Past the end of the file, zeros push the last of the sound out.
            std::fill(inL.begin(), inL.end(), 0.0f);
            std::fill(inR.begin(), inR.end(), 0.0f);
            for (long long i = 0; i < take; ++i) {
                inL[size_t(i)] = in[0][size_t(position + i)];
                inR[size_t(i)] = in[1][size_t(position + i)];
            }
            const float* ins[2] = {inL.data(), inR.data()};
            float* outs[2] = {outL.data(), outR.data()};
            advanced_process(chain, ins, nullptr, outs, n);
            for (int i = 0; i < n; ++i) {
                const long long w = written + i;
                if (w < 0 || w >= len) continue;
                out[size_t(w) * 2] = outL[size_t(i)];
                out[size_t(w) * 2 + 1] = outR[size_t(i)];
            }
            position += n;
            written += n;
        }
        advanced_delete(chain);
        return out;
    }

    // Normal mode: the same Rubber Band settings as live.
    using RubberBand::RubberBandStretcher;
    const auto options = RubberBandStretcher::OptionProcessRealTime | RubberBandStretcher::OptionEngineFiner |
                         RubberBandStretcher::OptionChannelsTogether;
    double current = amount(0);
    auto rb = std::make_unique<RubberBandStretcher>(size_t(rate), 2, options, 1.0, std::pow(2.0, current / 12));
    rb->setMaxProcessSize(block);
    const long long pad = (long long)rb->getPreferredStartPad();
    long long skip = (long long)rb->getStartDelay();
    long long position = -pad, written = 0;
    while (written < len) {
        const double value = amount(std::max<long long>(0, position));
        if (value != current) {
            rb->setPitchScale(std::pow(2.0, value / 12));
            current = value;
        }
        for (int i = 0; i < block; ++i) {
            const long long p = position + i;
            const bool inside = p >= 0 && p < len;
            inL[size_t(i)] = inside ? in[0][size_t(p)] : 0.0f;
            inR[size_t(i)] = inside ? in[1][size_t(p)] : 0.0f;
        }
        const float* ins[2] = {inL.data(), inR.data()};
        rb->process(ins, size_t(block), false);
        position += block;
        while (rb->available() > 0) {
            const int want = std::min(rb->available(), block);
            float* outs[2] = {outL.data(), outR.data()};
            const long long got = (long long)rb->retrieve(outs, size_t(want));
            const long long drop = std::min(skip, got);
            skip -= drop;
            for (long long i = drop; i < got && written < len; ++i, ++written) {
                out[size_t(written) * 2] = outL[size_t(i)];
                out[size_t(written) * 2 + 1] = outR[size_t(i)];
            }
            if (got == 0) break;
        }
    }
    return out;
}

}  // namespace ps
