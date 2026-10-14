// Advanced processing engine (see AdvancedChain.h). Ported from the research test bench (dspchain, recipe "balanced3").
//
// How it is built:
// - A "chain" is the whole recipe for ONE fixed amount N: band filters, 1-3 Rubber Band shifters, the air band and
//   an EQ. Every path inside a chain is read at the same fixed total delay, so the paths stay lined up exactly.
// - Rubber Band's delay is only known exactly for a fresh shifter (research round 3: after setPitchScale on a running
//   shifter its delay moves by up to 31 ms, depending on its history). So a new N never retunes a running chain:
//   a NEW chain is started with fresh shifters, fed the last part of the input from a history buffer (faster than
//   real time, but a bounded amount per call), and once it has caught up it is faded in over 80 ms.
// - Fresh shifters come from a pool made in advanced_new. Rubber Band's reset() makes memory, so used shifters are
//   reset by a small helper thread, never by the sound thread. They are handed over with atomic flags (no locks).
// - The EQ looks at the long-term spectrum. Its analysis (two big FFTs and a fit) is cut into 8 slices, one slice per
//   256 samples, so no single call has to do all of it.
#include "AdvancedChain.h"
#include "AdvancedTuning.h"
#include <rubberband/RubberBandStretcher.h>
#include <Accelerate/Accelerate.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <complex>
#include <cstdint>
#include <cstring>
#include <memory>
#include <string>
#include <thread>
#include <vector>

using RubberBand::RubberBandStretcher;

namespace {

const int MAXCH = 2;     // channels
const int MAXPATHS = 3;  // shifted paths in one chain
const int NEQ = 10;      // EQ filters
const int RBOPTS = RubberBandStretcher::OptionProcessRealTime | RubberBandStretcher::OptionEngineFiner |
                   RubberBandStretcher::OptionChannelsTogether;  // the app's normal settings

// ------------------------------------------------------------------------------------------------- filters

// One second-order filter (transposed direct form II, double precision), designs from the RBJ audio EQ cookbook.
struct Biquad {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0;
    inline float run(float x) { double y = b0 * x + z1; z1 = b1 * x - a1 * y + z2; z2 = b2 * x - a2 * y; return (float)y; }
    void clear() { z1 = z2 = 0; }
    void set(double B0, double B1, double B2, double A0, double A1, double A2) {
        b0 = B0 / A0; b1 = B1 / A0; b2 = B2 / A0; a1 = A1 / A0; a2 = A2 / A0;
    }
    void copyCoefs(const Biquad &o) { b0 = o.b0; b1 = o.b1; b2 = o.b2; a1 = o.a1; a2 = o.a2; }
    void lowpass(double f, double q, double sr) {
        double w = 2 * M_PI * f / sr, al = sin(w) / (2 * q), c = cos(w);
        set((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + al, -2 * c, 1 - al);
    }
    void highpass(double f, double q, double sr) {
        double w = 2 * M_PI * f / sr, al = sin(w) / (2 * q), c = cos(w);
        set((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + al, -2 * c, 1 - al);
    }
    void peaking(double f, double q, double gdb, double sr) {
        double A = pow(10, gdb / 40), w = 2 * M_PI * f / sr, al = sin(w) / (2 * q), c = cos(w);
        set(1 + al * A, -2 * c, 1 - al * A, 1 + al / A, -2 * c, 1 - al / A);
    }
    void lowshelf(double f, double gdb, double sr) {
        double A = pow(10, gdb / 40), w = 2 * M_PI * f / sr, c = cos(w), al = sin(w) / 2 * sqrt(2.0), sA = 2 * sqrt(A) * al;
        set(A * ((A + 1) - (A - 1) * c + sA), 2 * A * ((A - 1) - (A + 1) * c), A * ((A + 1) - (A - 1) * c - sA),
            (A + 1) + (A - 1) * c + sA, -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - sA);
    }
    void highshelf(double f, double gdb, double sr) {
        double A = pow(10, gdb / 40), w = 2 * M_PI * f / sr, c = cos(w), al = sin(w) / 2 * sqrt(2.0), sA = 2 * sqrt(A) * al;
        set(A * ((A + 1) + (A - 1) * c + sA), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - sA),
            (A + 1) - (A - 1) * c + sA, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - sA);
    }
    double magDb(double f, double sr) const {  // gain at frequency f
        std::complex<double> z = std::polar(1.0, -2 * M_PI * f / sr), zz = z * z;
        return 20 * log10(std::abs((b0 + b1 * z + b2 * zz) / (1.0 + a1 * z + a2 * zz)));
    }
};

// Linkwitz-Riley 4th order = two identical Butterworth stages. Its low and high outputs are in phase and add up flat.
struct LR4 {
    Biquad s1, s2;
    void lowpass(double f, double sr) { s1.lowpass(f, M_SQRT1_2, sr); s2 = s1; clear(); }
    void highpass(double f, double sr) { s1.highpass(f, M_SQRT1_2, sr); s2 = s1; clear(); }
    void clear() { s1.clear(); s2.clear(); }
    inline float run(float x) { return s2.run(s1.run(x)); }
};
inline double lrLP(double f, double fc) { double x = f / fc; x *= x; x *= x; return 1.0 / (1.0 + x); }  // |LR4 low-pass|
inline double lrHP(double f, double fc) { double x = f / fc; x *= x; x *= x; return x / (1.0 + x); }    // |LR4 high-pass|

// One channel of sound kept by absolute sample number (power-of-two size, so the index wraps with a mask).
struct Ring {
    std::vector<float> d;
    int64_t mask = 0;
    void init(size_t n) { size_t s = 1; while (s < n) s <<= 1; d.assign(s, 0.0f); mask = (int64_t)s - 1; }
    inline float &operator[](int64_t i) { return d[(size_t)(i & mask)]; }
    void clear() { std::fill(d.begin(), d.end(), 0.0f); }
};

size_t pow2above(size_t n) { size_t s = 1; while (s < n) s <<= 1; return s; }

// ------------------------------------------------------------------------------------------------- recipe

// What feeds a path: a sum of up to 3 "terms"; each term is the input through up to 3 LR4 filters, times a gain.
// Example (balanced3 at +8): main = HP150(x) + LP35'(LP300(x)) (the fold floor's sub bass), fold = HP35'(LP300(x)).
const int MAXTERMS = 3, MAXF = 3;
struct Term {
    float gain = 1;
    int nf = 0;                 // filters in the cascade (0 = the input itself)
    double fc[MAXF] = {};       // corner (Hz)
    bool hp[MAXF] = {};         // high-pass (else low-pass)
    double mag(double f) const { double m = gain; for (int i = 0; i < nf; i++) m *= hp[i] ? lrHP(f, fc[i]) : lrLP(f, fc[i]); return m; }
};

struct PathSpec {
    double shift = 0;           // half-steps; 0 = not shifted (just delayed)
    float outW = 1;             // level at the output
    int nt = 0;
    Term t[MAXTERMS];
    bool coherent = false;      // terms are in phase (LR4 pair at one corner): they add as amplitudes, else as powers
    double outHP = 0;           // 8th-order high-pass on the path's output (Hz), 0 = none (balanced3: 30 Hz on the +4..+6 fold)
    Term &add(float gain) { Term &x = t[nt++]; x.gain = gain; return x; }
};
inline Term &lp(Term &x, double f) { x.fc[x.nf] = f; x.hp[x.nf++] = false; return x; }
inline Term &hp(Term &x, double f) { x.fc[x.nf] = f; x.hp[x.nf++] = true; return x; }

struct Spec {           // the recipe for one amount N
    double N = 0;
    int n = 0;          // paths (0 = the unprocessed input)
    PathSpec p[MAXPATHS];
    double air = 0;     // pitch-down: above this (Hz) the output is the unshifted input; 0 = none
};

// ------------------------------------------------------------------------------------------------- shifter pool

enum { SH_FRESH = 0, SH_IN_USE = 1, SH_DIRTY = 2 };
struct Shifter {
    std::unique_ptr<RubberBandStretcher> rb;
    std::atomic<int> state{SH_FRESH};
};

// ------------------------------------------------------------------------------------------------- chain

enum { C_FREE, C_WARMING, C_PREROLL, C_FADE_IN, C_ACTIVE };

struct Path {
    PathSpec spec;
    Shifter *sh = nullptr;   // null: not shifted (a plain delay)
    int64_t lag = 0;         // where the shifter puts input sample i in its output stream: i + lag (fresh shifter)
    int64_t produced = 0;    // samples in its output stream so far
    Ring ring[MAXCH];        // its output stream
    LR4 filt[MAXTERMS][MAXF][MAXCH];   // input filters, one set per term
    Biquad outF[4][MAXCH];             // output high-pass (4 Butterworth sections)
};

struct Chain {
    int state = C_FREE;
    Spec spec;
    Path path[MAXPATHS];
    LR4 airLP[MAXCH], airHP[MAXCH];
    // EQ filters with their gains (dB): applied now, moving toward target in small steps
    Biquad eq[MAXCH][NEQ];
    double eqApplied[NEQ] = {}, eqInc[NEQ] = {};
    int eqSteps = 0, eqCount = 0;
    bool eqFresh = true;
    int64_t h0 = 0;          // first input sample this chain was fed
    int64_t p = 0;           // next input sample to feed
    int64_t V = 0;           // its output is right for input samples >= h0 + V (shifters need a moment to start)
    int64_t phase = 0;       // samples spent in PREROLL or FADE_IN
    bool dry() const { return spec.n == 0; }
};

// ------------------------------------------------------------------------------------------------- tonal EQ

// Slow, gentle EQ that steers the output's long-term 1/3-octave spectrum toward the input's (hybrid mode of the
// research): the target compares the input with a PREDICTED output spectrum (input moved by the chain's shifts,
// with its bands and air), plus a slow correction (+-3 dB, 12 s) from the measured output for what the prediction
// misses. 10 minimum-phase filters, fitted by least squares. Zero delay.
struct TonalEQ {
    double sr = 48000, tau = 4, boost = 9, cut = 9, alpha = 1, lowcap = 6, midcap = 6, shelfLo = 44;
    double loF = 100, loCut = 15;        // balanced3: below 100 Hz the target is not smoothed and may cut up to 15 dB
    int smooth = 1, N = 16384, period = 2048;
    FFTSetup setup = nullptr; int log2n = 14;
    std::vector<float> hann, tmp, re, im;
    std::vector<double> fcs, rbin, pref, pcur, pr, pc, pq, pqs, pcs, T, S, g, e;
    std::vector<int> b0, b1, bandOf;
    std::vector<std::vector<double>> M;  // least-squares fit matrix (filters x bands)
    double eqf[NEQ];
    int64_t blocks = 0, blocks2 = 0;     // analyses so far; analyses since the slow correction was reset
    double a = 0;
    int gen = -1;                        // which chain the current prediction is for (see Engine::targetGen)

    void setFilter(Biquad &b, int k, double gdb) const {
        if (k == 0) b.lowshelf(shelfLo, gdb, sr);
        else if (k == 9) b.highshelf(11300.0, gdb, sr);
        else b.peaking(eqf[k], 1.41, gdb, sr);
    }

    void init(double rate) {
        sr = rate;
        N = rate > 64000 ? 32768 : 16384;
        log2n = (int)lround(log2(N));
        setup = vDSP_create_fftsetup(log2n, kFFTRadix2);
        hann.resize(N); tmp.resize(N); re.resize(N / 2); im.resize(N / 2);
        for (int i = 0; i < N; i++) hann[i] = (float)(0.5 * (1 - cos(2 * M_PI * i / N)));
        for (int k = -16; k <= 12; k++) {
            double fc = 1000.0 * pow(10.0, k / 10.0); fcs.push_back(fc);
            b0.push_back(std::max(1, (int)floor(fc * pow(2, -1.0 / 6) * N / sr)));
            b1.push_back(std::max(b0.back() + 1, (int)ceil(fc * pow(2, 1.0 / 6) * N / sr)));
        }
        size_t nb = fcs.size();
        bandOf.assign(N / 2, -1);  // FFT bin -> 1/3-octave band (first match, as the test bench)
        for (int i = 0; i < N / 2; i++)
            for (size_t j = 0; j < nb; j++) if (i >= b0[j] && i < b1[j]) { bandOf[i] = (int)j; break; }
        rbin.assign(N / 2, 0.0);
        for (auto *v : {&pref, &pcur, &pr, &pc, &pq, &pqs, &pcs, &T, &S, &e}) v->assign(nb, 0.0);
        g.assign(NEQ, 0.0);
        for (int k = 0; k < NEQ; k++) eqf[k] = 31.25 * pow(2.0, k);
        // how each filter at 12 dB shows up in each band; M = (A^T A + 0.05 I)^-1 A^T
        std::vector<std::vector<double>> A(nb, std::vector<double>(NEQ));
        for (int k = 0; k < NEQ; k++) { Biquad b; setFilter(b, k, 12.0); for (size_t j = 0; j < nb; j++) A[j][k] = b.magDb(fcs[j], sr) / 12.0; }
        std::vector<std::vector<double>> AtA(NEQ, std::vector<double>(NEQ, 0.0)), inv(NEQ, std::vector<double>(NEQ, 0.0));
        for (int x = 0; x < NEQ; x++) for (int y = 0; y < NEQ; y++) {
            for (size_t j = 0; j < nb; j++) AtA[x][y] += A[j][x] * A[j][y];
            if (x == y) AtA[x][y] += 0.05;
        }
        for (int i = 0; i < NEQ; i++) inv[i][i] = 1;
        for (int i = 0; i < NEQ; i++) {  // Gauss-Jordan
            int p = i; for (int r = i + 1; r < NEQ; r++) if (fabs(AtA[r][i]) > fabs(AtA[p][i])) p = r;
            std::swap(AtA[i], AtA[p]); std::swap(inv[i], inv[p]);
            double d = AtA[i][i]; for (int c = 0; c < NEQ; c++) { AtA[i][c] /= d; inv[i][c] /= d; }
            for (int r = 0; r < NEQ; r++) if (r != i) { double f = AtA[r][i]; for (int c = 0; c < NEQ; c++) { AtA[r][c] -= f * AtA[i][c]; inv[r][c] -= f * inv[i][c]; } }
        }
        M.assign(NEQ, std::vector<double>(nb, 0.0));
        for (int x = 0; x < NEQ; x++) for (size_t j = 0; j < nb; j++) for (int y = 0; y < NEQ; y++) M[x][j] += inv[x][y] * A[j][y];
    }
    ~TonalEQ() { if (setup) vDSP_destroy_fftsetup(setup); }

    void reset() {
        std::fill(rbin.begin(), rbin.end(), 0.0);
        for (auto *v : {&pref, &pcur, &pqs, &pcs}) std::fill(v->begin(), v->end(), 0.0);
        blocks = blocks2 = 0; gen = -1;
    }
    void resetCorrection() { std::fill(pqs.begin(), pqs.end(), 0.0); std::fill(pcs.begin(), pcs.end(), 0.0); blocks2 = 0; }

    // FFT of the last N samples of a ring ending at `end`; band powers into out (FFT left in re/im)
    void bandPowers(Ring &r, int64_t end, std::vector<double> &out) {
        for (int i = 0; i < N; i++) tmp[i] = r[end - N + i] * hann[i];
        DSPSplitComplex s{re.data(), im.data()};
        vDSP_ctoz((const DSPComplex *)tmp.data(), 2, &s, 1, N / 2);
        vDSP_fft_zrip(setup, &s, 1, log2n, FFT_FORWARD);
        for (size_t j = 0; j < fcs.size(); j++) {
            double sum = 0;
            for (int k = b0[j]; k < b1[j] && k < N / 2; k++) sum += (double)re[k] * re[k] + (double)im[k] * im[k];
            out[j] = sum;
        }
    }
    inline void addAt(double fo, double p) {
        double kb = fo * N / sr;
        if (kb < 0 || kb >= N / 2) return;
        int j = bandOf[(int)kb];
        if (j >= 0) pq[j] += p;
    }
    // predicted output band powers of chain spec s, bins [k0, k1): each input bin is moved by each path's shift,
    // weighted by that path's input filters (and output high-pass, and the air band's crossover)
    void predict(const Spec &s, int k0, int k1) {
        double ratio[MAXPATHS];
        for (int q = 0; q < s.n; q++) ratio[q] = pow(2.0, s.p[q].shift / 12.0);
        for (int k = std::max(1, k0); k < k1; k++) {
            double P = rbin[k];
            if (P <= 0) continue;
            double f = (double)k * sr / N;
            for (int q = 0; q < s.n; q++) {
                const PathSpec &p = s.p[q];
                double pw = 0, amp = 0;
                for (int i = 0; i < p.nt; i++) { double m = p.t[i].mag(f); amp += m; pw += m * m; }
                if (p.coherent) pw = amp * amp;
                pw *= (double)p.outW * p.outW;
                double fo = f * ratio[q];
                if (s.air > 0) { double ga = lrLP(fo, s.air); pw *= ga * ga; }
                if (p.outHP > 0) { double h = lrHP(fo, p.outHP); pw *= h * h * h * h; }  // 8th order = |LR4|^2
                addAt(fo, P * pw);
            }
            if (s.air > 0) { double h = lrHP(f, s.air); addAt(f, P * h * h); }
        }
    }
};

// ------------------------------------------------------------------------------------------------- safety limiter

// Peak limiter at the very end, so the output never goes over the ceiling (-0.3 dBFS). Both channels get the same gain.
// It looks D samples (2 ms) ahead: the sound is delayed by D, and the gain for each sample is the average of the last
// D+1 "held" gains. Every one of those held values is <= the gain the delayed sample needs (each hold window contains
// that sample), so their average is too: no overs, and the gain slides down over 2 ms instead of jumping.
// Release: the held gain climbs back toward 1 with a 120 ms time constant. Under the ceiling it does nothing at all
// (gain exactly 1, the output is the input delayed by D).
struct Limiter {
    int nch = 2, D = 96, R = 97, pos = 0;
    double ceiling = 0.966, relCoef = 0.9998, r = 1, sum = 97;
    int64_t sinceOver = 1 << 30;
    std::vector<float> delay[MAXCH];
    std::vector<double> need, held;   // gain each sample needs; held (released) gain, last D+1 of each
    bool enabled = true;
    double minGain = 1; long long limited = 0, limited01 = 0, total = 0, clamps = 0;  // for checks (limited01: > 0.1 dB)

    void init(double sr, int channels) {
        nch = channels;
        D = std::max(1, (int)lround(0.002 * sr)); R = D + 1;
        relCoef = exp(-1.0 / (0.120 * sr));
        for (int c = 0; c < nch; c++) delay[c].assign(R, 0.0f);
        need.assign(R, 1.0); held.assign(R, 1.0);
        reset();
    }
    void reset() {
        for (int c = 0; c < nch; c++) std::fill(delay[c].begin(), delay[c].end(), 0.0f);
        std::fill(need.begin(), need.end(), 1.0); std::fill(held.begin(), held.end(), 1.0);
        r = 1; sum = R; pos = 0; sinceOver = 1 << 30;
    }
    // v: one sample per channel, replaced by the limited sample from D samples ago
    inline void run(float *v) {
        double peak = 0;
        for (int c = 0; c < nch; c++) peak = std::max(peak, (double)fabsf(v[c]));
        // aim a hair (0.00003 dB) under the ceiling, so float rounding of the result never lands above it
        double g = (enabled && peak > ceiling) ? ceiling * (1.0 - 4e-6) / peak : 1.0;
        need[pos] = g;
        sinceOver = g < 1.0 ? 0 : sinceOver + 1;
        double m = 1.0;  // lowest need in the last D+1 samples (only searched while an over is in the window)
        if (sinceOver <= D) for (int k = 0; k < R; k++) m = std::min(m, need[k]);
        if (m < r) r = m;                    // drops at once (the averaging below makes it a 2 ms slide)
        else {
            r = m - (m - r) * relCoef;       // climbs back slowly
            if (m == 1.0 && r > 1.0 - 1e-7) r = 1.0;
        }
        sum += r - held[pos]; held[pos] = r;
        double gain = std::min(1.0, sum / R);
        int out = pos + 1 == R ? 0 : pos + 1;  // the oldest slot holds the sample from D samples ago
        for (int c = 0; c < nch; c++) {
            delay[c][pos] = v[c];
            float y = delay[c][out];
            if (gain < 1.0) {
                y = (float)(y * gain);
                if (y > ceiling || y < -ceiling) { y = y > 0 ? (float)ceiling : (float)-ceiling; clamps++; }  // rounding guard
            }
            v[c] = y;
        }
        total++;
        if (gain < 1.0) { limited++; minGain = std::min(minGain, gain); if (gain < 0.98855) limited01++; }
        if (++pos == R) {  // re-add the held gains exactly once per lap, so rounding never builds up
            pos = 0;
            sum = 0; for (int k = 0; k < R; k++) sum += held[k];
        }
    }
};

// ------------------------------------------------------------------------------------------------- engine

struct Engine {
    double sr; int nch, maxFrames, flags;
    int L = 0;            // total delay (frames), fixed
    int W2 = 2048;        // half of Rubber Band's analysis window at this rate
    int SB = 256;         // slice size for spreading the EQ work
    int PIECE = 512;      // largest piece handed to a shifter at once
    double range = 24;
    // tunables (see AdvancedTuning.h)
    int recipe = 3, fold2 = 1, floor2 = 1; double airMin = 7000; int catchup = 2; double fadeMs = 80, foldStart = 3, foldFull = 7;
    double floorHz = 35, floorOut = 30;
    int64_t fadeLen = 3840, prerollLen = 1024;

    std::vector<std::unique_ptr<Shifter>> pool;
    std::thread worker;
    std::atomic<bool> quit{false};

    Ring hist[MAXCH], keepR[MAXCH], cur;   // input minus keep; keep; measured output (mono, for the EQ)
    int64_t t = 0, tStart = 0;             // samples processed; where the sound history starts (after a reset)
    Chain chains[2];
    int active = 0, next = -1;             // the chain being heard, and the one getting ready (or -1)
    double wantN = 0;                      // newest amount asked for
    bool pending = false;
    bool equalPower = true;                // crossfade law for the current fade
    int targetGen = 0;                     // changes whenever the EQ's target chain changes
    TonalEQ eq;
    Limiter lim;                           // safety limiter at the very end (adds its 2 ms look-ahead to the delay)
    long long underruns = 0, switches = 0;
    float keepG = 0, keepStep = 1;          // keep fade-in: level now, step per sample
    int64_t keepIdle = 0, keepIdleLimit = 1; // samples since keep was last non-zero; after 0.25 s it counts as off

    // scratch (made once)
    std::vector<float> xin[MAXCH], tmpT[MAXCH], pin[MAXCH], rbOut[MAXCH], acc[MAXCH], sum[MAXCH], pre[MAXCH], curMono, gain;

    Engine(double rate, int channels, int maxF, int fl) : sr(rate), nch(channels), maxFrames(maxF), flags(fl) {}

    bool setup() {
        range = (flags & ADVANCED_RANGE_12) ? 12 : 24;
        bool high = sr > 64000;
        SB = high ? 512 : 256;
        PIECE = high ? 1024 : 512;
        fadeLen = (int64_t)lround(fadeMs * 0.001 * sr);
        prerollLen = (int64_t)lround(0.0213 * sr);
        keepStep = (float)(1.0 / (0.030 * sr));
        keepIdleLimit = keepIdle = (int64_t)(0.25 * sr);
        lim.init(sr, nch);
        // two chains (the one heard and the next) of up to 3 shifters each, plus one spare while the helper resets
        // used ones. About 4.5 MB each at 48 kHz, 8 MB at 96 kHz.
        int poolSize = 2 * MAXPATHS + 1;
        for (int i = 0; i < poolSize; i++) {
            auto s = std::make_unique<Shifter>();
            s->rb.reset(new RubberBandStretcher((size_t)lround(sr), nch, RBOPTS, 1.0, 1.0));
            s->rb->setMaxProcessSize(1024);
            pool.push_back(std::move(s));
        }
        W2 = (int)pool[0]->rb->getStartDelay();  // half window at pitch 1.0 (2048 at 44.1/48 kHz, 4096 at 96 kHz)
        // Fixed delay: the worst fresh shifter over the whole range (measured with rbprobe: "fed minus retrieved" at worst,
        // plus where it places the sound; 5.09 x W2 at +-24, 3.06 x W2 at +-12), plus 1/8 W2 margin.
        L = (int)ceil((range > 12 ? 5.1 : 3.06) * W2) + W2 / 8;
        prewarm();
        size_t vmax = (size_t)(range > 12 ? 3 * W2 : W2) + (size_t)(1.5 * W2);
        size_t histSize = pow2above(std::max<size_t>(L + vmax + maxFrames + 4 * SB, 16384 * (high ? 2 : 1) + maxFrames + 4 * SB));
        if (nch > 1) refRing.init(histSize);
        for (int c = 0; c < nch; c++) {
            hist[c].init(histSize);
            keepR[c].init(L + maxFrames + 2 * SB);
            xin[c].assign(PIECE, 0.0f); pin[c].assign(PIECE, 0.0f); rbOut[c].assign(4096, 0.0f);
            tmpT[c].assign(PIECE, 0.0f);
            acc[c].assign(SB, 0.0f); sum[c].assign(SB, 0.0f); pre[c].assign(SB, 0.0f);
            for (auto &ch : chains) for (auto &p : ch.path) p.ring[c].init(L + maxFrames + 4096);
        }
        curMono.assign(SB, 0.0f); gain.assign(SB, 0.0f);
        eq.init(sr);
        eq.period = 8 * SB;
        cur.init(eq.N + 2 * SB);
        chains[0].state = C_ACTIVE;  // starts with the unprocessed input (N = 0)
        worker = std::thread([this] { tidyLoop(); });
        return true;
    }

    // Run every shifter once at a pitch up and a pitch down, so any memory Rubber Band makes on first use is made now.
    void prewarm() {
        std::vector<float> z(1024);
        uint32_t seed = 1;
        for (auto &v : z) { seed = seed * 1664525u + 1013904223u; v = ((seed >> 9) / 8388608.0f - 1.0f) * 0.01f; }
        const float *ip[MAXCH] = {z.data(), z.data()};
        std::vector<float> o0(8192), o1(8192);
        float *op[MAXCH] = {o0.data(), o1.data()};
        for (auto &s : pool) {
            for (double sc : {1.5, 0.7}) {
                s->rb->setPitchScale(sc);
                for (int k = 0; k < 6; k++) { s->rb->process(ip, 1024, false); int a; while ((a = s->rb->available()) > 0) s->rb->retrieve(op, std::min(a, 8192)); }
            }
            s->rb->reset();
            s->rb->setPitchScale(1.0);
        }
    }

    // Helper thread: resets used shifters so they are fresh again. It only touches shifters marked DIRTY,
    // which the sound thread has let go of.
    void tidyLoop() {
        while (!quit.load(std::memory_order_acquire)) {
            for (auto &s : pool)
                if (s->state.load(std::memory_order_acquire) == SH_DIRTY) {
                    s->rb->reset();
                    s->state.store(SH_FRESH, std::memory_order_release);
                }
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
    }

    ~Engine() {
        quit.store(true, std::memory_order_release);
        if (worker.joinable()) worker.join();
    }

    // ---------------------------------------------------------------- the rule for any N

    // The recipe for amount N ("balanced3", research round 4, extended to +-24 by the numbers in the engine report):
    //  N = 0      the input, untouched.
    //  N < 0      shift the whole input by N; above the air cut-off max(15 kHz x 2^(N/12), 7 kHz) use the unshifted input.
    //  0 < N <= 3 shift the whole input by N.
    //  3 < N < 7  fold ramp that splits by frequency: t = (N-3)/4; main = above 150t Hz, shifted by N;
    //             fold = below 300t Hz, shifted by N-12, with a 30 Hz high-pass on its output.
    //  7 <= N <= 15  main = above 150 Hz (N); fold = below 300 Hz (N-12; at exactly +12 not shifted, only delayed).
    //  Fold floor (folds that move down, +3 < N < +12): fold-band bass that would land below 35 Hz,
    //             i.e. below 35 x 2^((12-N)/12) Hz, goes to the main path instead.
    //  15 < N < 19  second fold comes in the same way: t2 = (N-15)/4; fold2 = below 600t2 Hz shifted by N-24;
    //             fold = 300t2..300 Hz (N-12); main as before. (3 shifters only here.)
    //  19 <= N <= 24  main = above 150 Hz (N); fold2 = below 600 Hz (N-24; at +24 only delayed). Two octaves overlap,
    //             because the two paths are two octaves apart, so the output has no gap.
    //  Second-fold floor (15 < N < 24): like the fold floor (35 Hz, and the 30 Hz output high-pass during its ramp),
    //             with the sub going one level up: to the first fold while it is there, else to main.
    Spec rule(double N) const {
        Spec s; s.N = N;
        auto path = [&](double shift) -> PathSpec & { PathSpec &p = s.p[s.n++]; p = PathSpec(); p.shift = shift; return p; };
        if (N == 0) return s;
        if (N < 0) {
            path(N).add(1);
            s.air = std::max(15000.0 * pow(2.0, N / 12.0), airMin);
            if (s.air > 0.45 * sr) s.air = 0;
            return s;
        }
        if (N <= foldStart) { path(N).add(1); return s; }
        if (recipe == 2 && N < foldFull) {  // balanced2 (test only): blend ramp, the unfolded low band rides in the main shifter
            double w = (N - foldStart) / (foldFull - foldStart);
            PathSpec &m = path(N); m.coherent = true; hp(m.add(1), 150); lp(m.add((float)(1 - w)), 150);
            PathSpec &f = path(N - 12); f.outW = (float)w; lp(f.add(1), 300);
            return s;
        }
        if (N <= 15 || !fold2) {  // one fold
            double t = std::min(1.0, (N - foldStart) / (foldFull - foldStart));
            double FH = 150 * t, FL = 300 * t;
            PathSpec &m = path(N); hp(m.add(1), FH);
            PathSpec &f = path(N - 12); Term &ft = lp(f.add(1), FL);
            if (recipe == 3 && N < 12) {  // fold floor
                double FX = floorHz * pow(2.0, (12 - N) / 12.0);
                lp(lp(m.add(1), FL), FX);
                hp(ft, FX);
                if (N < foldFull) f.outHP = floorOut;
            }
            return s;
        }
        // second fold
        double t2 = std::min(1.0, (N - 15) / (foldFull - foldStart)), x = 300 * t2;
        PathSpec &m = path(N); hp(m.add(1), 150);
        PathSpec *f1 = nullptr;
        if (t2 < 1) { f1 = &path(N - 12); hp(lp(f1->add(1), 300), x); }
        PathSpec &f2 = path(N - 24); Term &ft = lp(f2.add(1), 2 * x);
        if (floor2 && N < 24) {  // its sub bass goes one level up: to the first fold while it is there, else to main
            double FX = floorHz * pow(2.0, (24 - N) / 12.0);
            PathSpec &up = f1 ? *f1 : m;
            lp(lp(up.add(1), 2 * x), FX);
            hp(ft, FX);
            if (t2 < 1) f2.outHP = floorOut;
        }
        return s;
    }

    // ---------------------------------------------------------------- chains

    void retire(Chain &ch) {
        for (int q = 0; q < ch.spec.n; q++)
            if (ch.path[q].sh) { ch.path[q].sh->state.store(SH_DIRTY, std::memory_order_release); ch.path[q].sh = nullptr; }
        ch.state = C_FREE;
    }

    // Start a chain for amount N in slot `slot`. False if not enough fresh shifters yet (try again soon).
    bool start(int slot, double N) {
        Chain &ch = chains[slot];
        Spec s = rule(N);
        Shifter *got[MAXPATHS] = {};
        int needed = 0, have = 0;
        for (int q = 0; q < s.n; q++) if (s.p[q].shift != 0) needed++;
        for (auto &sh : pool) {
            if (have == needed) break;
            if (sh->state.load(std::memory_order_acquire) == SH_FRESH) got[have++] = sh.get();
        }
        if (have < needed) return false;
        ch.spec = s;
        int k = 0;
        int64_t vmax = 0;
        for (int q = 0; q < s.n; q++) {
            Path &p = ch.path[q];
            p.spec = s.p[q]; p.produced = 0; p.lag = 0; p.sh = nullptr;
            if (s.p[q].shift != 0) {
                p.sh = got[k++];
                p.sh->state.store(SH_IN_USE, std::memory_order_relaxed);
                p.sh->rb->setPitchScale(pow(2.0, s.p[q].shift / 12.0));
                p.lag = (int64_t)p.sh->rb->getStartDelay() - (int64_t)p.sh->rb->getPreferredStartPad();
                // measured with rbprobe --warm: full level from about max(0, -lag) + 60 ms after the start
                vmax = std::max(vmax, std::max<int64_t>(0, -p.lag) + (int64_t)(1.5 * W2));
            }
        }
        for (int q = 0; q < s.n; q++) {  // each path's input filters and output high-pass, fresh state
            Path &p = ch.path[q];
            for (int i = 0; i < p.spec.nt; i++)
                for (int k = 0; k < p.spec.t[i].nf; k++)
                    for (int c = 0; c < nch; c++) {
                        if (p.spec.t[i].hp[k]) p.filt[i][k][c].highpass(p.spec.t[i].fc[k], sr);
                        else p.filt[i][k][c].lowpass(p.spec.t[i].fc[k], sr);
                    }
            if (p.spec.outHP > 0)
                for (int k = 0; k < 4; k++) for (int c = 0; c < nch; c++) { p.outF[k][c].highpass(p.spec.outHP, M_SQRT1_2, sr); p.outF[k][c].clear(); }
        }
        for (int c = 0; c < nch; c++) {
            if (s.air > 0) { ch.airLP[c].lowpass(s.air, sr); ch.airHP[c].highpass(s.air, sr); }
            for (int b = 0; b < NEQ; b++) ch.eq[c][b].clear();
        }
        // EQ: start from the gains being heard, take the first gains made for this chain at once
        Chain &A = chains[active];
        for (int b = 0; b < NEQ; b++) { ch.eqApplied[b] = A.dry() ? 0.0 : A.eqApplied[b]; ch.eqInc[b] = 0; }
        ch.eqSteps = 0; ch.eqCount = 0; ch.eqFresh = true;
        setEqFilters(ch);
        // feed it from a little in the past, so it can be heard soon after it catches up
        ch.V = vmax;
        int64_t H = (L + vmax) * (catchup - 1) / catchup;
        ch.h0 = std::max(t - H, tStart);
        ch.p = ch.h0;
        ch.phase = 0;
        ch.state = C_WARMING;
        // the EQ's slow correction belongs to the old amount: start it over after a big change
        if (fabs(N - A.spec.N) > 1.0) eq.resetCorrection();
        targetGen++;
        return true;
    }

    void setEqFilters(Chain &ch) {
        for (int b = 0; b < NEQ; b++) {
            Biquad d; eq.setFilter(d, b, ch.eqApplied[b]);
            for (int c = 0; c < nch; c++) ch.eq[c][b].copyCoefs(d);
        }
    }

    // Decide what happens next: start a new chain, fade, finish a fade.
    void manage() {
        if (pending) {
            if (next >= 0 && chains[next].state != C_FADE_IN) {  // a new amount came while one was getting ready
                if (chains[next].spec.N == wantN) pending = false;
                else { retire(chains[next]); next = -1; targetGen++; }
            }
            if (pending && next < 0) {
                if (wantN == chains[active].spec.N) pending = false;  // back to what is playing
                else {
                    int slot = 1 - active;
                    if (wantN == 0) {  // the unprocessed input needs no shifters and is always ready
                        Chain &ch = chains[slot];
                        ch.spec = Spec(); ch.state = C_WARMING; ch.h0 = ch.p = t; ch.V = 0; ch.phase = 0;
                        next = slot; pending = false; targetGen++;
                    } else if (start(slot, wantN)) { next = slot; pending = false; }
                }
            }
        }
        if (next < 0) return;
        Chain &B = chains[next];
        // ready: caught up, and far enough past its start that its shifters sound right. The unprocessed input (N = 0)
        // is always ready, but waits about as long as a shifted amount would, so clicking quickly through 0 doesn't
        // flash the original pitch.
        bool ready = B.dry() ? (t - B.h0 >= dryWait() || B.h0 <= tStart)
                             : (B.p == t && (t - L >= B.h0 + B.V || B.h0 <= tStart));
        if (B.state == C_WARMING && ready) {
            if (t <= tStart + L) { switchNow(); return; }  // nothing real has come out yet: no fade needed
            B.state = B.dry() ? C_FADE_IN : C_PREROLL;
            B.phase = 0;
            equalPower = fabs(B.spec.N - chains[active].spec.N) >= 0.5;  // different pitches don't add up in phase
        }
        if (B.state == C_PREROLL && B.phase >= prerollLen) { B.state = C_FADE_IN; B.phase = 0; }
        if (B.state == C_FADE_IN && B.phase >= fadeLen) { switchNow(); switches++; }
    }

    int64_t dryWait() const { return (L + (int64_t)(1.5 * W2)) / catchup; }

    void switchNow() {
        retire(chains[active]);
        active = next; next = -1;
        chains[active].state = C_ACTIVE;
    }

    // Feed chain ch with input samples up to (not including) `upto`.
    void feed(Chain &ch, int64_t upto) {
        if (ch.dry()) { ch.p = upto; return; }
        while (ch.p < upto) {
            int q = (int)std::min<int64_t>(upto - ch.p, PIECE);
            for (int c = 0; c < nch; c++) { float *x = xin[c].data(); for (int i = 0; i < q; i++) x[i] = hist[c][ch.p + i]; }
            for (int k = 0; k < ch.spec.n; k++) {
                Path &p = ch.path[k];
                const float *src[MAXCH];
                for (int c = 0; c < nch; c++) {
                    const float *x = xin[c].data();
                    if (p.spec.nt == 1 && p.spec.t[0].nf == 0 && p.spec.t[0].gain == 1) { src[c] = x; continue; }  // whole input
                    float *o = pin[c].data(), *y = tmpT[c].data();
                    std::fill(o, o + q, 0.0f);
                    for (int i = 0; i < p.spec.nt; i++) {  // sum of terms, each = gain x (input through its LR4 filters)
                        const Term &tm = p.spec.t[i];
                        std::copy(x, x + q, y);
                        for (int f = 0; f < tm.nf; f++) { LR4 &flt = p.filt[i][f][c]; for (int j = 0; j < q; j++) y[j] = flt.run(y[j]); }
                        for (int j = 0; j < q; j++) o[j] += tm.gain * y[j];
                    }
                    src[c] = o;
                }
                if (p.sh) {
                    p.sh->rb->process(src, q, false);
                    drain(p);
                } else store(p, src, q);
            }
            ch.p += q;
        }
    }

    void drain(Path &p) {
        int a;
        float *op[MAXCH] = {rbOut[0].data(), nch > 1 ? rbOut[1].data() : nullptr};
        while ((a = p.sh->rb->available()) > 0) {
            size_t got = p.sh->rb->retrieve(op, std::min(a, (int)rbOut[0].size()));
            const float *src[MAXCH] = {rbOut[0].data(), nch > 1 ? rbOut[1].data() : nullptr};
            store(p, src, (int)got);
        }
    }

    // append to a path's output stream (through its output high-pass, if it has one)
    void store(Path &p, const float *const *src, int n) {
        for (int c = 0; c < nch; c++)
            for (int i = 0; i < n; i++) {
                float v = src[c][i];
                if (p.spec.outHP > 0) for (int k = 0; k < 4; k++) v = p.outF[k][c].run(v);
                p.ring[c][p.produced + i] = v;
            }
        p.produced += n;
    }

    // One chain's output for input samples tau0..tau0+m-1 into sum (and its level before the EQ into pre).
    void chainOut(Chain &ch, int64_t tau0, int m) {
        if (ch.dry()) {
            for (int c = 0; c < nch; c++) for (int i = 0; i < m; i++) sum[c][i] = pre[c][i] = hist[c][tau0 + i];
            return;
        }
        for (int c = 0; c < nch; c++) std::fill(sum[c].begin(), sum[c].begin() + m, 0.0f);
        for (int k = 0; k < ch.spec.n; k++) {
            Path &p = ch.path[k];
            float w = p.spec.outW;
            int64_t j0 = tau0 - ch.h0 + p.lag;
            if (j0 + m > p.produced) underruns++;
            for (int c = 0; c < nch; c++) {
                float *s = sum[c].data();
                for (int i = 0; i < m; i++) {
                    int64_t j = j0 + i;
                    if (j >= 0 && j < p.produced) s[i] += w * p.ring[c][j];
                }
            }
        }
        if (ch.spec.air > 0)  // pitch-down: above the air cut-off, the unshifted input
            for (int c = 0; c < nch; c++)
                for (int i = 0; i < m; i++) sum[c][i] = ch.airLP[c].run(sum[c][i]) + ch.airHP[c].run(hist[c][tau0 + i]);
        for (int c = 0; c < nch; c++) std::copy(sum[c].begin(), sum[c].begin() + m, pre[c].begin());
        // EQ, with its gains moving a small step every 32 samples
        int i = 0;
        while (i < m) {
            if (ch.eqCount == 0 && ch.eqSteps > 0) {
                for (int b = 0; b < NEQ; b++) ch.eqApplied[b] += ch.eqInc[b];
                ch.eqSteps--;
                setEqFilters(ch);
            }
            int n = std::min(m - i, 32 - ch.eqCount);
            for (int c = 0; c < nch; c++) {
                float *s = sum[c].data() + i;
                for (int b = 0; b < NEQ; b++) { Biquad &f = ch.eq[c][b]; for (int k = 0; k < n; k++) s[k] = f.run(s[k]); }
            }
            ch.eqCount = (ch.eqCount + n) & 31;
            i += n;
        }
    }

    // ---------------------------------------------------------------- EQ analysis, one slice per SB samples

    Chain *eqTarget() { Chain *c = next >= 0 ? &chains[next] : &chains[active]; return c->dry() ? nullptr : c; }

    void eqSlice(int stage) {
        TonalEQ &E = eq;
        if (stage == 0) {
            E.blocks++;
            E.a = std::min(exp(-(double)E.period / (E.tau * sr)), 1.0 - 1.0 / E.blocks);  // running mean at first
            E.bandPowers(nch > 1 ? refRing : hist[0], t, E.pr);
            for (int k = 1; k < E.N / 2; k++) E.rbin[k] = E.a * E.rbin[k] + (1 - E.a) * ((double)E.re[k] * E.re[k] + (double)E.im[k] * E.im[k]);
            for (size_t j = 0; j < E.fcs.size(); j++) E.pref[j] = E.a * E.pref[j] + (1 - E.a) * E.pr[j];
            return;
        }
        if (E.blocks == 0) return;
        if (stage == 1 || stage == 2) {
            Chain *c = eqTarget();
            if (stage == 1) { std::fill(E.pq.begin(), E.pq.end(), 0.0); E.gen = targetGen; }
            if (c && E.gen == targetGen) E.predict(c->spec, stage == 1 ? 1 : E.N / 4, stage == 1 ? E.N / 4 : E.N / 2);
            return;
        }
        if (stage == 3) {
            E.bandPowers(cur, t, E.pc);
            for (size_t j = 0; j < E.fcs.size(); j++) E.pcur[j] = E.a * E.pcur[j] + (1 - E.a) * E.pc[j];
            return;
        }
        if (stage != 4) return;
        Chain *c = eqTarget();
        if (!c || E.gen != targetGen) return;  // the target changed during this analysis: next time
        bool steady = next < 0;                 // the measured output belongs to this chain: update the slow correction
        if (steady) {
            E.blocks2++;
            double a2 = std::min(exp(-(double)E.period / (3 * E.tau * sr)), 1.0 - 1.0 / E.blocks2);
            for (size_t j = 0; j < E.fcs.size(); j++) { E.pqs[j] = a2 * E.pqs[j] + (1 - a2) * E.pq[j]; E.pcs[j] = a2 * E.pcs[j] + (1 - a2) * E.pcur[j]; }
        }
        double mx = *std::max_element(E.pref.begin(), E.pref.end());
        double ramp = std::min(1.0, (double)E.blocks2 * E.period / sr / (2 * E.tau));
        size_t nb = E.fcs.size();
        for (size_t j = 0; j < nb; j++) {
            double d = 10 * log10((E.pref[j] + 1e-20) / (E.pq[j] + 1e-20));
            if (E.blocks2 > 0) d += ramp * std::max(-3.0, std::min(3.0, 10 * log10((E.pqs[j] + 1e-20) / (E.pcs[j] + 1e-20))));
            if (E.pref[j] < mx * 1e-6 && E.pq[j] < mx * 1e-6) d = 0;
            if (E.pref[j] < mx * 1e-6 && E.pcur[j] < mx * 1e-6) d = 0;  // both quiet: leave alone
            bool lo = E.loF > 0 && E.fcs[j] < E.loF;  // balanced3: deeper cuts allowed below 100 Hz
            E.T[j] = E.alpha * std::max(lo ? -E.loCut : -E.cut, std::min(E.boost, d));
            if (E.fcs[j] < 70) E.T[j] = std::min(E.T[j], E.lowcap);
        }
        for (int j = 0; j < (int)nb; j++) {  // broad target only: average over +-1 band (not below loF)
            double s = 0; int n = 0;
            for (int q = std::max(0, j - E.smooth); q <= std::min((int)nb - 1, j + E.smooth); q++) { s += E.T[q]; n++; }
            E.S[j] = (E.loF > 0 && E.fcs[j] < E.loF) ? E.T[j] : s / n;
        }
        // least squares, then two correction passes on the true filter response
        for (int k = 0; k < NEQ; k++) { E.g[k] = 0; for (size_t j = 0; j < nb; j++) E.g[k] += E.M[k][j] * E.S[j]; }
        for (int it = 0; it < 2; it++) {
            Biquad tb[NEQ];
            for (int k = 0; k < NEQ; k++) E.setFilter(tb[k], k, E.g[k]);
            for (size_t j = 0; j < nb; j++) { double r = 0; for (int k = 0; k < NEQ; k++) r += tb[k].magDb(E.fcs[j], sr); E.e[j] = E.S[j] - r; }
            for (int k = 0; k < NEQ; k++) for (size_t j = 0; j < nb; j++) E.g[k] += E.M[k][j] * E.e[j];
        }
        int steps = E.period / 32;
        for (int k = 0; k < NEQ; k++) {
            double cutk = (E.loF > 0 && E.eqf[k] < E.loF) ? E.loCut : E.cut;  // the 44 Hz shelf and 62 Hz filter: deeper cut
            double gk = std::max(-cutk - 3, std::min((k <= 1 ? std::min(E.boost, E.lowcap) : E.boost) + 3, E.g[k]));
            if (k >= 3 && k <= 7) gk = std::max(-E.midcap, std::min(E.midcap, gk));
            if (c->eqFresh) { c->eqApplied[k] = gk; c->eqInc[k] = 0; }
            else c->eqInc[k] = (gk - c->eqApplied[k]) / steps;
        }
        if (c->eqFresh) { c->eqFresh = false; c->eqSteps = 0; setEqFilters(*c); }
        else c->eqSteps = steps;
    }

    Ring refRing;  // stereo only: mono mix of the history, the EQ's reference

    // ---------------------------------------------------------------- process

    void process(const float *const *in, const float *const *keep, float *const *out, int frames) {
        int done = 0;
        while (done < frames) {
            int m = (int)std::min<int64_t>(frames - done, SB - (t % SB));
            // keep: taken out of the input here, added back (same delay) in render(). When keep starts (it was NULL or
            // all zeros for a while) it is faded in over 30 ms, so the drums don't jump from the shifted path to the
            // unshifted one in one sample (that would click).
            for (int i = 0; i < m; i++) {
                bool any = false;
                if (keep) for (int c = 0; c < nch; c++) if (keep[c][done + i] != 0.0f) any = true;
                keepIdle = any ? 0 : std::min<int64_t>(keepIdle + 1, keepIdleLimit);
                keepG = keepIdle >= keepIdleLimit ? 0.0f : std::min(1.0f, keepG + keepStep);
                for (int c = 0; c < nch; c++) {
                    float k = keep ? keepG * keep[c][done + i] : 0.0f;
                    hist[c][t + i] = in[c][done + i] - k;
                    keepR[c][t + i] = k;
                }
            }
            if (nch > 1) for (int i = 0; i < m; i++) refRing[t + i] = 0.5f * (hist[0][t + i] + hist[1][t + i]);
            manage();
            // feed: chains that are caught up get this slice; one that is catching up gets up to `catchup` x more
            for (int s = 0; s < 2; s++) {
                Chain &ch = chains[s];
                if (ch.state == C_FREE) continue;
                if (ch.state == C_WARMING) feed(ch, std::min<int64_t>(t + m, ch.p + (int64_t)catchup * m));
                else feed(ch, t + m);
            }
            render(out, done, m);
            t += m; done += m;
            if (next >= 0 && (chains[next].state == C_PREROLL || chains[next].state == C_FADE_IN)) chains[next].phase += m;
            if (t % SB == 0) eqSlice((int)((t / SB) % 8));
        }
    }

    void render(float *const *out, int off, int m) {
        int64_t tau0 = t - L;
        for (int c = 0; c < nch; c++) std::fill(acc[c].begin(), acc[c].begin() + m, 0.0f);
        std::fill(curMono.begin(), curMono.begin() + m, 0.0f);
        Chain &A = chains[active];
        Chain *B = next >= 0 && (chains[next].state == C_PREROLL || chains[next].state == C_FADE_IN) ? &chains[next] : nullptr;
        bool fading = B && B->state == C_FADE_IN;
        for (int which = 0; which < (B ? 2 : 1); which++) {
            Chain &ch = which == 0 ? A : *B;
            chainOut(ch, tau0, m);
            for (int i = 0; i < m; i++) {
                float g = 1.0f;
                if (fading) {
                    double x = std::min(1.0, (double)(B->phase + i) / fadeLen);
                    double gi = equalPower ? sin(0.5 * M_PI * x) : x, go = equalPower ? cos(0.5 * M_PI * x) : 1 - x;
                    g = (float)(which == 0 ? go : gi);
                } else if (which == 1) g = 0.0f;  // pre-roll: warms its filters, not heard yet
                gain[i] = g;
            }
            for (int c = 0; c < nch; c++)
                for (int i = 0; i < m; i++) { acc[c][i] += gain[i] * sum[c][i]; curMono[i] += gain[i] * pre[c][i] / nch; }
        }
        for (int c = 0; c < nch; c++)
            for (int i = 0; i < m; i++) acc[c][i] += keepR[c][tau0 + i];
        for (int i = 0; i < m; i++) {  // safety limiter, both channels together
            float v[MAXCH];
            for (int c = 0; c < nch; c++) v[c] = acc[c][i];
            lim.run(v);
            for (int c = 0; c < nch; c++) out[c][off + i] = v[c];
        }
        for (int i = 0; i < m; i++) cur[t + i] = curMono[i];
    }

    void reset() {
        for (auto &ch : chains) if (ch.state != C_FREE) retire(ch);
        next = -1; active = 0;
        chains[0].spec = Spec(); chains[0].state = C_ACTIVE;
        for (int c = 0; c < nch; c++) { hist[c].clear(); keepR[c].clear(); }
        if (nch > 1) refRing.clear();
        cur.clear();
        eq.reset();
        keepG = 0; keepIdle = keepIdleLimit;
        lim.reset();
        tStart = t;
        pending = wantN != 0;
        targetGen++;
    }

    int shiftersInUse() const {
        int n = 0;
        for (auto &s : pool) if (s->state.load(std::memory_order_relaxed) == SH_IN_USE) n++;
        return n;
    }
};

}  // namespace

struct AdvancedChain { Engine *e; };

extern "C" {

AdvancedChain *advanced_new(double sampleRate, int channels, int maxFrames, int flags) {
    if (sampleRate < 8000 || sampleRate > 384000 || channels < 1 || channels > MAXCH || maxFrames < 1 || maxFrames > 65536) return nullptr;
    auto *e = new Engine(sampleRate, channels, maxFrames, flags);
    if (!e->setup()) { delete e; return nullptr; }
    return new AdvancedChain{e};
}

void advanced_delete(AdvancedChain *chain) {
    if (!chain) return;
    delete chain->e;
    delete chain;
}

void advanced_set_semis(AdvancedChain *chain, double semis) {
    Engine *e = chain->e;
    if (!(semis == semis)) return;  // NaN
    semis = std::max(-e->range, std::min(e->range, semis));
    semis = round(semis * 100.0) / 100.0;  // the app's 0.01 steps
    if (semis == e->wantN) return;
    e->wantN = semis;
    e->pending = true;
}

void advanced_reset(AdvancedChain *chain) { chain->e->reset(); }

void advanced_process(AdvancedChain *chain, const float *const *in, const float *const *keep, float *const *out, int frames) {
    Engine *e = chain->e;
    // More than maxFrames is fine too: the engine works in slices of at most 512 samples anyway.
    if (frames > 0) e->process(in, keep, out, frames);
}

int advanced_latency_frames(const AdvancedChain *chain) { return chain->e->L + chain->e->lim.D; }  // shifters + limiter look-ahead

void advanced_limiter_stats(const AdvancedChain *chain, AdvancedLimiterStats *s) {
    const Limiter &l = chain->e->lim;
    s->maxReductionDb = l.minGain < 1.0 ? -20 * log10(l.minGain) : 0.0;
    s->samplesLimited = l.limited;
    s->samplesLimitedOver01dB = l.limited01;
    s->samples = l.total;
    s->roundingClamps = l.clamps;
}

void advanced_get_info(const AdvancedChain *chain, AdvancedInfo *info) {
    const Engine *e = chain->e;
    info->heardSemis = e->chains[e->active].spec.N;
    info->changing = (e->next >= 0 || e->pending) ? 1 : 0;
    info->underruns = e->underruns;
    info->switches = e->switches;
    info->shiftersRunning = e->shiftersInUse();
}

int advanced_tune(AdvancedChain *chain, const char *key, double v) {
    Engine *e = chain->e;
    std::string k(key);
    if (k == "recipe") { e->recipe = (int)v; if (v == 2) { e->eq.loF = 0; e->eq.loCut = 9; } else { e->eq.loF = 100; e->eq.loCut = 15; } }
    else if (k == "limiter") e->lim.enabled = v != 0;
    else if (k == "floor2") e->floor2 = (int)v;
    else if (k == "floorhz") e->floorHz = v;
    else if (k == "floorout") e->floorOut = v;
    else if (k == "fold2") e->fold2 = (int)v;
    else if (k == "airmin") e->airMin = v;
    else if (k == "catchup") e->catchup = std::max(1, (int)v);
    else if (k == "fadems") { e->fadeMs = v; e->fadeLen = (int64_t)lround(v * 0.001 * e->sr); }
    else if (k == "keepfadems") e->keepStep = v > 0 ? (float)(1.0 / (v * 0.001 * e->sr)) : 1.0f;
    else if (k == "foldstart") e->foldStart = v;
    else if (k == "foldfull") e->foldFull = v;
    else return 0;
    return 1;
}

}  // extern "C"
