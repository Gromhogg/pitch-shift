// Pulse shifter (see PulseShifter.h): pitch-synchronous overlap-add for the voice changer's Natural mode.
//
// Steps, all on the sound thread with memory made up front:
//  1. Pitch tracker: the mic sound, low-passed (2 kHz) and thinned to about 12 kHz, is checked every 5 ms with a
//     YIN-style difference test over a 25 ms window (pitch 60 ... 700 Hz). A frame is voiced when the test finds a
//     clear repeat and it's loud enough (within 45 dB of the recent loudest, above -60 dBFS).
//  2. Pulse marks: in voiced parts one mark per vocal-fold pulse. The first mark of a voiced stretch sits on the
//     strongest pulse (the peak of the sound's slope energy); each next one is where the sound one period on
//     best matches the sound around the last mark (cross-correlation within +-20% of a period), so the marks keep
//     to the same point of every pulse. Unvoiced parts get marks every 4 ms.
//  3. Laying down: output marks follow the new pitch (one period / pitch scale apart). Each takes the piece around
//     the nearest input mark (a Hann window two input periods long, squeezed or stretched by the shape scale) and
//     adds it in at the output mark. Unvoiced pieces stay on their input marks (only reshaped), so noise is never
//     repeated. Voiced pieces are scaled by (pitch / shape)^-0.5 so the voice keeps its loudness.
#include "PulseShifter.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <new>

namespace {

struct Tuning {
    float latencyMs = 40;    // fixed delay (output k needs input up to k + this)
    float winMs = 25;        // pitch tracker window
    float hopMs = 5;         // pitch tracker step
    float minHz = 60;        // lowest pitch tracked
    float maxHz = 700;       // highest pitch tracked
    float pickAp = 0.15f;    // YIN: the first dip below this is the period
    float voicedAp = 0.35f;  // a frame starts a voiced stretch if its dip is below this ...
    float keepAp = 0.45f;    // ... and stays voiced while below this
    float floorDb = -60;     // quietest voiced sound, dBFS (low-passed)
    float rangeDb = 45;      // voiced only within this far below the recent loudest
    float search = 0.2f;     // the next pulse is looked for within +-this share of a period
    float minMatch = 0.3f;   // below this match the pulse train starts over on the strongest pulse
    float unvoicedMs = 4;    // mark spacing where there's no pitch
    float gainPow = 0.5f;    // voiced pieces are scaled by (pitch / shape)^-gainPow
    float creakRatio = 0.62f;  // a voiced frame below this share of the usual pitch is creak: the last good period holds
    float holdMs = 150;        // creak, or an unclear frame this soon after a good one, holds the last good period ...
    float holdAp = 0.5f;       // ... if its dip is below this ...
    float holdRangeDb = 20;    // ... and it's within this far of the recent loudest
    float usualSeconds = 2;    // how fast the usual pitch follows the voice
    float window = 1;          // voiced pieces are this share of two input periods long (shorter = smoother)
};

struct TuneKey {
    const char *name;
    float Tuning::*field;
};
const TuneKey kKeys[] = {
    {"pulseLatencyMs", &Tuning::latencyMs}, {"pulseWinMs", &Tuning::winMs}, {"pulseHopMs", &Tuning::hopMs},
    {"pulseMinHz", &Tuning::minHz}, {"pulseMaxHz", &Tuning::maxHz}, {"pulsePickAp", &Tuning::pickAp},
    {"pulseVoicedAp", &Tuning::voicedAp}, {"pulseKeepAp", &Tuning::keepAp}, {"pulseFloorDb", &Tuning::floorDb},
    {"pulseRangeDb", &Tuning::rangeDb}, {"pulseSearch", &Tuning::search}, {"pulseMinMatch", &Tuning::minMatch},
    {"pulseUnvoicedMs", &Tuning::unvoicedMs}, {"pulseGainPow", &Tuning::gainPow},
    {"pulseCreakRatio", &Tuning::creakRatio}, {"pulseHoldMs", &Tuning::holdMs}, {"pulseHoldAp", &Tuning::holdAp},
    {"pulseHoldRangeDb", &Tuning::holdRangeDb}, {"pulseUsualSeconds", &Tuning::usualSeconds},
    {"pulseWindow", &Tuning::window},
};

struct Biquad {
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0;
    void lowpass(double rate, double hz, double q) {
        const double w = 2 * M_PI * hz / rate, c = std::cos(w), alpha = std::sin(w) / (2 * q), a0 = 1 + alpha;
        b0 = (float)((1 - c) / 2 / a0);
        b1 = (float)((1 - c) / a0);
        b2 = b0;
        a1 = (float)(-2 * c / a0);
        a2 = (float)((1 - alpha) / a0);
    }
    float run(float x) {
        const float y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return y;
    }
    void clear() { z1 = z2 = 0; }
};

struct Frame {
    int64_t center;  // input sample
    float period;    // input samples (0 = unvoiced)
};

struct Mark {
    int64_t pos;
    float period;  // the voiced period here, or the unvoiced spacing
    bool voiced;
};

struct Setting {
    int64_t pos;
    double pitch, shape;
};

int powerOfTwoAtLeast(double n) {
    int p = 1;
    while (p < n) p <<= 1;
    return p;
}

}  // namespace

struct PulseShifter {
    double rate = 48000;
    Tuning t;

    // Derived from the tuning (setUp).
    int decim = 4;        // input samples per tracker sample
    double trackRate = 12000;
    int hop = 60;         // tracker samples per frame
    int halfWin = 150;    // tracker samples
    int tauMin = 17, tauMax = 200;
    int latency = 1920;   // input samples
    int unvoiced = 192;   // input samples
    int64_t firstCenter = 0;  // tracker sample of the first frame centre
    int delayFix = 0;     // the low-pass's delay, input samples

    // Mic sound.
    float *in = nullptr;
    int inMask = 0;
    int64_t inCount = 0;
    // Low-passed, thinned copy for the tracker.
    float *low = nullptr;
    int lowMask = 0;
    int64_t lowCount = 0;
    int phase = 0;
    Biquad lp1, lp2;
    // Tracker.
    float *span = nullptr;  // one frame's sound
    float *diff = nullptr;  // difference per lag, then its normalised form
    Frame *frames = nullptr;
    int frameMask = 0;
    int64_t frameCount = 0;
    float peakDb = -120;
    float lastTau = 0;
    double usualLog = 0;      // log of the usual period (tracker samples), 0 = not known yet
    float goodTau = 0;        // the last good (not creak) period, tracker samples
    int64_t goodFrame = -1000000;
    int holdFrames = 30;
    // Marks.
    Mark *marks = nullptr;
    int markMask = 0;
    int64_t markCount = 0;
    int64_t cursor = 0;  // the mark at or before the next output mark
    // Pitch and shape per stretch of input.
    Setting *settings = nullptr;
    int setMask = 0;
    int64_t setCount = 0;
    int64_t setCursor = 0;
    int setGrain = 32;
    double pitchNow = 1, shapeNow = 1;
    // Output.
    float *acc = nullptr;
    float *unvoicedWindow = nullptr;  // the window of an unvoiced piece, for whole-sample steps -unvoiced ... unvoiced
    int accMask = 0;
    int64_t outRead = 0;   // next sample to hand out
    int64_t outFinal = 0;  // samples before this are complete
    double nextOut = 0;    // next output mark
    double lastStart = 0;  // where the last piece laid down starts (pieces never start before the one before)
    // Counts since the last reset (pulseshifter_get_counts).
    int64_t pieces = 0, voicedPieces = 0, guessed = 0, waited = 0;

    bool make(double sampleRate) {
        rate = sampleRate;
        const double seconds = 1.2;  // room for the longest delay (0.3 s) and the tracker's window, with margin
        const int inSize = powerOfTwoAtLeast(rate * seconds);
        in = new (std::nothrow) float[inSize]();
        inMask = inSize - 1;
        const int lowSize = powerOfTwoAtLeast(rate * seconds / 1 + 16);
        low = new (std::nothrow) float[lowSize]();
        lowMask = lowSize - 1;
        span = new (std::nothrow) float[8192]();
        diff = new (std::nothrow) float[4096]();
        frames = new (std::nothrow) Frame[1024]();
        frameMask = 1023;
        marks = new (std::nothrow) Mark[4096]();
        markMask = 4095;
        settings = new (std::nothrow) Setting[2048]();
        setMask = 2047;
        acc = new (std::nothrow) float[inSize]();
        accMask = inSize - 1;
        unvoicedWindow = new (std::nothrow) float[2 * std::max(4, (int)std::lround(0.020 * rate)) + 1]();  // (see setUp)
        if (!in || !low || !span || !diff || !frames || !marks || !settings || !acc || !unvoicedWindow) return false;
        setUp();
        reset();
        return true;
    }

    ~PulseShifter() {
        delete[] in;
        delete[] low;
        delete[] span;
        delete[] diff;
        delete[] frames;
        delete[] marks;
        delete[] settings;
        delete[] acc;
        delete[] unvoicedWindow;
    }

    void setUp() {
        t.minHz = std::max(40.0f, std::min(t.minHz, 200.0f));
        t.maxHz = std::max(t.minHz * 2, std::min(t.maxHz, 1500.0f));
        t.winMs = std::max(5.0f, std::min(t.winMs, 60.0f));
        t.hopMs = std::max(1.0f, std::min(t.hopMs, 20.0f));
        t.unvoicedMs = std::max(1.0f, std::min(t.unvoicedMs, 20.0f));
        t.latencyMs = std::max(15.0f, std::min(t.latencyMs, 300.0f));
        decim = std::max(1, (int)std::lround(rate / 12000.0));
        trackRate = rate / decim;
        hop = std::max(1, (int)std::lround(t.hopMs / 1000 * trackRate));
        halfWin = std::max(8, (int)std::lround(t.winMs / 2000 * trackRate));
        tauMax = std::min((int)std::ceil(trackRate / t.minHz), 4000 - 2);
        tauMin = std::max(2, (int)std::floor(trackRate / t.maxHz));
        // the span a frame needs must fit in `span` (2 * halfWin + tauMax + 4 <= 8192)
        if (2 * halfWin + tauMax + 4 > 8192) halfWin = (8192 - tauMax - 4) / 2;
        firstCenter = halfWin + tauMax / 2 + 2;
        holdFrames = std::max(0, (int)std::lround(t.holdMs / t.hopMs));
        latency = (int)std::lround(t.latencyMs / 1000 * rate);
        unvoiced = std::max(4, (int)std::lround(t.unvoicedMs / 1000 * rate));
        const double toSide = M_PI / unvoiced;  // as layDown works it out
        for (int k = -unvoiced; k <= unvoiced; ++k) unvoicedWindow[k + unvoiced] = 0.5f + 0.5f * (float)std::cos(k * toSide);
        setGrain = std::max(32, (int)(rate / 1500));
        const double cutoff = std::min(2000.0, 0.35 * trackRate);
        lp1.lowpass(rate, cutoff, 0.5412);
        lp2.lowpass(rate, cutoff, 1.3066);
        delayFix = (int)std::lround(0.416 / cutoff * rate);  // 4th-order Butterworth delay at low frequencies
    }

    void reset() {
        std::memset(in, 0, sizeof(float) * (inMask + 1));
        std::memset(low, 0, sizeof(float) * (lowMask + 1));
        std::memset(acc, 0, sizeof(float) * (accMask + 1));
        inCount = lowCount = 0;
        phase = 0;
        lp1.clear();
        lp2.clear();
        frameCount = 0;
        peakDb = -120;
        lastTau = 0;
        usualLog = 0;
        goodTau = 0;
        goodFrame = -1000000;
        markCount = 0;
        cursor = 0;
        marks[0] = Mark{0, (float)unvoiced, false};
        markCount = 1;
        setCount = 0;
        setCursor = 0;
        settings[0] = Setting{0, pitchNow, shapeNow};
        setCount = 1;
        outRead = outFinal = 0;
        nextOut = 0;
        lastStart = -1e9;
        pieces = voicedPieces = guessed = waited = 0;
    }

    // ---- tracker ----

    // The frame whose centre is nearest `pos` (false if it isn't analysed yet).
    bool frameAt(int64_t pos, Frame &f) const {
        if (frameCount == 0) return false;
        const int64_t step = (int64_t)hop * decim;
        const int64_t c0 = firstCenter * decim + decim - 1 + delayFix;
        int64_t k = pos <= c0 ? 0 : (pos - c0 + step / 2) / step;
        if (k >= frameCount) return false;
        k = std::max(k, frameCount - frameMask);
        f = frames[k & frameMask];
        return true;
    }

    void analyseFrames() {
        const int need = 2 * halfWin + tauMax + 3;
        for (;;) {
            const int64_t c = firstCenter + frameCount * hop;  // tracker samples
            const int64_t lo = c - halfWin - tauMax / 2 - 1;
            if (lo + need >= lowCount) return;
            for (int j = 0; j < need; ++j) {
                const int64_t at = lo + j;
                span[j] = at >= 0 && at > lowCount - lowMask ? low[at & lowMask] : 0.0f;
            }
            // level of the window, dBFS
            const int mid = (int)(c - lo);
            double energy = 0;
            for (int j = mid - halfWin; j <= mid + halfWin; ++j) energy += (double)span[j] * span[j];
            const float levelDb = (float)(10 * std::log10(energy / (2 * halfWin + 1) + 1e-20));
            peakDb = std::max(levelDb, peakDb - 3.0f * t.hopMs / 1000);  // the loudest fades 3 dB a second
            // too quiet to be voiced or held (the tests below): no pitch needed (the same frame either way)
            if (!(levelDb > std::max(t.floorDb, peakDb - t.rangeDb)) && !(levelDb > std::max(t.floorDb, peakDb - t.holdRangeDb))) {
                lastTau = 0;
                frames[frameCount & frameMask] = Frame{c * decim + decim - 1 + delayFix, 0.0f};
                ++frameCount;
                continue;
            }
            // difference per lag (symmetric around the centre), then cumulative-mean normalised
            const int n = 2 * halfWin + 1;
            diff[0] = 1;
            double running = 0;
            for (int tau = 1; tau <= tauMax; ++tau) {
                const float *a = span + (mid - halfWin - tau / 2);
                const float *b = a + tau;
                float d = 0;
#pragma clang loop vectorize(enable)
                for (int j = 0; j < n; ++j) {
                    const float e = a[j] - b[j];
                    d += e * e;
                }
                running += d;
                diff[tau] = running > 0 ? (float)(d * tau / running) : 1.0f;
            }
            const bool wasVoiced = frameCount > 0 && frames[(frameCount - 1) & frameMask].period > 0;
            // the period: the first dip below pickAp (then down to its bottom), else the deepest dip
            int best = -1;
            for (int tau = tauMin; tau < tauMax; ++tau) {
                if (diff[tau] < t.pickAp) {
                    while (tau + 1 < tauMax && diff[tau + 1] < diff[tau]) ++tau;
                    best = tau;
                    break;
                }
            }
            if (best < 0) {
                best = tauMin;
                for (int tau = tauMin + 1; tau < tauMax; ++tau) if (diff[tau] < diff[best]) best = tau;
            }
            // keep to the last period if it's nearly as good (no octave jumps inside a voiced stretch)
            if (wasVoiced && lastTau > 0) {
                const int a = std::max(tauMin, (int)std::floor(lastTau * 0.85f));
                const int b = std::min(tauMax - 1, (int)std::ceil(lastTau * 1.15f));
                int near = -1;
                for (int tau = a; tau <= b; ++tau) if (near < 0 || diff[tau] < diff[near]) near = tau;
                if (near >= 0 && near != best && diff[near] <= diff[best] + 0.08f) best = near;
            }
            const float dip = diff[best];
            double tau = best;
            if (best > 1 && best < tauMax) {
                const double y0 = diff[best - 1], y1 = diff[best], y2 = diff[best + 1], den = y0 - 2 * y1 + y2;
                if (den > 0) tau += std::max(-0.5, std::min(0.5, 0.5 * (y0 - y2) / den));
            }
            const bool loud = levelDb > std::max(t.floorDb, peakDb - t.rangeDb);
            bool voiced = loud && dip < (wasVoiced ? t.keepAp : t.voicedAp);
            const bool recent = frameCount - goodFrame <= holdFrames && goodTau > 0;
            float use = (float)tau;
            if (voiced && usualLog != 0 && tau > std::exp(usualLog) / t.creakRatio) {  // creak: far below the usual pitch
                if (recent) use = goodTau;
            } else if (voiced) {  // a good frame: it sets the period to hold and moves the usual pitch
                goodTau = (float)tau;
                goodFrame = frameCount;
                const double k = usualLog == 0 ? 1.0 : std::min(1.0, (double)t.hopMs / 1000 / std::max(0.1, (double)t.usualSeconds));
                usualLog += (std::log(tau) - usualLog) * k;
            } else if (recent && dip < t.holdAp && levelDb > std::max(t.floorDb, peakDb - t.holdRangeDb)) {
                voiced = true;  // unclear but loud right after voicing (creak, a rough patch): hold the last good period
                use = goodTau;
            }
            lastTau = voiced ? use : 0;
            frames[frameCount & frameMask] = Frame{c * decim + decim - 1 + delayFix, voiced ? use * decim : 0.0f};
            ++frameCount;
        }
    }

    // ---- marks ----

    float inAt(int64_t i) const { return i >= 0 && i > inCount - inMask - 1 && i < inCount ? in[i & inMask] : 0.0f; }

    // Where the strongest pulse is in [from, to]: the peak of the slope energy, smoothed over 1 ms.
    int64_t strongestPulse(int64_t from, int64_t to) const {
        const int w = std::max(1, (int)(0.0005 * rate));
        double sum = 0;
        for (int64_t k = from - w; k <= from + w; ++k) {
            const float d = inAt(k) - inAt(k - 1);
            sum += (double)d * d;
        }
        double best = sum;
        int64_t at = from;
        for (int64_t k = from + 1; k <= to; ++k) {
            const float add = inAt(k + w) - inAt(k + w - 1), drop = inAt(k - w - 1) - inAt(k - w - 2);
            sum += (double)add * add - (double)drop * drop;
            if (sum > best) {
                best = sum;
                at = k;
            }
        }
        return at;
    }

    // How well the sound around each of the four spots `b` matches the sound around `a` (normalised
    // cross-correlation, -1 ... 1), over `half` samples on each side, every `stride`-th sample. The four sums run side
    // by side, each added up in the same order as one spot at a time (so the numbers are the same, only sooner), and
    // the sound around `a` is summed once.
    void match4(int64_t a, const int64_t *b, int half, int stride, double *out) const {
        double aa = 0;
        for (int j = -half; j < half; j += stride) {
            const float x = in[(a + j) & inMask];
            aa += (double)x * x;
        }
        double ab0 = 0, ab1 = 0, ab2 = 0, ab3 = 0, bb0 = 0, bb1 = 0, bb2 = 0, bb3 = 0;
        for (int j = -half; j < half; j += stride) {
            const float x = in[(a + j) & inMask];
            const float y0 = in[(b[0] + j) & inMask], y1 = in[(b[1] + j) & inMask];
            const float y2 = in[(b[2] + j) & inMask], y3 = in[(b[3] + j) & inMask];
            ab0 += (double)x * y0;
            bb0 += (double)y0 * y0;
            ab1 += (double)x * y1;
            bb1 += (double)y1 * y1;
            ab2 += (double)x * y2;
            bb2 += (double)y2 * y2;
            ab3 += (double)x * y3;
            bb3 += (double)y3 * y3;
        }
        const double ab[4] = {ab0, ab1, ab2, ab3}, bb[4] = {bb0, bb1, bb2, bb3};
        for (int q = 0; q < 4; ++q) out[q] = aa > 0 && bb[q] > 0 ? ab[q] / std::sqrt(aa * bb[q]) : 0.0;
    }

    // The spot among from, from + step, ... (up to `to`) whose sound best matches the sound around `a` (see match4),
    // looked at in that order: a better match than `best` takes over (`first`: the first spot takes over whatever
    // `best` was).
    void bestMatch(int64_t a, int64_t from, int64_t to, int step, int half, int stride, bool first, double &best,
                   int64_t &at) const {
        for (int64_t k = from; k <= to; k += 4 * step) {
            int64_t spots[4];
            for (int q = 0; q < 4; ++q) spots[q] = std::min(k + q * step, to);  // past `to`: a spare copy, not used
            double m[4];
            match4(a, spots, half, stride, m);
            for (int q = 0; q < 4 && k + q * step <= to; ++q) {
                if ((first && k == from && q == 0) || m[q] > best) {
                    best = m[q];
                    at = k + q * step;
                }
            }
        }
    }

    void placeMarks() {
        for (;;) {
            if (markCount - cursor > markMask - 8) return;  // full (the output side is far behind; shouldn't happen)
            const Mark last = marks[(markCount - 1) & markMask];
            const int64_t expect = last.pos + (int64_t)std::lround(last.voiced ? last.period : (float)unvoiced);
            Frame f;
            if (!frameAt(expect, f)) return;
            if (f.period <= 0) {
                marks[markCount & markMask] = Mark{expect, (float)unvoiced, false};
                ++markCount;
                continue;
            }
            const float period = f.period;
            const int half = std::max(2, (int)(period / 2));
            int64_t pos = -1;
            if (last.voiced) {  // follow the pulse train
                const int64_t lo = last.pos + (int64_t)std::floor((1 - t.search) * period);
                const int64_t hi = last.pos + (int64_t)std::ceil((1 + t.search) * period);
                if (hi + half + 2 >= inCount) return;  // wait for more sound
                double best = -2;
                int64_t at = lo;
                bestMatch(last.pos, lo, hi, 2, half, 2, false, best, at);  // coarse: every other lag and sample
                const int64_t c = at;
                bestMatch(last.pos, std::max(lo, c - 2), std::min(hi, c + 2), 1, half, 1, true, best, at);  // fine
                if (best >= t.minMatch && last.pos - half > inCount - inMask) pos = at;
            }
            if (pos < 0) {  // a voiced stretch starts (or the train was lost): the strongest pulse near the expected spot
                const int64_t lo = expect - half, hi = expect + half;
                const int w = (int)(0.0005 * rate) + 3;
                if (hi + w >= inCount) return;
                pos = strongestPulse(std::max(lo, last.pos + 1), hi);
            }
            marks[markCount & markMask] = Mark{pos, period, true};
            ++markCount;
        }
    }

    // ---- laying down ----

    void settingAt(int64_t pos, double &pitch, double &shape) {
        while (setCursor + 1 < setCount && settings[(setCursor + 1) & setMask].pos <= pos) ++setCursor;
        setCursor = std::max(setCursor, setCount - setMask);
        const Setting &s = settings[setCursor & setMask];
        pitch = s.pitch;
        shape = s.shape;
    }

    float interp(double pos) const {
        const double fl = std::floor(pos);
        const int64_t i = (int64_t)fl;
        const float f = (float)(pos - fl);
        const float xm1 = in[(i - 1) & inMask], x0 = in[i & inMask], x1 = in[(i + 1) & inMask], x2 = in[(i + 2) & inMask];
        return x0 + 0.5f * f * (x1 - xm1 + f * (2 * xm1 - 5 * x0 + 4 * x1 - x2 + f * (3 * (x0 - x1) + x2 - xm1)));
    }

    void layDown() {
        const int64_t until = inCount - latency;  // samples before this are due
        if (until <= outFinal) return;
        bool due = false;
        for (;;) {
            const double s = nextOut;
            // the input mark nearest the output mark (the last one if none is known past it yet)
            while (cursor + 1 < markCount && marks[(cursor + 1) & markMask].pos <= s) ++cursor;
            cursor = std::max(cursor, markCount - markMask);
            int64_t pick = cursor;
            if (cursor + 1 < markCount) {
                const Mark &a = marks[cursor & markMask], &b = marks[(cursor + 1) & markMask];
                if (std::fabs(b.pos - s) < std::fabs(s - a.pos)) pick = cursor + 1;
            }
            const Mark m = marks[pick & markMask];
            double pitch, shape;
            settingAt((int64_t)s, pitch, shape);
            double halfLen, step;
            float gain = 1;
            if (m.voiced) {
                halfLen = t.window * m.period / shape;
                step = m.period / pitch;
                gain = (float)std::exp(-t.gainPow * std::log(t.window * pitch / shape));
            } else {
                halfLen = unvoiced;
                step = unvoiced;
            }
            // the left half is cut short where the last piece started (a voiced stretch right after an unvoiced
            // one), so pieces never start before the one before and what's complete stays complete
            const double left = std::max(1.0, std::min(halfLen, s - lastStart));
            if (s - left >= until) {
                due = true;
                break;
            }
            if (m.pos + halfLen * shape + 3 >= inCount) {  // its sound isn't in yet (the delay is too short)
                ++waited;
                break;
            }
            ++pieces;
            if (m.voiced) ++voicedPieces;
            if (pick + 1 >= markCount && s - m.pos > 0.5 * m.period) ++guessed;  // no mark known past it yet
            // add the piece: a Hann window (left and right halves), the sound read squeezed by the shape scale
            const int64_t j0 = std::max(outFinal, (int64_t)std::ceil(s - left));
            const int64_t j1 = (int64_t)std::floor(s + halfLen);
            const double toLeft = M_PI / left, toRight = M_PI / halfLen;
            // an unvoiced piece at full width on a whole sample: its window is the same every time (from the table)
            const float *same = !m.voiced && left == halfLen && s == std::floor(s) ? unvoicedWindow + unvoiced : nullptr;
            for (int64_t j = j0; j <= j1; ++j) {
                const double u = j - s;
                const float w = same ? same[(int64_t)u] : 0.5f + 0.5f * (float)std::cos(u * (u < 0 ? toLeft : toRight));
                acc[j & accMask] += gain * w * interp(m.pos + u * shape);
            }
            lastStart = s - left;
            // next output mark: the new period on, or (unvoiced) on the next input mark
            if (!m.voiced && pick + 1 < markCount) {
                nextOut = std::max(s + 1, (double)marks[(pick + 1) & markMask].pos);
            } else {
                nextOut = s + std::max(1.0, step);
            }
        }
        const int64_t complete = due ? until : std::min(until, (int64_t)std::floor(lastStart));
        outFinal = std::max(outFinal, complete);
    }

    void process(const float *x, int frames) {
        for (int i = 0; i < frames; ++i) {
            const float v = x[i];
            in[inCount & inMask] = v;
            ++inCount;
            const float y = lp2.run(lp1.run(v));
            if (++phase >= decim) {
                phase = 0;
                low[lowCount & lowMask] = y;
                ++lowCount;
            }
        }
        analyseFrames();
        placeMarks();
        layDown();
    }

    void set(double pitch, double shape) {
        pitch = std::max(0.25, std::min(4.0, pitch > 0 ? pitch : 1.0));
        shape = std::max(0.5, std::min(2.0, shape > 0 ? shape : 1.0));
        if (pitch == pitchNow && shape == shapeNow) return;
        pitchNow = pitch;
        shapeNow = shape;
        Setting &last = settings[(setCount - 1) & setMask];
        // close to the last one (and not in use yet), or no room: change the last one
        if ((inCount - last.pos < setGrain && setCount - 1 > setCursor) || setCount - setCursor > setMask - 4) {
            last.pitch = pitch;
            last.shape = shape;
            return;
        }
        settings[setCount & setMask] = Setting{inCount, pitch, shape};
        ++setCount;
    }

    int retrieve(float *out, int frames) {
        const int n = (int)std::min<int64_t>(frames, outFinal - outRead);
        for (int i = 0; i < n; ++i) {
            float &v = acc[(outRead + i) & accMask];
            out[i] = v;
            v = 0;
        }
        outRead += std::max(0, n);
        return std::max(0, n);
    }
};

extern "C" {

PulseShifter *pulseshifter_new(double sampleRate) {
    if (!(sampleRate >= 8000 && sampleRate <= 192000)) return nullptr;
    PulseShifter *p = new (std::nothrow) PulseShifter();
    if (!p) return nullptr;
    if (!p->make(sampleRate)) {
        delete p;
        return nullptr;
    }
    return p;
}

void pulseshifter_delete(PulseShifter *p) { delete p; }

void pulseshifter_reset(PulseShifter *p) {
    if (p) p->reset();
}

void pulseshifter_set(PulseShifter *p, double pitchScale, double shapeScale) {
    if (p) p->set(pitchScale, shapeScale);
}

void pulseshifter_process(PulseShifter *p, const float *in, int frames) {
    if (p && in && frames > 0) p->process(in, frames);
}

int pulseshifter_available(const PulseShifter *p) { return p ? (int)(p->outFinal - p->outRead) : 0; }

int pulseshifter_retrieve(PulseShifter *p, float *out, int frames) {
    return p && out && frames > 0 ? p->retrieve(out, frames) : 0;
}

int pulseshifter_latency(const PulseShifter *p) { return p ? p->latency : 0; }

void pulseshifter_get_counts(const PulseShifter *p, PulseShifterCounts *out) {
    if (!p || !out) return;
    out->pieces = p->pieces;
    out->voicedPieces = p->voicedPieces;
    out->guessed = p->guessed;
    out->waited = p->waited;
}

int pulseshifter_tune(PulseShifter *p, const char *key, float value) {
    if (!p || !key) return 0;
    for (const auto &k : kKeys) {
        if (std::strcmp(k.name, key) == 0) {
            p->t.*(k.field) = value;
            p->setUp();
            p->reset();
            return 1;
        }
    }
    return 0;
}

}  // extern "C"
