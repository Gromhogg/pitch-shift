// Lets sounds that are not a voice through as they are (see SoundGate.h). 3.4.
//
// The mic is measured in 1 ms steps ("ticks": the energy above 100 Hz) and 10 ms frames (a voice-pitch check on the
// sound under ~1 kHz; a 32 ms spectrum at ~16 kHz). Each tick is sorted 20 ms after it came in, as
//   quiet  (its last 10 ms within `sgQuietDb` of the room's noise: the 5 % mark of the last 1.5 s of frames),
//   tap    (part of a short sound: a sharp start, `sgOnsetAboveDb` over the room's noise and `sgRiseDb` over the
//          20 ms before it within 3 ms, then dying away: `sgDecay40Db` down 30-40 ms after its loudest 3 ms (found
//          within 15 ms: a clap builds up), `sgDecay80Db` 70-80 ms after, `sgDecay120Db` 110-120 ms after, and on by
//          at least `sgKeepDecayDb` every 40 ms while well above the noise (a cough's rush of air holds on); not
//          rising again to within `sgReRiseNearDb` of its peak (a short bump is an echo; a sharp start is a new tap);
//          no voice's pitch in it; not the third of three sharp starts within `sgTrainMs` of each other (the pulses of
//          a burp or a creaky voice); it ends when its last 10 ms are 3 dB under quiet),
//   tone   (a whistle frame: one strong peak at 0.6-4.5 kHz holding most of the sound, nothing at a voice's pitch
//          under it), or
//   other  (anything else that is louder than quiet: speech, breath, a laugh, a cough, a sneeze, a hum, music ...).
// A tap is decided `sgIsoAfterMs` after its start (less if the stream's delay is short: never under `sgIsoMinMs`). It
// is let through only if that wait and the `sgIsoBeforeMs` before it hold nothing but quiet and taps (so a click
// while talking, a "t" or "k" before a vowel, a laugh's bursts, a cough stay the AI voice; a tap that is kept counts as
// "other" for the taps after it), and its spectrum is spread out like a click's (`sgFlatMin`: a voice's sounds gather
// at a few resonances). It is heard as the original from `sgPrerollMs` before its start (the AI voice starts its own
// version of a sound a little early) until it has died away, and never closer than `sgMarginMs` to anything after it.
// A whistle is let through once its tone has held for `sgWhRunFrames` frames with a smooth pitch and pure on average
// (the peak holds `sgWhShare` of the sound, its double `sgWhH2Db` lower: a scream has more overtones), with no
// voice's pitch in the `sgWhIsoMs` before it; it stays through while the tone holds. Any "other" tick ends what is
// let through `sgMarginMs` before it. The switch is a 10 ms crossfade (`sgRampMs`).
//
// Tuning keys (soundgate_tune; defaults in Tuning): sgTaps, sgWhistles (1 = on), sgRiseDb, sgRiseInTailDb,
// sgOnsetAboveDb, sgOnsetMinDb, sgQuietDb, sgDecay40Db, sgDecay80Db, sgDecay120Db, sgKeepDecayDb, sgKeepDecayAboveDb,
// sgReRiseDb, sgReRiseNearDb, sgMaxTapMs, sgIsoBeforeMs, sgIsoAfterMs, sgIsoMinMs, sgTrainMs, sgMaxFloorDb,
// sgLeadInMs, sgFlatMin, sgPrerollMs, sgMarginMs, sgRampMs, sgHoldMs, sgVoicedR, sgVoicedLowDb, sgVoicedF0Db,
// sgWhMinHz, sgWhMaxHz, sgWhShare, sgWhH2Db, sgWhFrameShare, sgWhFrameH2Db, sgWhLowDb, sgWhAboveDb, sgWhRunFrames,
// sgWhGlideOct, sgWhGapFrames, sgWhIsoMs, sgWarmMs.
// Measured on free recordings (research/voicechanger/results/passthrough.md): nothing of 150 speech clips let
// through; laughs, coughs, sneezes, sniffs, burps, gasps, sighs, screams: under 0.1 % of their sound.
#include "SoundGate.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <new>
#include <string>
#include <vector>

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr int kTickRing = 8192;     // 1 ms ticks kept (8 s)
constexpr int kFrameRing = 1024;    // 10 ms frames kept
constexpr int kFloorFrames = 150;   // the room's noise: the 5 % mark of the 10 ms frames of the last 1.5 s
constexpr int kTaps = 64;
constexpr int kLog = 256;
constexpr int kFft = 512;           // whistle spectrum: 512 samples at ~16 kHz (32 ms)
constexpr int kLag = 20;            // ticks are sorted this many ticks after they came in
constexpr int kSlack = 8;           // ticks kept spare in the look-ahead
constexpr int k16Ring = 4096;
constexpr int k8Ring = 2048;

enum : uint8_t { kQuiet = 0, kTap = 1, kOther = 2, kTone = 3 };

struct Biquad {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0;
    void lowpass(double rate, double hz, double q) { set(rate, hz, q, false); }
    void highpass(double rate, double hz, double q) { set(rate, hz, q, true); }
    void set(double rate, double hz, double q, bool high) {
        const double w = 2 * kPi * std::min(hz, rate * 0.45) / rate, c = std::cos(w), al = std::sin(w) / (2 * q);
        const double a0 = 1 + al;
        if (high) { b0 = (1 + c) / 2 / a0; b1 = -(1 + c) / a0; b2 = b0; }
        else { b0 = (1 - c) / 2 / a0; b1 = (1 - c) / a0; b2 = b0; }
        a1 = -2 * c / a0; a2 = (1 - al) / a0;
    }
    float run(float x) {
        const double y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return (float)y;
    }
};

struct Tuning {
    float taps = 1, whistles = 1;
    float riseDb = 15, riseInTailDb = 10, onsetAboveDb = 30, onsetMinDb = -60, quietDb = 10;
    float decay40Db = 10, decay80Db = 16, decay120Db = 22, keepDecayDb = 4, keepDecayAboveDb = 3, reRiseDb = 6, reRiseNearDb = 15, maxTapMs = 400;
    float isoBeforeMs = 300, isoAfterMs = 300, isoMinMs = 200, prerollMs = 40, marginMs = 15, rampMs = 10, holdMs = 10;
    float trainMs = 40, maxFloorDb = -45, leadInMs = 15, flatMin = 0.1f;
    float voicedR = 0.6f, voicedLowDb = -12, voicedF0Db = 12;
    float whMinHz = 600, whMaxHz = 4500, whShare = 0.9f, whH2Db = 30, whLowDb = 20, whAboveDb = 15, whRunFrames = 12;
    float whFrameShare = 0.7f, whFrameH2Db = 15;  // one frame of a run (looser: the run as a whole must meet the above)
    float whGlideOct = 0.12f, whGapFrames = 2, whIsoMs = 300;
    float warmMs = 500;
};

inline float toDb(double p) { return (float)(10 * std::log10(p + 1e-12)); }

}  // namespace

struct SoundGate {
    double rate = 48000;
    int S = 48;        // samples per tick
    int D = 3;         // to ~16 kHz
    double rate16 = 16000, rate8 = 8000;
    Tuning tu;
    int prerollTicks = 40;     // (fitted to the stream's look-ahead)
    int isoTicks = 300;        // the wait after a tap's start before it is decided (fitted too)
    bool usable = true;
    int fitted = -1;           // the look-ahead soundgate_fit was given (-1 = none)

    Biquad hp, aa1, aa2, lp1, lp2;
    double acc = 0;
    int accN = 0, decPhase = 0, dec8Phase = 0;
    int64_t ticks = 0;                       // ticks measured
    std::vector<float> e1;                   // tick energy, dB
    std::vector<double> p1;                  // ... and as power
    std::vector<uint8_t> cls, target;
    std::vector<float> x16, x8;
    int64_t n16 = 0, n8 = 0;
    int64_t frames = 0;                      // 10 ms frames measured
    std::vector<float> e10, floorScratch;
    std::vector<double> pitchSound, pitchSums;  // the pitch check's sound in order, and its sum per lag
    std::vector<uint8_t> voiced, tonal;
    std::vector<float> toneHz, toneShare, toneH2, flat;
    float floorDb = -120;
    int64_t warmFrames = 50;
    // spectrum
    std::vector<float> win, re, im, cosT, sinT;
    std::vector<int> rev;

    int64_t sorted = 0;                      // ticks sorted

    struct Tap {
        int64_t onset = 0, peak = 0, end = -1, next = INT64_MAX;
        float peakDb = 0, floorDb = 0, runMin = 0;
        bool failed = false, decided = false, passed = false, open = false, held = false;
        int log = -1;
    };
    Tap taps[kTaps];
    int64_t tapCount = 0;
    int cur = -1;                            // the tap being followed (-1 = none)

    struct Run {
        bool active = false, decided = false;
        int64_t start = 0, last = 0;         // frames
        float lastHz = 0;
        int len = 0, log = -1;
        double share = 0, h2 = 0;            // sums over its frames (purity: a whistle has almost no overtones)
    } run;
    bool toneOpen = false;                   // a passed whistle's ticks are let through as they are sorted
    int64_t lastOther = -1000000;            // last "other" tick
    int64_t lastVoiced = -1000000;           // last frame with a voice's pitch

    // output side
    int64_t played = -1;                     // last tick whose weight was read
    float g = 0;
    float step = 1.0f / 480;
    SoundGateStats stats{};
    SoundGateEvent events[kLog];
    int64_t eventCount = 0;

    int ms(float v) const { return std::max(0, (int)std::lround(v)); }

    void init() {
        S = std::max(1, (int)std::lround(rate / 1000));
        D = std::max(1, (int)std::lround(rate / 16000));
        rate16 = rate / D;
        rate8 = rate16 / 2;
        hp.highpass(rate, 100, 0.7071);
        if (D > 1) { aa1.lowpass(rate, 0.42 * rate16, 0.5412); aa2.lowpass(rate, 0.42 * rate16, 1.3066); }
        lp1.lowpass(rate16, 1000, 0.5412);
        lp2.lowpass(rate16, 1000, 1.3066);
        e1.assign(kTickRing, -120.0f);
        p1.assign(kTickRing, 1e-12);
        cls.assign(kTickRing, kQuiet);
        target.assign(kTickRing, 0);
        x16.assign(k16Ring, 0.0f);
        x8.assign(k8Ring, 0.0f);
        e10.assign(kFrameRing, -120.0f);
        floorScratch.assign(kFloorFrames, 0.0f);
        pitchSound.assign((size_t)(std::lround(0.04 * rate8) + std::ceil(rate8 / 60) + 1), 0.0);
        pitchSums.assign((size_t)(std::ceil(rate8 / 60) + 1), 0.0);
        voiced.assign(kFrameRing, 0);
        tonal.assign(kFrameRing, 0);
        toneHz.assign(kFrameRing, 0.0f);
        toneShare.assign(kFrameRing, 0.0f);
        toneH2.assign(kFrameRing, 0.0f);
        flat.assign(kFrameRing, -1.0f);
        win.resize(kFft); re.resize(kFft); im.resize(kFft); cosT.resize(kFft / 2); sinT.resize(kFft / 2); rev.resize(kFft);
        for (int i = 0; i < kFft; i++) win[i] = (float)(0.5 - 0.5 * std::cos(2 * kPi * i / kFft));
        for (int i = 0; i < kFft / 2; i++) { cosT[i] = (float)std::cos(2 * kPi * i / kFft); sinT[i] = (float)-std::sin(2 * kPi * i / kFft); }
        int bits = 0;
        while ((1 << bits) < kFft) bits++;
        for (int i = 0; i < kFft; i++) {
            int r = 0;
            for (int b = 0; b < bits; b++) if (i & (1 << b)) r |= 1 << (bits - 1 - b);
            rev[i] = r;
        }
        retune();
    }

    void retune() {
        step = 1.0f / std::max(1.0f, (float)(rate * tu.rampMs / 1000));
        warmFrames = std::max<int64_t>(10, ms(tu.warmMs) / 10);
    }

    // ticks of look-ahead the decisions need: sorting lag + the wait after a start + the lead-in
    // (kSlack: a callback's worth of samples is read after the newest push, and ticks round down)
    int needTicks(int preroll, int iso) const { return kLag + iso + preroll + kSlack; }

    // ------------------------------------------------------------------------------------------- measuring
    float E(int64_t k) const { return k < 0 ? -120.0f : e1[(size_t)(k & (kTickRing - 1))]; }
    // power mean of ticks [a, b] in dB
    float meanDb(int64_t a, int64_t b) const {
        double p = 0;
        int n = 0;
        for (int64_t k = a; k <= b; k++) { p += k < 0 ? 1e-12 : p1[(size_t)(k & (kTickRing - 1))]; n++; }
        return n ? toDb(p / n) : -120.0f;
    }

    void push(const float *x, int n) {
        for (int i = 0; i < n; i++) {
            const float v = x ? x[i] : 0.0f;
            const float h = hp.run(v);
            acc += (double)h * h;
            if (++accN == S) {
                e1[(size_t)(ticks & (kTickRing - 1))] = toDb(acc / S);
                p1[(size_t)(ticks & (kTickRing - 1))] = acc / S + 1e-12;
                target[(size_t)(ticks & (kTickRing - 1))] = 0;  // (the slot held a tick from 8 s ago)
                cls[(size_t)(ticks & (kTickRing - 1))] = kQuiet;
                acc = 0;
                accN = 0;
                ticks++;
                if (ticks % 10 == 0) frame();
                while (sorted + kLag < ticks && sorted + kLag <= frames * 10 - 1) sortTick(sorted++);
            }
            float a = h;  // (the pitch check and the whistle spectrum use the sound above 100 Hz too)
            if (D > 1) a = aa2.run(aa1.run(h));
            if (++decPhase >= D) {
                decPhase = 0;
                x16[(size_t)(n16 & (k16Ring - 1))] = a;
                n16++;
                const float l = lp2.run(lp1.run(a));
                if (++dec8Phase >= 2) {
                    dec8Phase = 0;
                    x8[(size_t)(n8 & (k8Ring - 1))] = l;
                    n8++;
                }
            }
        }
    }

    // A 10 ms frame ended (ticks [10 j, 10 j + 9]).
    void frame() {
        const int64_t j = frames;
        const size_t fj = (size_t)(j & (kFrameRing - 1));
        e10[fj] = meanDb(j * 10, j * 10 + 9);
        frames++;
        // the room's noise
        // (the 5 % mark, so a short dropout of the mic does not make everything after it seem loud)
        const int back = (int)std::min<int64_t>(frames, kFloorFrames);
        for (int q = 0; q < back; q++) floorScratch[(size_t)q] = e10[(size_t)((frames - back + q) & (kFrameRing - 1))];
        const int nth = back / 20;
        std::nth_element(floorScratch.begin(), floorScratch.begin() + nth, floorScratch.begin() + back);
        floorDb = floorScratch[(size_t)nth];
        // a voice's pitch (60-500 Hz) in the sound under ~1 kHz, last 40 ms
        voiced[fj] = 0;
        const int W = (int)std::lround(0.04 * rate8), lagLo = (int)std::floor(rate8 / 500), lagHi = (int)std::ceil(rate8 / 60);
        if (n8 > W + lagHi && e10[fj] > floorDb + 6) {
            auto at = [&](int64_t q) { return x8[(size_t)(q & (k8Ring - 1))]; };
            const int64_t end = n8;
            double e0 = 0;
            for (int64_t q = end - W; q < end; q++) e0 += (double)at(q) * at(q);
            double best = 0;
            if (e0 > 1e-12) {
                double el = 0;
                for (int64_t q = end - W - lagLo; q < end - lagLo; q++) el += (double)at(q) * at(q);
                // each lag's sum, eight lags side by side (each added up in the same order as one lag at a time)
                double *x = pitchSound.data();  // x[i] = at(end - W - lagHi + i)
                for (int i = 0; i < W + lagHi; i++) x[i] = at(end - W - lagHi + i);
                const double *w = x + lagHi;    // the last W samples
                for (int L = lagLo; L <= lagHi; L += 8) {
                    const double *y[8];
                    for (int u = 0; u < 8; u++) y[u] = w - std::min(L + u, lagHi);  // past lagHi: a spare copy, not used
                    double c0 = 0, c1 = 0, c2 = 0, c3 = 0, c4 = 0, c5 = 0, c6 = 0, c7 = 0;
                    for (int q = 0; q < W; q++) {
                        const double v = w[q];
                        c0 += v * y[0][q];
                        c1 += v * y[1][q];
                        c2 += v * y[2][q];
                        c3 += v * y[3][q];
                        c4 += v * y[4][q];
                        c5 += v * y[5][q];
                        c6 += v * y[6][q];
                        c7 += v * y[7][q];
                    }
                    const double c[8] = {c0, c1, c2, c3, c4, c5, c6, c7};
                    for (int u = 0; u < 8 && L + u <= lagHi; u++) pitchSums[(size_t)(L + u)] = c[u];
                }
                for (int L = lagLo; L <= lagHi; L++) {
                    if (L > lagLo) {  // slide the lagged window one sample back
                        const float in = at(end - W - L), out = at(end - L);
                        el += (double)in * in - (double)out * out;
                    }
                    const double c = pitchSums[(size_t)L];
                    const double r = c / std::sqrt(e0 * std::max(el, 1e-12));
                    best = std::max(best, r);
                }
            }
            // most of the sound is under ~1 kHz (a voice), not a high tone
            const float full = meanDb(j * 10 - 30, j * 10 + 9);
            const float low = toDb(e0 / W);
            if (best >= tu.voicedR && low - full >= tu.voicedLowDb) voiced[fj] = 1;
#ifdef SOUNDGATE_TRACE
            std::fprintf(stderr, "f %.3f r %.2f low-full %.1f\n", (double)j / 100, best, low - full);
#endif
        }
        // whistle: one strong peak, last 32 ms
        tonal[fj] = 0;
        toneHz[fj] = 0;
        flat[fj] = -1;
        if (n16 >= kFft && e10[fj] >= floorDb + std::min(tu.whAboveDb, tu.onsetAboveDb - 15)) {
            for (int i = 0; i < kFft; i++) { re[i] = x16[(size_t)((n16 - kFft + i) & (k16Ring - 1))] * win[i]; im[i] = 0; }
            fft();
            const double bin = rate16 / kFft;
            auto P = [&](int k) { return (double)re[k] * re[k] + (double)im[k] * im[k]; };
            auto sum = [&](int a, int b) { double s = 0; a = std::max(a, 1); b = std::min(b, kFft / 2); for (int k = a; k <= b; k++) s += P(k); return s; };
            {  // how even the spectrum is (a click is spread out; a voice's sounds gather at its resonances)
                const int a = (int)std::lround(300 / bin), b = (int)std::lround(std::min(7000.0, 0.45 * rate16) / bin);
                double lg = 0, ar = 0;
                for (int k = a; k <= b; k++) { const double v = P(k) + 1e-20; lg += std::log(v); ar += v; }
                flat[fj] = (float)(std::exp(lg / (b - a + 1)) / (ar / (b - a + 1)));
            }
            // a voice's pitch has its lowest notes at 70-500 Hz; a high tone that repeats (a whistle) has nothing there
            const double f0band = sum((int)std::lround(70 / bin), (int)std::lround(500 / bin));
            const double all = sum((int)std::lround(70 / bin), (int)std::lround(std::min(7000.0, 0.45 * rate16) / bin));
            if (voiced[fj] && toDb(f0band) < toDb(all) - tu.voicedF0Db) voiced[fj] = 0;
            if (tu.whistles == 0) return;
            const int kLo = (int)std::ceil(tu.whMinHz / bin), kHi = std::min(kFft / 2 - 3, (int)std::floor(tu.whMaxHz / bin));
            int kp = kLo;
            for (int k = kLo; k <= kHi; k++) if (P(k) > P(kp)) kp = k;
            const double total = sum((int)std::lround(300 / bin), (int)std::lround(std::min(7000.0, 0.45 * rate16) / bin));
            const double pk = sum(kp - 2, kp + 2);
            const double h2 = 2 * kp + 2 <= kFft / 2 ? sum(2 * kp - 2, 2 * kp + 2) : 0;
            const double low = sum((int)std::lround(70 / bin), (int)std::lround(500 / bin));
            const double half = sum(kp / 2 - 2, kp / 2 + 2);
            if (total > 0 && pk / total >= tu.whFrameShare && toDb(h2) <= toDb(pk) - tu.whFrameH2Db &&
                toDb(low) <= toDb(pk) - tu.whLowDb && toDb(half) <= toDb(pk) - tu.whLowDb) {
                toneShare[fj] = (float)(pk / total);
                toneH2[fj] = std::max(-60.0f, toDb(h2) - toDb(pk));
                tonal[fj] = 1;
                const double a = std::log(P(kp - 1) + 1e-30), b = std::log(P(kp) + 1e-30), c = std::log(P(kp + 1) + 1e-30);
                const double den = a - 2 * b + c;
                const double off = std::fabs(den) > 1e-12 ? std::clamp(0.5 * (a - c) / den, -0.5, 0.5) : 0.0;
                toneHz[fj] = (float)((kp + off) * bin);
                voiced[fj] = 0;  // (a pure high tone repeats at every lag the pitch check tries: it is not a voice's pitch)
            }
        }
    }

    void fft() {
        for (int i = 0; i < kFft; i++) if (rev[i] > i) { std::swap(re[i], re[rev[i]]); std::swap(im[i], im[rev[i]]); }
        for (int len = 2; len <= kFft; len <<= 1) {
            const int half = len >> 1, stride = kFft / len;
            for (int i = 0; i < kFft; i += len) {
                for (int k = 0; k < half; k++) {
                    const float wr = cosT[k * stride], wi = sinT[k * stride];
                    const int a = i + k, b = a + half;
                    const float tr = re[b] * wr - im[b] * wi, ti = re[b] * wi + im[b] * wr;
                    re[b] = re[a] - tr; im[b] = im[a] - ti;
                    re[a] += tr; im[a] += ti;
                }
            }
        }
    }

    // --------------------------------------------------------------------------------------------- sorting
    // A sharp start at c (inTail: in another tap's tail, where a smaller jump is enough).
    bool onsetAt(int64_t c, bool inTail = false) const {
        const float pk = std::max({E(c), E(c + 1), E(c + 2)});
        if (pk < tu.onsetMinDb || pk < floorDb + tu.onsetAboveDb || floorDb > tu.maxFloorDb) return false;
        return pk >= meanDb(c - 20, c - 1) + (inTail ? tu.riseInTailDb : tu.riseDb);
    }
    bool voicedAt(int64_t c) const {  // two voiced frames in a row around it (one alone can be a room's ring)
        const int64_t f = c / 10;
        const bool a = voiced[(size_t)((f - 1) & (kFrameRing - 1))] != 0, b = voiced[(size_t)(f & (kFrameRing - 1))] != 0;
        const bool n = f + 1 < frames && voiced[(size_t)((f + 1) & (kFrameRing - 1))] != 0;
        return b && (a || n);
    }
    bool tonalAt(int64_t c) const { return tonal[(size_t)((c / 10) & (kFrameRing - 1))] != 0; }
    void setCls(int64_t k, uint8_t v) { cls[(size_t)(k & (kTickRing - 1))] = v; }
    uint8_t clsAt(int64_t k) const { return k < 0 ? kQuiet : cls[(size_t)(k & (kTickRing - 1))]; }
    void setTarget(int64_t a, int64_t b, uint8_t v) {  // [a, b], never the ticks already heard
        a = std::max(a, played + 1);
#ifdef SOUNDGATE_TRACE
        if (v && b - a > 2) std::fprintf(stderr, "set %.3f-%.3f cur %d open %d tone %d\n", (double)a / 1000, (double)b / 1000, cur, cur >= 0 ? (int)tapAt(cur)->open : -1, (int)toneOpen);
#endif
        for (int64_t k = a; k <= b; k++) target[(size_t)(k & (kTickRing - 1))] = v;
    }

    int logEvent(int64_t startTick, int kind, int passed, int reason, float peakDb) {
        SoundGateEvent &e = events[eventCount % kLog];
        e.start = startTick * S;
        e.end = -1;
        e.kind = kind;
        e.passed = passed;
        e.reason = reason;
        e.peakDb = peakDb;
        e.floorDb = floorDb;
        return (int)(eventCount++ % kLog);
    }

    Tap *tapAt(int64_t i) { return &taps[i % kTaps]; }

    // How spread out a tap's spectrum is just after its peak (-1 = too soft to tell).
    float flatAround(const Tap &t) const {
        float fl = -1;
        for (int64_t f = (t.peak + 10) / 10; f <= (t.peak + 30) / 10; f++) fl = std::max(fl, flat[(size_t)(f & (kFrameRing - 1))]);
        return fl;
    }

    void endTap(Tap &t, int64_t c) {
        t.end = c;
        if (t.log >= 0 && events[t.log].end < 0) events[t.log].end = c * S;
        if (t.open) {  // let through to its end (+ hold), not closer than the margin to what follows
            setTarget(c, c + ms(tu.holdMs), 1);
            t.open = false;
        }
        cur = -1;
    }

    void failTap(Tap &t, int64_t c, int why) {
#ifdef SOUNDGATE_TRACE
        std::fprintf(stderr, "fail %.3f why %d peak %.1f floor %.1f\n", (double)c / 1000, why, t.peakDb, floorDb);
#else
        (void)why;
#endif
        t.failed = true;
        for (int64_t k = t.onset; k <= c; k++) setCls(k, kOther);
        t.end = c;
        cur = -1;
    }

    // An "other" tick (or a tone not let through) at c: nothing is let through from `margin` before it.
    void cut(int64_t c) {
        setTarget(c - ms(tu.marginMs), c + ms(tu.holdMs) + 1, 0);
        if (cur >= 0) tapAt(cur)->open = false;
    }

    void startTap(int64_t c) {
        if (cur >= 0) {  // the one before ends where this starts (and is not let through into it)
            Tap &p = *tapAt(cur);
            const bool wasOpen = p.open;
            p.open = false;
            endTap(p, c);
            p.next = c;
            if (wasOpen) setTarget(c - ms(tu.marginMs), c + ms(tu.holdMs) + 1, 0);
        }
        // three or more sharp starts close together (the pulses of a burp or a creaky voice) are not taps (two can be:
        // a key going down and up)
        bool train = false;
        if (tapCount > 1) {
            Tap &p = *tapAt(tapCount - 1), &q = *tapAt(tapCount - 2);
            if (c - p.onset < ms(tu.trainMs) && p.onset - q.onset < ms(tu.trainMs)) {
                train = true;
                if (!q.failed) failTap(q, p.onset - 1, 5);
                if (!p.failed) failTap(p, c - 1, 5);
            }
        }
        Tap &t = *tapAt(tapCount);
        t = Tap{};
        t.failed = train;
        t.onset = c;
        t.peak = c;  // the loudest 3 ms within 15 ms (a clap builds up over a few ms)
        float best = -200;
        for (int64_t k = c; k <= c + 15; k++) {
            const float m = meanDb(k - 1, k + 1);
            if (m > best) { best = m; t.peak = k; }
        }
        t.peakDb = best;
        t.floorDb = floorDb;
        t.runMin = t.peakDb;
        cur = (int)(tapCount % kTaps);
        tapCount++;
    }

    void sortTick(int64_t c) {
        uint8_t k = kQuiet;
        const float L10 = meanDb(c - 9, c);  // (not ahead: a sharp start would make the ticks before it loud)
        const bool quiet = L10 <= floorDb + tu.quietDb;
        bool done = false;
        if (tu.taps != 0 && cur >= 0) {
            Tap &t = *tapAt(cur);
            const int64_t since = c - t.peak;
            if (c > t.peak + 5 && onsetAt(c, true)) {
                startTap(c);
                k = kTap;
                done = true;
            } else if (voicedAt(c) && !quiet) {
                failTap(t, c, 1);
            } else if (since == 40 && meanDb(t.peak + 30, t.peak + 40) > t.peakDb - tu.decay40Db) {
                failTap(t, c, 2);
            } else if (since == 80 && meanDb(t.peak + 70, t.peak + 80) > std::min(t.peakDb - tu.decay80Db, meanDb(t.peak + 30, t.peak + 40) - tu.keepDecayDb)) {
                failTap(t, c, 3);
            } else if (since >= 120 && since % 40 == 0 && L10 > floorDb + tu.quietDb + tu.keepDecayAboveDb &&  // (near the noise it slows down)
                       meanDb(c - 10, c) > std::min(since == 120 ? t.peakDb - tu.decay120Db : 0.0f, meanDb(c - 50, c - 40) - tu.keepDecayDb)) {
                failTap(t, c, 3);  // (a sound that holds on, like a cough's rush of air, is not a tap: it must keep dying away)
            } else {
                if (since > 10) t.runMin = std::min(t.runMin, L10);
                // rising again (over 10 ms: a few ms' bump is an echo): only near its own loudness, and not just
                // before another sharp start (that starts a tap of its own)
                if (since > 20 && L10 > t.runMin + tu.reRiseDb && L10 > floorDb + tu.quietDb && L10 > t.peakDb - tu.reRiseNearDb &&
                    !onsetAt(c + 1, true) && !onsetAt(c + 2, true) && !onsetAt(c + 3, true)) {
                    if (since <= 120) failTap(t, c, 4);
                    else endTap(t, c);  // something else starts in its tail
                } else if ((since > 10 && L10 <= floorDb + tu.quietDb - 3) || since > ms(tu.maxTapMs)) {  // (3 dB under quiet: its
                    // tail may wander about the line for a while)
                    endTap(t, c);  // died away to the room's noise
                } else {
                    k = t.held ? kOther : kTap;
                    done = true;
                    if (t.open) setTarget(c, c, 1);
                }
            }
        }
        if (!done) {
            if (tu.taps != 0 && onsetAt(c)) {
                startTap(c);
                k = kTap;
            } else if (tonalAt(c) && !quiet) {
                k = kTone;
            } else if (!quiet) {
                k = kOther;
            }
        }
        setCls(c, k);
#ifdef SOUNDGATE_TRACE
        std::fprintf(stderr, "t %.3f E %.1f L10 %.1f fl %.1f cls %d v %d tn %d cur %d\n", (double)c / 1000, E(c), L10, floorDb, k,
                     voicedAt(c) ? 1 : 0, tonalAt(c) ? 1 : 0, cur);
#endif
        if (k == kOther) lastOther = c;
        if (k == kOther || (k == kTone && !toneOpen)) cut(c);
        if (c % 10 == 9) whistleFrame(c / 10);
        if (toneOpen && k == kTone) setTarget(c, c, 1);
        decideTaps(c);
    }

    // Anything but quiet and taps in ticks [a, b]?
    bool soundIn(int64_t a, int64_t b) const {
        for (int64_t q = a; q <= b; q++) if (clsAt(q) != kQuiet && clsAt(q) != kTap) return true;
        return false;
    }

    // Taps whose wait ends at c: let through, or not.
    void decideTaps(int64_t c) {
        const int iso = isoTicks;
        for (int64_t i = tapCount - 1; i >= 0 && i >= tapCount - kTaps; i--) {
            Tap &t = *tapAt(i);
            if (t.onset + iso < c) break;
            if (t.decided || t.onset + iso != c) continue;
            t.decided = true;
            int reason = 0;
            if (t.failed) reason = 3;
            else if (frames < warmFrames) reason = 6;
            else {
                // (its own lead-in, e.g. the fingers sliding before a snap, may come just before the sharp start)
                if (soundIn(t.onset - std::max(ms(tu.isoBeforeMs), iso), t.onset - ms(tu.leadInMs) - 1)) reason = 1;
                else if (soundIn(t.onset, c)) reason = 2;
            }
            if (!reason && flatAround(t) < tu.flatMin) reason = 7;  // spread out like a click's, not gathered at a voice's resonances
            const int64_t from = t.onset - prerollTicks;
            if (!reason && (!usable || from <= played)) reason = 5;
            t.log = logEvent(t.onset, 1, reason == 0, reason, t.peakDb);
#ifdef SOUNDGATE_TRACE
            std::fprintf(stderr, "tapf %.3f reason %d above %.1f rise %d d40 %.1f d80 %.1f d120 %.1f len %d flat %.3f\n",
                         (double)t.onset / 1000, reason, t.peakDb - t.floorDb, (int)(t.peak - t.onset),
                         meanDb(t.peak + 30, t.peak + 40) - t.peakDb, meanDb(t.peak + 70, t.peak + 80) - t.peakDb,
                         meanDb(t.peak + 110, t.peak + 120) - t.peakDb, t.end >= 0 ? (int)(t.end - t.onset) : -1, flatAround(t));
#endif
            if (t.end >= 0) events[t.log].end = t.end * S;
            if (reason) {  // its ticks now count as a sound for the taps after it (a chain of taps next to a voice stays)
                stats.tapsHeld++;
                t.held = true;
                for (int64_t q = t.onset; q <= (t.end >= 0 ? std::min(t.end, c) : c); q++) setCls(q, kOther);
                continue;
            }
            t.passed = true;
            stats.taps++;
            // let through from the lead-in to where it ended (or to now, then on while it lasts)
            int64_t upto = c;
            if (t.end >= 0) upto = std::min<int64_t>(t.end + ms(tu.holdMs), t.next == INT64_MAX ? t.end + ms(tu.holdMs) : t.next - ms(tu.marginMs) - 1);
            setTarget(from, upto, 1);
            if (t.end < 0 && !t.failed && cur >= 0 && tapAt(cur) == &t) t.open = true;
        }
    }

    // Whistles, once per frame (its ticks are sorted).
    void whistleFrame(int64_t f) {
        if (tu.whistles == 0) return;
        const size_t fi = (size_t)(f & (kFrameRing - 1));
        const bool tone = tonal[fi] && !voiced[fi];
        if (voiced[fi]) {  // a voice's pitch: no whistle through it, nor one starting soon after (a scream's high
            lastVoiced = f;  // part comes out of a lower voice)
            if (run.active) { closeRun(f); run.active = false; }
        }
#ifdef SOUNDGATE_TRACE
        if (tonal[fi]) std::fprintf(stderr, "wf %.2f hz %.0f share %.3f h2 %.1f v %d\n", (double)f / 100, toneHz[fi], toneShare[fi], toneH2[fi], voiced[fi]);
        if (voiced[fi]) std::fprintf(stderr, "vf %.2f e %.1f\n", (double)f / 100, e10[fi] - floorDb);
#endif
        if (tone) {
            const float hz = toneHz[fi];
            const int64_t gap = f - run.last;
            if (run.active && gap <= (int64_t)tu.whGapFrames + 1 && std::fabs(std::log2(hz / std::max(run.lastHz, 1.0f))) <= tu.whGlideOct * gap) {
                run.last = f;
                run.lastHz = hz;
                run.len++;
                run.share += toneShare[fi];
                run.h2 += toneH2[fi];
            } else {
                closeRun(f);
                run = Run{};
                run.active = true;
                run.start = run.last = f;
                run.lastHz = hz;
                run.len = 1;
                run.share = toneShare[fi];
                run.h2 = toneH2[fi];
            }
            if (!run.decided && run.len >= (int)tu.whRunFrames && run.share / run.len >= tu.whShare &&
                run.h2 / run.len <= -tu.whH2Db && lastVoiced < run.start - ms(tu.whIsoMs) / 10) {
                const int64_t startTick = run.start * 10;
                const int64_t from = std::max(startTick - prerollTicks, lastOther + ms(tu.marginMs) + 1);  // not into a sound before it
                run.decided = true;
                if (frames < warmFrames || !usable || from <= played) {
                    run.log = logEvent(startTick, 2, 0, frames < warmFrames ? 6 : 5, e10[fi]);
                } else {
                    toneOpen = true;
                    stats.whistles++;
                    run.log = logEvent(startTick, 2, 1, 0, e10[fi]);
#ifdef SOUNDGATE_TRACE
                    std::fprintf(stderr, "whistle %.3f share %.3f h2 %.1f hz %.0f\n", (double)startTick / 1000, run.share / run.len, run.h2 / run.len, run.lastHz);
#endif
                    setTarget(from, f * 10 + 9, 1);
                }
            }
        } else if (run.active && f - run.last > (int64_t)tu.whGapFrames) {
            closeRun(f);
            run.active = false;
        }
    }

    void closeRun(int64_t f) {
        if (run.active && toneOpen) {
            toneOpen = false;
            const int64_t endTick = run.last * 10 + 10;
            if (run.log >= 0) events[run.log].end = endTick * S;
            setTarget(endTick + ms(tu.holdMs), f * 10 + 9, 0);
        }
    }

    // ------------------------------------------------------------------------------------------------ output
    int weights(int64_t pos, int n, float *w) {
        int any = 0;
        for (int i = 0; i < n; i++) {
            const int64_t p = pos + i;
            float t = 0;
            if (p >= 0 && usable) {
                const int64_t k = p / S;
                // final only once its decision is in (the stream's delay gives the look-ahead)
                if (k + prerollTicks + isoTicks <= sorted && k > sorted - kTickRing / 2) t = target[(size_t)(k & (kTickRing - 1))];
                if (k > played) played = k;
            }
            if (t > g) g = std::min(t, g + step);
            else if (t < g) g = std::max(t, g - step);
            w[i] = g;
            if (g > 0) any = 1;
            if (g > 0.5f) stats.passedSeconds += 1.0 / rate;
        }
        return any;
    }
};

extern "C" {

SoundGate *soundgate_new(double rate) {
    if (!(rate >= 8000 && rate <= 384000)) return nullptr;
    auto *g = new (std::nothrow) SoundGate();
    if (!g) return nullptr;
    g->rate = rate;
    g->init();
    return g;
}

void soundgate_delete(SoundGate *gate) { delete gate; }

int soundgate_lookahead_frames(const SoundGate *gate) {
    return gate ? gate->needTicks(gate->ms(gate->tu.prerollMs), gate->ms(gate->tu.isoAfterMs)) * gate->S : 0;
}

int soundgate_fit(SoundGate *gate, int lookaheadFrames) {
    if (!gate) return 0;
    // the full wait and lead-in if they fit; else a shorter wait (not under sgIsoMinMs), then a shorter lead-in
    const int have = lookaheadFrames / gate->S;
    const Tuning &t = gate->tu;
    const int iso = gate->ms(t.isoAfterMs), isoMin = std::min(iso, gate->ms(t.isoMinMs));
    const int pre = gate->ms(t.prerollMs), preMin = std::min(pre, gate->ms(t.rampMs) + 2);
    gate->isoTicks = std::clamp(have - gate->needTicks(pre, 0), isoMin, iso);
    gate->prerollTicks = std::clamp(have - gate->needTicks(0, gate->isoTicks), 0, pre);
    gate->usable = gate->prerollTicks >= preMin;
    gate->fitted = lookaheadFrames;
    return gate->usable ? 1 : 0;
}

void soundgate_push(SoundGate *gate, const float *mic, int frames) {
    if (gate && frames > 0) gate->push(mic, frames);
}

int soundgate_weights(SoundGate *gate, int64_t pos, int n, float *weights) {
    if (!gate || !weights || n <= 0) return 0;
    return gate->weights(pos, n, weights);
}

void soundgate_get_stats(const SoundGate *gate, SoundGateStats *out) {
    if (!out) return;
    *out = gate ? gate->stats : SoundGateStats{};
}

int soundgate_events(const SoundGate *gate, SoundGateEvent *out, int max) {
    if (!gate || !out || max <= 0) return 0;
    const int64_t first = std::max<int64_t>(0, std::max(gate->eventCount - kLog, gate->eventCount - max));
    int n = 0;
    for (int64_t i = first; i < gate->eventCount; i++) out[n++] = gate->events[i % kLog];
    return n;
}

int soundgate_tune(SoundGate *gate, const char *key, float value) {
    if (!gate || !key || !std::isfinite(value)) return 0;
    const std::string k(key);
    Tuning &t = gate->tu;
    struct Key { const char *name; float *field; };
    const Key keys[] = {
        {"sgTaps", &t.taps}, {"sgWhistles", &t.whistles}, {"sgRiseDb", &t.riseDb}, {"sgRiseInTailDb", &t.riseInTailDb}, {"sgOnsetAboveDb", &t.onsetAboveDb},
        {"sgOnsetMinDb", &t.onsetMinDb}, {"sgQuietDb", &t.quietDb}, {"sgDecay40Db", &t.decay40Db}, {"sgDecay80Db", &t.decay80Db},
        {"sgDecay120Db", &t.decay120Db}, {"sgKeepDecayDb", &t.keepDecayDb}, {"sgKeepDecayAboveDb", &t.keepDecayAboveDb},
        {"sgReRiseDb", &t.reRiseDb}, {"sgReRiseNearDb", &t.reRiseNearDb}, {"sgMaxTapMs", &t.maxTapMs},
        {"sgIsoBeforeMs", &t.isoBeforeMs}, {"sgIsoAfterMs", &t.isoAfterMs}, {"sgIsoMinMs", &t.isoMinMs},
        {"sgTrainMs", &t.trainMs}, {"sgMaxFloorDb", &t.maxFloorDb}, {"sgLeadInMs", &t.leadInMs}, {"sgFlatMin", &t.flatMin}, {"sgPrerollMs", &t.prerollMs}, {"sgMarginMs", &t.marginMs},
        {"sgRampMs", &t.rampMs}, {"sgHoldMs", &t.holdMs}, {"sgVoicedR", &t.voicedR}, {"sgVoicedLowDb", &t.voicedLowDb}, {"sgVoicedF0Db", &t.voicedF0Db},
        {"sgWhMinHz", &t.whMinHz}, {"sgWhMaxHz", &t.whMaxHz}, {"sgWhShare", &t.whShare}, {"sgWhH2Db", &t.whH2Db},
        {"sgWhFrameShare", &t.whFrameShare}, {"sgWhFrameH2Db", &t.whFrameH2Db},
        {"sgWhLowDb", &t.whLowDb}, {"sgWhAboveDb", &t.whAboveDb}, {"sgWhRunFrames", &t.whRunFrames}, {"sgWhGlideOct", &t.whGlideOct},
        {"sgWhGapFrames", &t.whGapFrames}, {"sgWhIsoMs", &t.whIsoMs}, {"sgWarmMs", &t.warmMs},
    };
    for (const Key &e : keys) {
        if (k == e.name) {
            *e.field = value;
            t.isoAfterMs = std::clamp(t.isoAfterMs, 60.0f, 600.0f);
            t.isoMinMs = std::clamp(t.isoMinMs, 60.0f, 600.0f);
            t.isoBeforeMs = std::clamp(t.isoBeforeMs, 0.0f, 1000.0f);
            t.prerollMs = std::clamp(t.prerollMs, 0.0f, 200.0f);
            t.marginMs = std::clamp(t.marginMs, 0.0f, 100.0f);
            t.rampMs = std::clamp(t.rampMs, 1.0f, 50.0f);
            t.holdMs = std::clamp(t.holdMs, 0.0f, 200.0f);
            t.maxTapMs = std::clamp(t.maxTapMs, 60.0f, 2000.0f);
            t.whRunFrames = std::clamp(t.whRunFrames, 3.0f, 200.0f);
            t.whGapFrames = std::clamp(t.whGapFrames, 0.0f, 10.0f);
            gate->prerollTicks = gate->ms(t.prerollMs);
            gate->isoTicks = gate->ms(t.isoAfterMs);
            if (gate->fitted >= 0) soundgate_fit(gate, gate->fitted);
            gate->retune();
            return 1;
        }
    }
    return 0;
}

}  // extern "C"
