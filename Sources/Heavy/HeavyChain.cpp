#include "HeavyChain.h"
#include <Accelerate/Accelerate.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

namespace {

// Times in ms. Chosen on the test set, see the research notes.
const double DelayMs = 350, FadeMs = 15, JumpMinMs = 4, JumpMaxMs = 160, MatchMs = 25, ToleranceMs = 5, HoldMs = 25, GuardMs = 5;
const double MatchLowHz = 300, MatchHighHz = 5000;  // what the matching listens to
const double HitSensitivity = 1.5;                  // lower finds more hits
const double LimiterCeiling = 0.966;                // -0.3 dBFS

double bessel0(double x) {
    double sum = 1, term = 1;
    for (int k = 1; k < 30; k++) { term *= (x / (2 * k)) * (x / (2 * k)); sum += term; }
    return sum;
}

// Finds hits as a sudden rise across the spectrum, which works on loud masters, where the level hardly moves at a hit.
// A hit is known about 50 ms after it arrives.
struct HitFinder {
    static constexpr int Median = 31, MedianMiddle = 15, Around = 8;
    int size = 1024, log2Size = 10, hop = 128, fill = 0, frames = 0, sinceHit = 1 << 20, minGap = 22;
    FFTSetup fft = nullptr;
    std::vector<float> window, buffer, scratch, re, im, previous, magnitude;
    float rises[Median] = {}, sorted[Median] = {}, recent[Around * 2 + 1] = {};
    double mean = 0, variance = 1;

    void init(double rate, int scale) {
        size = 1024 * scale; hop = 128 * scale;
        log2Size = int(std::lround(std::log2(double(size))));
        fft = vDSP_create_fftsetup(log2Size, kFFTRadix2);
        window.resize(size); buffer.assign(size, 0); scratch.resize(size);
        re.resize(size / 2); im.resize(size / 2); previous.assign(size / 2 + 1, 0); magnitude.resize(size / 2 + 1);
        float sum = 0;
        for (int i = 0; i < size; i++) { window[i] = 0.5f - 0.5f * std::cos(2 * float(M_PI) * i / size); sum += window[i]; }
        for (auto &w : window) w /= sum / 2;
        minGap = int(0.06 * rate / hop);
    }
    ~HitFinder() { if (fft) vDSP_destroy_fftsetup(fft); }

    // One sample in. Returns how many samples ago a hit was, or -1.
    int push(float mono) {
        buffer[fill++] = mono;
        if (fill < size) return -1;
        vDSP_vmul(buffer.data(), 1, window.data(), 1, scratch.data(), 1, vDSP_Length(size));
        for (int i = 0; i < size / 2; i++) { re[i] = scratch[2 * i]; im[i] = scratch[2 * i + 1]; }
        DSPSplitComplex z{re.data(), im.data()};
        vDSP_fft_zrip(fft, &z, 1, log2Size, kFFTDirection_Forward);
        magnitude[0] = std::log1p(100 * std::fabs(re[0]) * 0.5f);
        magnitude[size / 2] = std::log1p(100 * std::fabs(im[0]) * 0.5f);
        for (int i = 1; i < size / 2; i++) magnitude[i] = std::log1p(100 * 0.5f * std::sqrt(re[i] * re[i] + im[i] * im[i]));
        float rise = 0;
        for (int i = 0; i <= size / 2; i++) { float d = magnitude[i] - previous[i]; if (d > 0) rise += d; previous[i] = magnitude[i]; }
        std::memmove(buffer.data(), buffer.data() + hop, sizeof(float) * (size - hop));
        fill = size - hop;
        std::memmove(rises, rises + 1, sizeof(float) * (Median - 1));
        rises[Median - 1] = rise;
        frames++; sinceHit++;
        // The frame in the middle, against the median around it.
        std::copy(rises, rises + Median, sorted);
        std::nth_element(sorted, sorted + MedianMiddle, sorted + Median);
        float value = rises[Median - 1 - MedianMiddle] - sorted[MedianMiddle];
        std::memmove(recent, recent + 1, sizeof(float) * (Around * 2));
        recent[Around * 2] = value;
        const double a = 1.0 / 1500;  // about 4 s of memory
        mean += a * (value - mean);
        variance += a * ((value - mean) * (value - mean) - variance);
        if (frames < 60 || variance < 1e-12) return -1;
        float middle = recent[Around];
        if (middle <= 1e-6f || middle < mean + HitSensitivity * std::sqrt(variance) || sinceHit < minGap) return -1;
        for (float r : recent) if (r > middle) return -1;
        sinceHit = 0;
        return size / 2 + (MedianMiddle + Around) * hop;
    }
};

// Reads a ring of sound at any position, with a filter that leaves out what would fold back when reading fast.
struct TapeReader {
    static constexpr int Taps = 48, Half = Taps / 2, Phases = 256;
    std::vector<float> table;
    void init() { table.assign(size_t(Phases + 1) * Taps, 0.f); }
    // No memory is made here. Only exactly 1 gives an untouched sound, so nothing else is cut at the same frequency.
    void setSpeed(double speed) {
        double cut = speed == 1 ? 1.0 : 0.97 * std::min(1.0, 1.0 / speed);
        for (int p = 0; p <= Phases; p++) {
            double fraction = double(p) / Phases, sum = 0;
            float *row = &table[size_t(p) * Taps];
            for (int k = 0; k < Taps; k++) {
                double x = k - (Half - 1) - fraction, s = std::fabs(x) < 1e-9 ? cut : std::sin(M_PI * cut * x) / (M_PI * x);
                double u = x / Half, w = std::fabs(u) >= 1 ? 0 : bessel0(9.0 * std::sqrt(1 - u * u)) / bessel0(9.0);
                row[k] = float(s * w);
                sum += s * w;
            }
            for (int k = 0; k < Taps; k++) row[k] = float(row[k] / sum);
        }
    }
    inline float read(const float *ring, int64_t mask, double position) const {
        int64_t whole = int64_t(std::floor(position));
        double f = (position - whole) * Phases;
        int p = int(f);
        float blend = float(f - p);
        const float *row0 = &table[size_t(p) * Taps], *row1 = row0 + Taps;
        float s0 = 0, s1 = 0;
        int64_t start = whole - (Half - 1);
        for (int k = 0; k < Taps; k++) {
            float v = ring[(start + k) & mask];
            s0 += row0[k] * v; s1 += row1[k] * v;
        }
        return s0 + blend * (s1 - s0);
    }
};

// The same safety limiter as Advanced processing: 2 ms of look-ahead, gain back in 25 ms after a short over, else 120 ms.
struct Limiter {
    int look = 96, length = 97, position = 0;
    double release = 0.9998, fastRelease = 0.999, gainHeld = 1, sum = 97;
    int64_t sinceOver = 1 << 30, episode = 0, shortOver = 240;
    std::vector<float> delay[2];
    std::vector<double> need, held;

    void init(double rate) {
        look = std::max(1, int(std::lround(0.002 * rate))); length = look + 1;
        release = std::exp(-1.0 / (0.120 * rate)); fastRelease = std::exp(-1.0 / (0.025 * rate));
        shortOver = int64_t(std::lround(0.005 * rate));
        delay[0].assign(length, 0.f); delay[1].assign(length, 0.f);
        need.assign(length, 1.0); held.assign(length, 1.0);
        sum = length;
    }
    inline void run(float &left, float &right) {
        double peak = std::max(std::fabs(double(left)), std::fabs(double(right)));
        double wanted = peak > LimiterCeiling ? LimiterCeiling * (1.0 - 4e-6) / peak : 1.0;
        need[position] = wanted;
        if (wanted < 1.0 && sinceOver > look) episode = 0;
        sinceOver = wanted < 1.0 ? 0 : sinceOver + 1;
        double lowest = 1.0;
        if (sinceOver <= look) { for (int k = 0; k < length; k++) lowest = std::min(lowest, need[k]); episode++; }
        if (lowest < gainHeld) gainHeld = lowest;
        else {
            gainHeld = lowest - (lowest - gainHeld) * (episode < shortOver ? fastRelease : release);
            if (lowest == 1.0 && gainHeld > 1.0 - 1e-7) gainHeld = 1.0;
        }
        sum += gainHeld - held[position]; held[position] = gainHeld;
        double gain = std::min(1.0, sum / length);
        int oldest = position + 1 == length ? 0 : position + 1;
        delay[0][position] = left; delay[1][position] = right;
        float l = delay[0][oldest], r = delay[1][oldest];
        if (gain < 1.0) {
            l = float(std::max(-LimiterCeiling, std::min(LimiterCeiling, l * gain)));
            r = float(std::max(-LimiterCeiling, std::min(LimiterCeiling, r * gain)));
        }
        left = l; right = r;
        if (++position == length) {  // add the gains up again once per lap, so rounding never builds up
            position = 0;
            sum = 0;
            for (int k = 0; k < length; k++) sum += held[k];
        }
    }
};

}  // namespace

struct HeavyChain {
    double rate = 48000, speed = 1, semis = 0;
    int delay = 16800, hitStep = 120, fadeLength = 720;
    int64_t size = 1 << 18, mask = (1 << 18) - 1, written = 0, played = 0;
    std::vector<float> ring[2], match[2], quarter[2];
    std::vector<uint8_t> hits;
    TapeReader reader;
    HitFinder finder;
    Limiter limiter;
    double head = 0, nextHead = 0;
    int fade = -1, waitAfterJump = 0;
    float likeness = 1;
    double lowState[2] = {0, 0}, highState[2] = {0, 0}, lowK = 0, highK = 0;
    float quarterSum[2] = {0, 0};
    bool planned = false;
    double planAt = 0, planJump = 0, planLikeness = 0;

    void setSemis(double value) {
        semis = std::max(-24.0, std::min(24.0, value));
        speed = semis == 0 ? 1.0 : std::pow(2.0, semis / 12);
        reader.setSpeed(speed);
        fadeLength = std::max(16, int(FadeMs * 0.001 * rate / std::max(1.0, speed)));
        planned = false;
    }

    void push(const float *left, const float *right, int frames) {
        for (int i = 0; i < frames; i++, written++) {
            ring[0][written & mask] = left[i]; ring[1][written & mask] = right[i];
            if (written % hitStep == 0) hits[(written / hitStep) % int64_t(hits.size())] = 0;  // a ring: last lap's hits are old
            for (int c = 0; c < 2; c++) {
                double v = c ? right[i] : left[i];
                lowState[c] += lowK * (v - lowState[c]);
                highState[c] += highK * (v - lowState[c] - highState[c]);
                match[c][written & mask] = float(highState[c]);
                quarterSum[c] += float(highState[c]);
                if ((written & 3) == 3) { quarter[c][(written >> 2) & (size / 4 - 1)] = quarterSum[c] * 0.25f; quarterSum[c] = 0; }
            }
            int ago = finder.push(0.5f * (left[i] + right[i]));
            if (ago >= 0 && ago < written)
                hits[((written - ago) / hitStep) % int64_t(hits.size())] = 1;
        }
        // Long digital silence must not sink the filters into very small numbers, which are slow on Intel.
        for (int c = 0; c < 2; c++) {
            if (std::fabs(lowState[c]) < 1e-20) lowState[c] = 0;
            if (std::fabs(highState[c]) < 1e-20) highState[c] = 0;
        }
    }

    int64_t hitAfter(double from, double to) const {
        for (int64_t k = int64_t(from) / hitStep + 1; k <= int64_t(to) / hitStep; k++)
            if (k >= 0 && hits[k % int64_t(hits.size())]) return k * hitStep;
        return -1;
    }

    int64_t hitBefore(double from, double reach) const {
        for (int64_t k = int64_t(from) / hitStep; k >= int64_t(from - reach) / hitStep; k--)
            if (k >= 0 && hits[k % int64_t(hits.size())]) return k * hitStep;
        return -(int64_t(1) << 40);
    }

    // How alike the sound is at position and at position + jump, -1 to 1, at a quarter of the rate.
    double likenessRough(int64_t position, int jump, int length) const {
        const int64_t m = size / 4 - 1;
        int64_t a = position >> 2, b = (position + jump) >> 2;
        double ab = 0, aa = 1e-9, bb = 1e-9;
        for (int c = 0; c < 2; c++) {
            const float *d = quarter[c].data();
            float s1 = 0, s2 = 0, s3 = 0;
            for (int i = 0; i < length; i++) { float u = d[(a + i) & m], v = d[(b + i) & m]; s1 += u * v; s2 += u * u; s3 += v * v; }
            ab += s1; aa += s2; bb += s3;
        }
        return ab / std::sqrt(aa * bb);
    }

    double likenessExact(int64_t position, int jump, int length) const {
        double ab = 0, aa = 1e-9, bb = 1e-9;
        for (int c = 0; c < 2; c++) {
            const float *d = match[c].data();
            float s1 = 0, s2 = 0, s3 = 0;
            for (int i = 0; i < length; i++) { float u = d[(position + i) & mask], v = d[(position + jump + i) & mask]; s1 += u * v; s2 += u * u; s3 += v * v; }
            ab += s1; aa += s2; bb += s3;
        }
        return ab / std::sqrt(aa * bb);
    }

    void jump(double by, double alike) {
        nextHead = head + by;
        fade = 0;
        likeness = float(std::max(0.0, std::min(1.0, alike)));
        waitAfterJump = int(JumpMinMs * 0.001 * rate);
        planned = false;
    }

    // Finds the jump that lands the next hit on time, and the moment in the gap where it joins best.
    void plan() {
        double trueTime = double(played) - delay;
        if (trueTime < 0) return;
        double error = head - trueTime;
        if (speed == 1) {  // at 0 the head sits exactly on true time, so the sound is untouched
            if (error != 0) { jump(-error, 1); nextHead = trueTime; }
            return;
        }
        // Safety: the head must never reach sound that hasn't arrived.
        if (std::fabs(error) > 0.85 * delay) { jump(-error, 0); return; }
        if (planned) { if (head >= planAt) jump(planJump, planLikeness); return; }
        double fadeRead = fadeLength * speed, guard = GuardMs * 0.001 * rate, hold = HoldMs * 0.001 * rate;
        double seen = double(written) - 64;
        if (seen - head < fadeRead + guard) return;
        int64_t hitAt = hitAfter(head + fadeRead + guard, seen);
        bool real = hitAt >= 0;
        double target = real ? double(hitAt) : seen;
        double need = (target - speed * (target - trueTime)) - head;  // landing on time; the same at any moment in the gap
        int minJump = int(JumpMinMs * 0.001 * rate), maxJump = int(JumpMaxMs * 0.001 * rate), tolerance = int(ToleranceMs * 0.001 * rate);
        if (!real) need *= 0.5;  // nothing to land on yet: take part of it, and look again
        if (std::fabs(need) < minJump) return;
        if (std::fabs(need) > maxJump) need = need > 0 ? maxJump : -maxJump;
        double last = double(hitBefore(head, 0.5 * rate));
        double amount = std::fabs(need), low, high;
        bool part = false;
        if (need < 0 && real) {  // going up, a jump must fit in the gap, or it would play the last hit twice
            double room = (target - fadeRead - guard) - (last + hold);
            if (amount > room) {
                if (room < minJump) return;
                amount = room; need = -room; part = true;
            }
        }
        if (need < 0) { low = std::max(head, last + hold + amount); high = target - fadeRead - guard; }
        else { low = std::max(head, last + hold); high = target - amount - fadeRead - guard; }
        high = std::min(high, seen - amount - fadeRead);
        if (part) high = std::min(high, low + 0.02 * rate);  // more jumps must follow in this gap, so go early
        if (high <= low) return;
        const int stepTime = int(0.005 * rate), length = int(MatchMs * 0.001 * rate), lengthRough = std::max(8, length / 4);
        double best = -2; int64_t bestAt = 0; int bestJump = 0;
        for (double p = low; p <= high; p += stepTime) {
            for (int j = int(need) - tolerance; j <= int(need) + tolerance; j += 4) {
                if ((j < 0) != (need < 0) || std::abs(j) < minJump) continue;
                double q = likenessRough(int64_t(p), j, lengthRough);
                if (q > best) { best = q; bestAt = int64_t(p); bestJump = j; }
            }
        }
        if (best < -1) return;
        double bestExact = -2; int exactJump = bestJump;
        for (int j = bestJump - 6; j <= bestJump + 6; j++) {
            double q = likenessExact(bestAt, j, length);
            if (q > bestExact) { bestExact = q; exactJump = j; }
        }
        planned = true; planAt = double(bestAt); planJump = exactJump; planLikeness = bestExact;
    }

    void pull(float *left, float *right, int frames) {
        for (int i = 0; i < frames; i++, played++) {
            if (played < delay) head = double(played) - delay;
            if (fade < 0 && waitAfterJump <= 0 && (played % 48) == 0) plan();
            if (waitAfterJump > 0) waitAfterJump--;
            float l = reader.read(ring[0].data(), mask, head), r = reader.read(ring[1].data(), mask, head);
            if (fade >= 0) {
                // Alike sounds add in step, so they fade evenly. Different sounds add as powers, so they fade by power.
                float t = std::min(1.f, float(fade) / fadeLength);
                float even = 0.5f - 0.5f * std::cos(float(M_PI) * t);
                float powerIn = std::sin(0.5f * float(M_PI) * t), powerOut = std::cos(0.5f * float(M_PI) * t);
                float gainIn = likeness * even + (1 - likeness) * powerIn, gainOut = likeness * (1 - even) + (1 - likeness) * powerOut;
                l = gainOut * l + gainIn * reader.read(ring[0].data(), mask, nextHead);
                r = gainOut * r + gainIn * reader.read(ring[1].data(), mask, nextHead);
                nextHead += speed;
                if (++fade >= fadeLength) { head = nextHead - speed; fade = -1; }
            }
            left[i] = l; right[i] = r;
            head += speed;
        }
    }
};

extern "C" {

HeavyChain *heavy_new(double sampleRate, int maxFrames) {
    if (sampleRate < 8000 || maxFrames < 1) return nullptr;
    HeavyChain *chain = new HeavyChain();
    chain->rate = sampleRate;
    chain->delay = int(DelayMs * 0.001 * sampleRate);
    chain->hitStep = std::max(1, int(0.0025 * sampleRate));
    int64_t size = 1 << 16;
    while (size < int64_t(5 * sampleRate)) size *= 2;
    chain->size = size; chain->mask = size - 1;
    for (int c = 0; c < 2; c++) { chain->ring[c].assign(size, 0.f); chain->match[c].assign(size, 0.f); chain->quarter[c].assign(size / 4, 0.f); }
    chain->hits.assign(size / chain->hitStep + 1, 0);
    chain->lowK = 1 - std::exp(-2 * M_PI * MatchLowHz / sampleRate);
    chain->highK = 1 - std::exp(-2 * M_PI * MatchHighHz / sampleRate);
    chain->finder.init(sampleRate, std::max(1, int(std::lround(sampleRate / 48000))));
    chain->limiter.init(sampleRate);
    chain->reader.init();
    chain->head = -double(chain->delay);
    chain->setSemis(0);
    return chain;
}

void heavy_delete(HeavyChain *chain) { delete chain; }

void heavy_set_semis(HeavyChain *chain, double semis) {
    if (semis != chain->semis) chain->setSemis(semis);
}

void heavy_process(HeavyChain *chain, const float *const *in, float *const *out, int frames) {
    chain->push(in[0], in[1], frames);
    chain->pull(out[0], out[1], frames);
    for (int i = 0; i < frames; i++) chain->limiter.run(out[0][i], out[1][i]);
}

int heavy_latency_frames(const HeavyChain *chain) { return chain->delay + chain->limiter.look; }

}
