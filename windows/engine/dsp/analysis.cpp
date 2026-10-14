#include "dsp/analysis.h"

#include <algorithm>
#include <cmath>

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
    const double w = 2 * kPi * hz / rate;
    double re = 0, im = 0;
    for (size_t i = 0; i < n; ++i) {
        const double win = 0.5 - 0.5 * std::cos(2 * kPi * double(i) / double(n));
        re += x[i] * win * std::cos(w * double(i));
        im -= x[i] * win * std::sin(w * double(i));
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

}  // namespace ps
