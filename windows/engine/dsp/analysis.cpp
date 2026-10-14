#include "dsp/analysis.h"

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace ps {

namespace {
constexpr double kPi = 3.14159265358979323846;

struct SineFit {
    double a = 0, b = 0, c = 0;  // a*cos + b*sin + c
    double explained = 0;        // how much of the sound the fit accounts for (biggest at the right pitch)
    double amplitude() const { return std::sqrt(a * a + b * b); }
};

// Best-fit a*cos(wt) + b*sin(wt) + c (least squares, so it's exact even when the window
// doesn't hold a whole number of cycles).
SineFit fit_sine(const float* x, size_t n, double rate, double hz) {
    const double w = 2 * kPi * hz / rate;
    // Step cos/sin with a rotation instead of calling cos() for every sample; re-sync now and then.
    double scc = 0, sss = 0, scs = 0, sc = 0, ss = 0, sxc = 0, sxs = 0, sx = 0;
    const double cw = std::cos(w), sw = std::sin(w);
    double co = 1, si = 0;
    for (size_t i = 0; i < n; ++i) {
        if ((i & 1023) == 0) {
            co = std::cos(w * double(i));
            si = std::sin(w * double(i));
        }
        const double v = x[i];
        scc += co * co;
        sss += si * si;
        scs += co * si;
        sc += co;
        ss += si;
        sxc += v * co;
        sxs += v * si;
        sx += v;
        const double nco = co * cw - si * sw;
        si = si * cw + co * sw;
        co = nco;
    }
    // Solve the 3x3 system [scc scs sc; scs sss ss; sc ss n] [a b c] = [sxc sxs sx].
    double m[3][4] = {{scc, scs, sc, sxc}, {scs, sss, ss, sxs}, {sc, ss, double(n), sx}};
    for (int col = 0; col < 3; ++col) {
        int pivot = col;
        for (int r = col + 1; r < 3; ++r)
            if (std::fabs(m[r][col]) > std::fabs(m[pivot][col])) pivot = r;
        if (std::fabs(m[pivot][col]) < 1e-12) return {};
        if (pivot != col)
            for (int k = 0; k < 4; ++k) std::swap(m[col][k], m[pivot][k]);
        for (int r = 0; r < 3; ++r) {
            if (r == col) continue;
            const double f = m[r][col] / m[col][col];
            for (int k = col; k < 4; ++k) m[r][k] -= f * m[col][k];
        }
    }
    SineFit fit;
    fit.a = m[0][3] / m[0][0];
    fit.b = m[1][3] / m[1][1];
    fit.c = m[2][3] / m[2][2];
    fit.explained = fit.a * sxc + fit.b * sxs + fit.c * sx;
    return fit;
}

// How strong `hz` is, with a smooth (Hann) window so nearby tones don't leak in. For the rough search.
double windowed_power(const float* x, size_t n, double rate, double hz) {
    // cos/sin are stepped with rotations (much faster than calling them for every sample).
    const double w = 2 * kPi * hz / rate, v = 2 * kPi / double(n);
    const double cw = std::cos(w), sw = std::sin(w), cv = std::cos(v), sv = std::sin(v);
    double co = 1, si = 0, wc = 1, ws = 0;
    double re = 0, im = 0;
    for (size_t i = 0; i < n; ++i) {
        if ((i & 1023) == 0) {
            co = std::cos(w * double(i));
            si = std::sin(w * double(i));
            wc = std::cos(v * double(i));
            ws = std::sin(v * double(i));
        }
        const double win = 0.5 - 0.5 * wc;
        re += x[i] * win * co;
        im -= x[i] * win * si;
        const double nco = co * cw - si * sw;
        si = si * cw + co * sw;
        co = nco;
        const double nwc = wc * cv - ws * sv;
        ws = ws * cv + wc * sv;
        wc = nwc;
    }
    return re * re + im * im;
}
}  // namespace

// How well a sine at `hz` matches the sound. Used to find the exact pitch.
static double match(const float* x, size_t n, double rate, double hz) { return fit_sine(x, n, rate, hz).explained; }

double to_db(double amplitude) {
    return amplitude > 1e-10 ? 20 * std::log10(amplitude) : -200;
}

double tone_amplitude(const float* samples, size_t count, double rate, double hz) {
    if (count < 16) return 0;
    return fit_sine(samples, count, rate, hz).amplitude();
}

double faint_tone_amplitude(const float* samples, size_t count, double rate, double hz) {
    if (count < 16) return 0;
    // The Hann window adds up to count/2, so a sine of amplitude A gives |sum| = A * count/4.
    return 4.0 * std::sqrt(windowed_power(samples, count, rate, hz)) / double(count);
}

SteadyLevel steady_level(const float* samples, size_t count, double rate, double hz, double piece_seconds) {
    SteadyLevel s;
    const size_t piece = size_t(rate * piece_seconds);
    if (piece < 16) return s;
    std::vector<double> levels;
    for (size_t at = 0; at + piece <= count; at += piece)
        levels.push_back(to_db(faint_tone_amplitude(samples + at, piece, rate, hz)));
    if (levels.empty()) return s;
    std::sort(levels.begin(), levels.end());
    s.pieces = levels.size();
    s.lowest_db = levels.front();
    s.highest_db = levels.back();
    s.level_db = levels[levels.size() / 2];
    return s;
}

ToneMeasure measure_tone(const float* x, size_t n, double rate, double expected_hz) {
    ToneMeasure m;
    m.frames = n;
    if (n < 256 || expected_hz <= 0) return m;

    double sum2 = 0, peak = 0;
    for (size_t i = 0; i < n; ++i) {
        sum2 += double(x[i]) * x[i];
        peak = std::max(peak, double(std::fabs(x[i])));
    }
    m.peak = peak;
    m.rms_db = to_db(std::sqrt(sum2 / double(n)));
    if (peak == 0) return m;

    // Rough search on a shorter piece (fast), then fine-tune with the best-fit sine on all of it.
    const size_t rough_n = std::min<size_t>(n, size_t(rate * 0.5));
    double best_hz = expected_hz, best_power = -1;
    const double lo = expected_hz * 0.8, hi = expected_hz * 1.25;
    const double step = std::max(0.5, rate / double(rough_n) / 4);
    for (double hz = lo; hz <= hi; hz += step) {
        const double p = windowed_power(x, rough_n, rate, hz);
        if (p > best_power) {
            best_power = p;
            best_hz = hz;
        }
    }
    // Closer look in small steps, so the last search starts on the main peak.
    const double fine = step / 10;
    double best_amp = -1, center = best_hz;
    for (int k = -10; k <= 10; ++k) {
        const double hz = center + k * fine;
        const double amp = match(x, n, rate, hz);
        if (amp > best_amp) {
            best_amp = amp;
            best_hz = hz;
        }
    }
    // Golden-section search for the frequency whose best-fit sine matches the sound best.
    double a = best_hz - fine, b = best_hz + fine;
    const double g = (std::sqrt(5.0) - 1) / 2;
    double c1 = b - g * (b - a), c2 = a + g * (b - a);
    double f1 = match(x, n, rate, c1), f2 = match(x, n, rate, c2);
    for (int i = 0; i < 40 && b - a > 1e-5; ++i) {
        if (f1 > f2) {
            b = c2; c2 = c1; f2 = f1;
            c1 = b - g * (b - a);
            f1 = match(x, n, rate, c1);
        } else {
            a = c1; c1 = c2; f1 = f2;
            c2 = a + g * (b - a);
            f2 = match(x, n, rate, c2);
        }
    }
    m.frequency = (a + b) / 2;
    const SineFit fit = fit_sine(x, n, rate, m.frequency);
    m.level_db = to_db(fit.amplitude());

    // Whatever is left after taking the tone (and any DC offset) away is distortion + noise.
    const double w = 2 * kPi * m.frequency / rate;
    double tone2 = 0, rest2 = 0;
    for (size_t i = 0; i < n; ++i) {
        const double t = fit.a * std::cos(w * double(i)) + fit.b * std::sin(w * double(i));
        const double r = x[i] - t - fit.c;
        tone2 += t * t;
        rest2 += r * r;
    }
    m.thdn_db = tone2 > 0 ? 10 * std::log10(std::max(rest2, 1e-30) / tone2) : 0;
    return m;
}

std::vector<float> take_channel(const std::vector<float>& interleaved, int channels, int which) {
    std::vector<float> out;
    if (channels <= 0 || which < 0 || which >= channels) return out;
    out.reserve(interleaved.size() / size_t(channels));
    for (size_t i = size_t(which); i < interleaved.size(); i += size_t(channels)) out.push_back(interleaved[i]);
    return out;
}

std::vector<float> make_tone(double hz, double amplitude, double rate, int channels, double seconds) {
    const size_t frames = size_t(rate * seconds);
    std::vector<float> out(frames * size_t(channels));
    for (size_t i = 0; i < frames; ++i) {
        const float v = float(amplitude * std::sin(2 * kPi * hz * double(i) / rate));
        for (int c = 0; c < channels; ++c) out[i * size_t(channels) + size_t(c)] = v;
    }
    return out;
}

std::vector<float> make_vowel(double f0, double rate, double seconds, double amplitude) {
    const size_t n = size_t(rate * seconds);
    std::vector<double> x(n, 0.0);
    // Buzz: a sharp pulse once per pitch period (like the vocal folds).
    double phase = 0;
    for (size_t i = 0; i < n; ++i) {
        phase += f0 / rate;
        if (phase >= 1.0) {
            phase -= 1.0;
            x[i] = 1.0;
        }
    }
    // Mouth resonances: three two-pole filters in a row.
    const double formants[3][2] = {{700, 110}, {1220, 120}, {2600, 160}};
    for (const auto& f : formants) {
        const double r = std::exp(-kPi * f[1] / rate);
        const double a1 = 2 * r * std::cos(2 * kPi * f[0] / rate), a2 = -r * r;
        double y1 = 0, y2 = 0;
        for (size_t i = 0; i < n; ++i) {
            const double y = x[i] + a1 * y1 + a2 * y2;
            y2 = y1;
            y1 = y;
            x[i] = y;
        }
    }
    double peak = 0;
    for (size_t i = n / 4; i < n; ++i) peak = std::max(peak, std::fabs(x[i]));
    std::vector<float> out(n);
    for (size_t i = 0; i < n; ++i) out[i] = float(peak > 0 ? x[i] / peak * amplitude : 0);
    return out;
}

std::vector<float> make_test_song(double rate, double seconds) {
    const size_t n = size_t(rate * seconds);
    std::vector<double> l(n, 0.0), r(n, 0.0);
    const double beat = 0.5;  // 120 beats per minute
    uint32_t seed = 12345;
    auto noise = [&seed] {
        seed = seed * 1664525u + 1013904223u;
        return double(int32_t(seed)) / 2147483648.0;
    };
    auto pitch = [](int note) { return 440.0 * std::pow(2.0, (note - 69) / 12.0); };  // MIDI note -> Hz
    const int roots[4] = {48, 45, 41, 43};  // chords C, Am, F, G (one per bar)
    const int thirds[4] = {4, 3, 4, 4};
    const int tune[16] = {72, 74, 76, 79, 76, 74, 72, 69, 72, 74, 76, 77, 79, 77, 76, 74};
    double hat_last = 0, air_low = 0, tune_phase = 0;
    for (size_t i = 0; i < n; ++i) {
        const double t = double(i) / rate;
        const int b = int(t / beat);               // which beat
        const double since = t - b * beat;         // seconds since the beat
        const double eighth = std::fmod(t, beat / 2);
        const int bar = (b / 4) % 4;
        double left = 0, right = 0;
        // Kick on every beat: a sine falling from 120 to 45 Hz.
        const double kick = 0.45 * std::exp(-since * 9) * std::sin(2 * kPi * (45 * since + 2.5 * (1 - std::exp(-since * 30))));
        left += kick;
        right += kick;
        // Snare on beats 2 and 4: noise and a 185 Hz tone.
        if (b % 2 == 1) {
            const double snare = std::exp(-since * 18) * (0.18 * noise() + 0.12 * std::sin(2 * kPi * 185 * since));
            left += snare;
            right += snare;
        }
        // Hi-hat on every eighth: short, high-passed noise.
        const double hiss = noise();
        const double hat = 0.06 * std::exp(-eighth * 60) * (hiss - hat_last);
        hat_last = hiss;
        left += 0.8 * hat;
        right += hat;
        // Bass: the chord's root (a fifth up on the last beat) in eighths, with a few harmonics (44-98 Hz).
        const double bass_hz = pitch(roots[bar] - 12 + (b % 4 == 3 ? 7 : 0));
        double bass = 0;
        for (int k = 1; k <= 5; ++k) bass += std::sin(2 * kPi * bass_hz * k * t) / k;
        bass *= 0.16 * std::min(1.0, eighth * 200) * std::exp(-eighth * 3);
        left += bass;
        right += bass;
        // Chords: three notes held for the bar, spread left and right.
        for (int k = 0; k < 3; ++k) {
            const double hz = pitch(roots[bar] + 12 + (k == 0 ? 0 : k == 1 ? thirds[bar] : 7));
            double v = 0;
            for (int h = 1; h <= 4; ++h) v += std::sin(2 * kPi * hz * h * t + k) / (h * h);
            v *= 0.05;
            left += v * (k == 1 ? 1.2 : k == 2 ? 0.8 : 1.0);
            right += v * (k == 1 ? 0.8 : k == 2 ? 1.2 : 1.0);
        }
        // Tune: one note per beat with a little vibrato.
        tune_phase += 2 * kPi * pitch(tune[b % 16]) * (1 + 0.003 * std::sin(2 * kPi * 5.5 * t)) / rate;
        const double tone = 0.12 * std::min(1.0, since * 100) * std::exp(-since * 2) *
                            (std::sin(tune_phase) + 0.3 * std::sin(2 * tune_phase));
        left += 0.7 * tone;
        right += tone;
        // Air: very quiet hiss above about 7 kHz.
        const double x = noise();
        air_low += 0.6 * (x - air_low);
        left += 0.012 * (x - air_low);
        right += 0.012 * (x - air_low);
        l[i] = left;
        r[i] = right;
    }
    double peak = 0;
    for (size_t i = 0; i < n; ++i) peak = std::max({peak, std::fabs(l[i]), std::fabs(r[i])});
    const double gain = peak > 0 ? 0.7 / peak : 0;  // peaks at -3 dBFS
    std::vector<float> out(n * 2);
    for (size_t i = 0; i < n; ++i) {
        out[2 * i] = float(l[i] * gain);
        out[2 * i + 1] = float(r[i] * gain);
    }
    return out;
}

double spectral_centroid(const float* x, size_t n, double rate, double lo_hz, double hi_hz) {
    // Average the spectrum of several 4096-sample pieces (Hann window), in 10 Hz steps.
    const size_t frame = std::min<size_t>(4096, n);
    if (frame < 256) return 0;
    double weighted = 0, total = 0;
    for (size_t start = 0; start + frame <= n; start += frame) {
        for (double hz = lo_hz; hz <= hi_hz; hz += 10) {
            const double p = windowed_power(x + start, frame, rate, hz);
            weighted += hz * p;
            total += p;
        }
    }
    return total > 0 ? weighted / total : 0;
}

double estimate_f0(const float* x, size_t n, double rate, double lo_hz, double hi_hz) {
    const size_t min_lag = size_t(rate / hi_hz), max_lag = size_t(rate / lo_hz);
    if (n < max_lag * 3) return 0;
    const size_t len = n - max_lag;
    double energy = 0;
    for (size_t i = 0; i < len; ++i) energy += double(x[i]) * x[i];
    if (energy <= 0) return 0;
    std::vector<double> corr(max_lag + 2, 0.0);
    for (size_t lag = min_lag; lag <= max_lag + 1; ++lag) {
        double s = 0;
        for (size_t i = 0; i < len; ++i) s += double(x[i]) * x[i + lag];
        corr[lag] = s / energy;
    }
    // The first strong peak (so we don't pick a multiple of the period).
    double best = 0;
    for (size_t lag = min_lag; lag <= max_lag; ++lag) best = std::max(best, corr[lag]);
    for (size_t lag = min_lag + 1; lag <= max_lag; ++lag) {
        if (corr[lag] >= 0.85 * best && corr[lag] >= corr[lag - 1] && corr[lag] >= corr[lag + 1]) {
            // Refine between samples with a parabola through the peak.
            const double a = corr[lag - 1], b = corr[lag], c = corr[lag + 1];
            const double denom = a - 2 * b + c;
            const double shift = denom != 0 ? 0.5 * (a - c) / denom : 0;
            return rate / (double(lag) + shift);
        }
    }
    return 0;
}

double onset_time(const float* x, size_t n, double rate, double hz, double threshold_db, double from_s) {
    const size_t step = size_t(rate * 0.010);
    const size_t win = size_t(rate * 0.020);
    for (size_t start = size_t(from_s * rate); start + win <= n; start += step) {
        // Hann-windowed level of `hz` in this 20 ms piece (scaled so a full-scale sine reads 0 dB).
        const double p = windowed_power(x + start, win, rate, hz);
        const double amp = 4.0 * std::sqrt(p) / double(win);
        if (to_db(amp) > threshold_db) return double(start + win / 2) / rate;
    }
    return -1;
}

}  // namespace ps
