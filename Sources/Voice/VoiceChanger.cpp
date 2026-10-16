// Voice changer, Natural mode (see VoiceChanger.h and notes/voice-changer-plan.md, "Natural mode").
//
// analyse (before Rubber Band), per mic sample:
//   - keeps the original in a delay line (for the sibilance keep in post),
//   - low-passes and thins it to about 16 kHz (/3 at 48 kHz, /6 at 96 kHz, none at 16 kHz),
//   - every 10 ms: YIN pitch tracker on the last ~43 ms (25 ms window, 55-600 Hz, threshold 0.12, parabolic
//     interpolation); voiced = aperiodicity < 0.25 and level > noise floor + 10 dB and > -50 dBFS,
//   - octave errors (YIN sometimes reads half or double the pitch for a frame or two, mostly where a sound starts or
//     ends): each voiced frame's pitch may be its YIN value, half or double it; a small running path search picks
//     the one that moves least from frame to frame (1 point per half-step), with a cost for taking half (4.5) or
//     double (3.5) and, once the speaker's median is known, for going more than 10 half-steps from it (0.5 per
//     half-step); a frame's choice is settled one frame later, when the next frame is in. A real fall to the bottom
//     of the voice is gradual, so it is kept (the old median-based fix doubled it: the "cracks" at the ends of
//     words); a lasting real octave drop (creak) is taken after ~4 frames. Then a median of 3 frames (so each
//     decision is one frame late),
//   - pitch mapping toward the voice's median pitch: off = 12 log2(target / speaker's median),
//     P = strength * (off + (intonation - 1) * deviation) + extra, limited to +-15 half-steps, smoothed 25 ms,
//     held through unvoiced and creaky frames (creak: < 70 Hz, < 0.62 x median, zig-zag jitter > 8 % over 3 frames,
//     or aperiodicity 0.25-0.45 just after voice); the speaker's median (4 s) starts from a light guess (0.1 s worth
//     of the median an earlier chain measured, voicechanger_set_speaker, or else of assumedInputHz) and learns from
//     voiced frames and from smooth low ones (>= 0.5 x median, not rough), so a deep voice finds its real median;
//     for the first 0.5 s of voice every smooth frame counts and only < 70 Hz is creak (the guess may be far off);
//     the median in use moves at most 0.3 half-steps per 10 ms, so learning it never makes the pitch jump,
//   - the pitch the AI voice follows (Realistic mode, frameHz): the tracked pitch x the mapping; through creak it
//     moves with a gradual fall or rise (not below 0.62 x median, mapped) and holds through a sudden drop or rough
//     frames; an aperiodic moment up to 80 ms after voice holds it (never starts it); then it is eased into 9 (at
//     most 12) half-steps above and 6 (at most 9) below the voice's own median, and moves at most 2 half-steps per
//     10 ms while it sings (gaps up to 30 ms count as singing),
//   - voice shape (formants): formant ^ (strength * |off| / |12 log2(target / assumedInputHz)|, limited to 1),
//     gliding over 150 ms; Rubber Band gets shape / pitch.
// post (after Rubber Band), per output sample, all plain filters (no added delay):
//   - sibilance (Man): between voiced sounds the top above 4.5 kHz crossfades toward the original's top,
//   - tone EQ: the output's long-term spectrum of voiced sound (21 third-octave bands, ~6 s) against the voice's
//     `ltas`, both normalised over 500 Hz - 2 kHz, smoothed over neighbouring bands, x eqAmount, limited +-6 dB, on
//     8 octave peaking filters 125 Hz - 16 kHz (Q 1.41), moved at most 0.05 dB per 256 samples,
//   - presence: a peak at 3 kHz (Q 0.9),
//   - breath: noise in 4 bands (1.5-2.5, 2.5-4, 4-6, 6-9 kHz), each following the output's own loudness in that
//     band (5 ms up, 30 ms down), only while voiced.
// Everything that depends on the strength is scaled by the strength in use, so at strength 0 the sound is untouched
// (apart from Rubber Band). The strength glides (0.15 s for the whole range).
//
// Inner tuning keys (voicechanger_tune), defaults in Tuning below: yinThreshold, voicedAp, voicedAboveFloorDb,
// voicedMinDb, creakHz, creakRatio, creakJitter, creakApLow, creakApHigh, smoothMs, formantGlideMs, strengthGlideS,
// maxSemitones, medianSeconds, seedFrames, eqMaxDb, eqStepDb, eqSeconds, eqStartSeconds, presenceHz, presenceQ,
// sibilanceHz, breathAttackMs, breathReleaseMs, octUpCost, octDownCost, jumpCost, rangeSt, rangeCost, contFrames,
// gapFrames, warmFrames, medianGlideSt, aiBandSt, aiMaxSt, aiBandLowSt, aiMinSt, aiHoldFrames, aiSlewSt.
#include "VoiceChanger.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <new>

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr int kBands = VOICECHANGER_LTAS_BANDS;  // tone measurement bands
constexpr int kBandsPadded = 24;                 // so the band loop runs in whole vector steps
constexpr int kEq = 8;                           // octave EQ filters, 125 Hz ... 16 kHz
constexpr int kBreath = 4;
constexpr int kPitchBins = 48 * 6;               // quarter half-steps from 40 Hz, 6 octaves
constexpr float kBinLowHz = 40;
constexpr int kLevelBins = 141;                  // 1 dB from -140 to 0 dBFS
constexpr int kFlagFrames = 128;                 // voiced/creak decisions kept for post (1.28 s)
constexpr int kEqBlock = 256;                    // tone EQ measuring/updating block

// One second-order filter (Robert Bristow-Johnson's audio EQ cookbook), transposed direct form II, in double.
struct Biquad {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    double z1 = 0, z2 = 0;
    inline double run(double x) {
        const double y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return y;
    }
    void clear() { z1 = z2 = 0; }
    void flush() {  // tiny numbers are slow on Intel Macs
        if (std::fabs(z1) < 1e-30) z1 = 0;
        if (std::fabs(z2) < 1e-30) z2 = 0;
    }
    void set(double c0, double c1, double c2, double d0, double d1, double d2) {
        b0 = c0 / d0; b1 = c1 / d0; b2 = c2 / d0; a1 = d1 / d0; a2 = d2 / d0;
    }
    void lowPass(double f, double q, double rate) {
        const double w = 2 * kPi * f / rate, c = std::cos(w), alpha = std::sin(w) / (2 * q);
        set((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + alpha, -2 * c, 1 - alpha);
    }
    void highPass(double f, double q, double rate) {
        const double w = 2 * kPi * f / rate, c = std::cos(w), alpha = std::sin(w) / (2 * q);
        set((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha);
    }
    void bandPass(double f, double q, double rate) {  // 0 dB at the centre
        const double w = 2 * kPi * f / rate, c = std::cos(w), alpha = std::sin(w) / (2 * q);
        set(alpha, 0, -alpha, 1 + alpha, -2 * c, 1 - alpha);
    }
    void peak(double f, double q, double db, double rate) {
        const double w = 2 * kPi * f / rate, c = std::cos(w), alpha = std::sin(w) / (2 * q);
        const double a = std::pow(10.0, db / 40);
        set(1 + alpha * a, -2 * c, 1 - alpha * a, 1 + alpha / a, -2 * c, 1 - alpha / a);
    }
};

struct Tuning {
    float yinThreshold = 0.12f;
    float voicedAp = 0.25f;
    float voicedAboveFloorDb = 10;
    float voicedMinDb = -50;
    float creakHz = 70;
    float creakRatio = 0.62f;
    float creakJitter = 0.08f;
    float creakApLow = 0.25f;
    float creakApHigh = 0.45f;
    float smoothMs = 25;
    float formantGlideMs = 150;
    float strengthGlideS = 0.15f;
    float maxSemitones = 15;
    float medianSeconds = 4;
    float seedFrames = 10;           // weight of the first guess of the speaker's median (10 ms frames)
    float eqMaxDb = 6;
    float eqStepDb = 0.05f;
    float eqSeconds = 6;
    float eqStartSeconds = 1;
    float presenceHz = 3000;
    float presenceQ = 0.9f;
    float sibilanceHz = 4500;
    float breathAttackMs = 5;
    float breathReleaseMs = 30;
    // octave errors (see the top of this file)
    float octUpCost = 3.5f;          // cost of taking double the YIN pitch (YIN read half)
    float octDownCost = 4.5f;        // cost of taking half the YIN pitch (YIN read double)
    float jumpCost = 1;              // cost per half-step moved from the frame before
    float rangeSt = 10;              // once the median is known: more than this from it ...
    float rangeCost = 0.5f;          // ... costs this per half-step
    float contFrames = 3;            // a gap up to this many frames keeps the full move cost (and the AI's speed limit)
    float gapFrames = 20;            // ... longer gaps weaken it, past this the next sound starts afresh
    float warmFrames = 50;           // learned frames before the median is trusted for creak decisions
    float medianGlideSt = 0.3f;      // the median in use moves at most this per frame
    // the pitch handed to the AI voice
    float aiBandSt = 9;              // up to this above the voice's median it is left alone ...
    float aiMaxSt = 12;              // ... beyond it eased so it never goes further than this
    float aiBandLowSt = 6;           // the same below the voice's median (a voice model sounds strained low)
    float aiMinSt = 9;
    float aiHoldFrames = 8;          // an aperiodic moment this soon after voice keeps the AI voice singing
    float aiSlewSt = 2;              // the most it moves per frame inside voiced sound
};

struct TuneKey {
    const char *name;
    float Tuning::*field;
};
const TuneKey kTuneKeys[] = {
    {"yinThreshold", &Tuning::yinThreshold}, {"voicedAp", &Tuning::voicedAp},
    {"voicedAboveFloorDb", &Tuning::voicedAboveFloorDb}, {"voicedMinDb", &Tuning::voicedMinDb},
    {"creakHz", &Tuning::creakHz}, {"creakRatio", &Tuning::creakRatio}, {"creakJitter", &Tuning::creakJitter},
    {"creakApLow", &Tuning::creakApLow}, {"creakApHigh", &Tuning::creakApHigh}, {"smoothMs", &Tuning::smoothMs},
    {"formantGlideMs", &Tuning::formantGlideMs}, {"strengthGlideS", &Tuning::strengthGlideS},
    {"maxSemitones", &Tuning::maxSemitones}, {"medianSeconds", &Tuning::medianSeconds},
    {"seedFrames", &Tuning::seedFrames}, {"eqMaxDb", &Tuning::eqMaxDb}, {"eqStepDb", &Tuning::eqStepDb},
    {"eqSeconds", &Tuning::eqSeconds}, {"eqStartSeconds", &Tuning::eqStartSeconds},
    {"presenceHz", &Tuning::presenceHz}, {"presenceQ", &Tuning::presenceQ}, {"sibilanceHz", &Tuning::sibilanceHz},
    {"breathAttackMs", &Tuning::breathAttackMs}, {"breathReleaseMs", &Tuning::breathReleaseMs},
    {"octUpCost", &Tuning::octUpCost}, {"octDownCost", &Tuning::octDownCost}, {"jumpCost", &Tuning::jumpCost},
    {"rangeSt", &Tuning::rangeSt}, {"rangeCost", &Tuning::rangeCost}, {"contFrames", &Tuning::contFrames},
    {"gapFrames", &Tuning::gapFrames}, {"warmFrames", &Tuning::warmFrames},
    {"medianGlideSt", &Tuning::medianGlideSt}, {"aiBandSt", &Tuning::aiBandSt}, {"aiMaxSt", &Tuning::aiMaxSt},
    {"aiBandLowSt", &Tuning::aiBandLowSt}, {"aiMinSt", &Tuning::aiMinSt}, {"aiHoldFrames", &Tuning::aiHoldFrames},
    {"aiSlewSt", &Tuning::aiSlewSt},
};

struct VoiceKey {
    const char *name;
    float VoiceChangerVoice::*field;
};
const VoiceKey kVoiceKeys[] = {
    {"targetHz", &VoiceChangerVoice::targetHz}, {"assumedInputHz", &VoiceChangerVoice::assumedInputHz},
    {"intonation", &VoiceChangerVoice::intonation}, {"formant", &VoiceChangerVoice::formant},
    {"breathDb", &VoiceChangerVoice::breathDb}, {"presenceDb", &VoiceChangerVoice::presenceDb},
    {"sibilanceKeep", &VoiceChangerVoice::sibilanceKeep}, {"eqAmount", &VoiceChangerVoice::eqAmount},
};
constexpr int kVoiceKeyCount = sizeof(kVoiceKeys) / sizeof(kVoiceKeys[0]);

inline float semitones(double ratio) { return (float)(12 * std::log2(ratio)); }

inline int pitchBin(double hz) {
    if (!(hz > 0)) return 0;
    const int b = (int)std::lround(48 * std::log2(hz / kBinLowHz));
    return std::clamp(b, 0, kPitchBins - 1);
}
inline double binHz(int b) { return kBinLowHz * std::pow(2.0, b / 48.0); }

// Median of a histogram (the bin where the running count passes half), with an extra weight on one bin.
inline int medianBin(const float *bins, int seedBin, float seedWeight) {
    float total = seedWeight;
    for (int b = 0; b < kPitchBins; ++b) total += bins[b];
    if (total <= 0) return seedBin;
    const float half = total / 2;
    float run = 0;
    for (int b = 0; b < kPitchBins; ++b) {
        run += bins[b] + (b == seedBin ? seedWeight : 0);
        if (run >= half) return b;
    }
    return kPitchBins - 1;
}

// xorshift32: the breath noise (the same every time after a reset, so offline renders repeat exactly).
inline float noise(uint32_t &state) {
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    return (float)((double)state / 2147483648.0 - 1.0);
}

double nowNs() {
    return (double)std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

}  // namespace

struct VoiceChanger {
    // Fixed at creation.
    double rate = 48000;
    int maxFrames = 0;
    int down = 3;            // thinning factor to ~16 kHz
    double analysisRate = 16000;
    int hop = 160;           // 10 ms at the analysis rate
    int hopIn = 480;         // ... at the chain rate
    int window = 400;        // YIN integration window (25 ms)
    int tauMin = 26, tauMax = 291;
    int span = 691;          // window + tauMax
    int decSize = 2048;      // analysis ring (power of two)
    int inSize = 32768;      // original delay line (power of two)
    bool bandOk[kBands] = {};    // band below 0.45 x rate
    bool eqOk[kEq] = {};
    bool breathOk[kBreath] = {};
    double eqHz[kEq] = {};

    // Buffers made in voicechanger_new.
    float *dec = nullptr;    // thinned mic, ring
    float *lin = nullptr;    // one analysis span, oldest first
    double *energy = nullptr;  // running sum of squares over `lin`
    float *diff = nullptr;   // YIN difference / normalised difference
    float *original = nullptr; // mic delay line

    // Settings.
    Tuning tuning;
    VoiceChangerVoice voice{};  // the voice in use (with tuned overrides)
    VoiceChangerVoice asSet{};  // as given to voicechanger_set
    bool hasVoice = false;
    bool overridden[kVoiceKeyCount] = {};
    float overrideValue[kVoiceKeyCount] = {};
    float strengthTarget = 0, strength = 0;

    // Analysis state.
    Biquad antiAlias[3];
    int decPhase = 0;
    int64_t decCount = 0;
    int64_t inPos = 0;          // mic samples given since the last reset
    int64_t hops = 0;
    float levelHist[kLevelBins] = {};
    uint8_t levelRing[512] = {};
    int levelCount = 0, levelAt = 0;
    // Octave errors: the last voiced frame's three choices (half, YIN, double), their path costs, and how many
    // frames ago it was.
    float octHz[3] = {};
    float octPath[3] = {};
    int octAge = 999;
    // The last three frames (for the median of 3): corrected pitch, aperiodicity, level, centre.
    float lastF0[3] = {}, lastAp[3] = {1, 1, 1}, lastLevel[3] = {-140, -140, -140};
    int64_t lastCentre[3] = {};
    // Mapping.
    float mapBins[kPitchBins] = {};
    int16_t mapRing[1024] = {};
    int mapCount = 0, mapAt = 0, mapCap = 400;
    int seedBin = 0;
    float seedWeight = 0;
    bool seeded = false;
    float speakerHz = 0;        // the speaker's median measured earlier (voicechanger_set_speaker), 0 = none
    float speakerWeight = 0;
    int64_t learned = 0;        // frames the median has learned from
    float medianUse = 0;        // the median in use (glides toward the measured one), 0 = not yet
    float prev[3] = {};
    int prevCount = 0;
    float shiftFrame = 0;       // mapped shift (half-steps, before strength), smoothed per frame
    float shiftNow = 0;         // ... gliding per callback toward shiftFrame
    bool shiftKnown = false;
    float shapePower = 1;       // the formant exponent before strength (|off| / full move, 0 ... 1)
    double shapeLogNow = 0;     // log of the voice shape in use (glides)
    float lastGoodHz = 0;
    float lastDev = 0;          // the last good frame's distance from the median (half-steps)
    int lastGoodAge = 999;
    float aiHz = 0;             // the last pitch handed to the AI voice, and how many frames ago
    int aiAge = 999;
    int voicedAge = 999;        // frames since the last voiced frame (after the median of 3)
    float medianHz = 120;
    // Decisions for post.
    uint8_t flagRing[kFlagFrames] = {};
    int64_t flagCentre[kFlagFrames] = {};
    int64_t flagLatest = -1;
    // Counts.
    int64_t frames = 0, voicedFrames = 0, creakFrames = 0;
    // Newest output.
    float pitchScale = 1, formantScale = 1, semitonesNow = 0;

    // Post state.
    Biquad sibTop, sibOrigTop;
    float sibKeep = 0, sibStep = 0;
    float voicedNow = 0, voicedStep = 0;
    // tone measurement bank (float, all bands side by side so the loop runs in vector steps)
    alignas(16) float bb0[kBandsPadded] = {}, bb2[kBandsPadded] = {}, ba1[kBandsPadded] = {}, ba2[kBandsPadded] = {};
    alignas(16) float bz1[kBandsPadded] = {}, bz2[kBandsPadded] = {}, bacc[kBandsPadded] = {};
    double measured[kBands] = {};     // long-term band power of voiced output
    int64_t measuredBlocks = 0;
    int blockAt = 0;
    float blockVoiced = 0;
    Biquad eq[kEq];
    float eqTarget[kEq] = {}, eqSlow[kEq] = {}, eqApplied[kEq] = {};
    Biquad presence;
    float presenceApplied = 0;
    Biquad breathBand[kBreath], breathNoise[kBreath];
    double breathNorm[kBreath] = {};
    float breathEnv[kBreath] = {};
    float breathAttack = 0, breathRelease = 0;
    uint32_t noiseState = 0x9E3779B9u;

    // Timing.
    double spentNs = 0, spentFrames = 0;
    double windowNs = 0, windowFrames = 0, worstMs = 0;

    void applyVoice() {
        voice = asSet;
        for (int k = 0; k < kVoiceKeyCount; ++k)
            if (overridden[k]) voice.*(kVoiceKeys[k].field) = overrideValue[k];
        if (!(voice.targetHz > 0)) voice.targetHz = 200;
        if (!(voice.assumedInputHz > 0)) voice.assumedInputHz = 120;
        if (!(voice.formant > 0)) voice.formant = 1;
        // The first guess of the speaker's median: measured earlier if known, else the voice's assumed input.
        seedBin = pitchBin(speakerHz > 0 ? speakerHz : voice.assumedInputHz);
        if (!seeded) {
            seedWeight = speakerHz > 0 ? speakerWeight : tuning.seedFrames;
            seeded = true;
        }
        mapCap = std::clamp((int)std::lround(tuning.medianSeconds * 100), 10, 1024);
    }

    bool warm() const { return learned >= (int64_t)tuning.warmFrames || speakerHz > 0; }

    // Once a frame: the median in use moves toward the measured one, at most medianGlideSt.
    void glideMedian(float measured) {
        if (!(medianUse > 0)) { medianUse = measured; return; }
        const float d = std::clamp(semitones(measured / medianUse), -tuning.medianGlideSt, tuning.medianGlideSt);
        medianUse = (float)(medianUse * std::exp2(d / 12));
    }

    // The pitch handed to the AI voice: eased into a band around the voice's own median (what this target pitch
    // would be for the speaker's median), and moving at most aiSlewSt per frame inside voiced sound.
    float aiPitch(float hz, float bandCentre) {
        if (!(hz > 0)) {
            if (aiAge < 1000) aiAge++;
            return 0;
        }
        if (bandCentre > 0) {
            const float up = std::max(0.0f, tuning.aiBandSt), upRoom = std::max(0.01f, tuning.aiMaxSt - up);
            const float down = std::max(0.0f, tuning.aiBandLowSt), downRoom = std::max(0.01f, tuning.aiMinSt - down);
            float s = semitones(hz / bandCentre);
            if (s > up) s = up + upRoom * std::tanh((s - up) / upRoom);
            else if (s < -down) s = -down - downRoom * std::tanh((-down - s) / downRoom);
            hz = (float)(bandCentre * std::exp2(s / 12));
        }
        if (aiHz > 0 && aiAge <= (int)tuning.contFrames && tuning.aiSlewSt > 0) {
            const float d = std::clamp(semitones(hz / aiHz), -tuning.aiSlewSt, tuning.aiSlewSt);
            hz = (float)(aiHz * std::exp2(d / 12));
        }
        aiHz = hz;
        aiAge = 0;
        return hz;
    }

    void pushMap(int bin) {
        while (mapCount >= mapCap) {  // oldest out
            const int oldest = (mapAt - mapCount + 1024) % 1024;
            mapBins[mapRing[oldest]] -= 1;
            mapCount--;
        }
        mapRing[mapAt] = (int16_t)bin;
        mapBins[bin] += 1;
        mapAt = (mapAt + 1) % 1024;
        mapCount++;
    }

    void learnMedian(float f0) {
        pushMap(pitchBin(f0));
        learned++;
        seedWeight = std::max(0.0f, seedWeight - 0.25f);  // the first guess fades as real frames come in
    }

    float noiseFloor() const {  // 10th percentile of the levels of the last ~5 s
        if (levelCount == 0) return -140;
        const float want = 0.1f * levelCount;
        float run = 0;
        for (int b = 0; b < kLevelBins; ++b) {
            run += levelHist[b];
            if (run >= want) return (float)(b - 140);
        }
        return 0;
    }

    void pushLevel(float db) {
        const int b = std::clamp((int)std::lround(db) + 140, 0, kLevelBins - 1);
        const int cap = (int)sizeof(levelRing);
        if (levelCount == cap) levelHist[levelRing[levelAt]] -= 1;
        else levelCount++;
        levelRing[levelAt] = (uint8_t)b;
        levelHist[b] += 1;
        levelAt = (levelAt + 1) % cap;
    }

    // YIN on `lin` (span samples). Returns pitch (Hz), aperiodicity and level (dBFS) of the middle.
    void yin(float &f0, float &ap, float &levelDb) {
        const int W = window, T = tauMax;
        energy[0] = 0;
        for (int i = 0; i < span; ++i) energy[i + 1] = energy[i] + (double)lin[i] * lin[i];
        const double e0 = energy[W];
        diff[0] = 0;
        double sum = 0;
        for (int tau = 1; tau <= T; ++tau) {
            const float *a = lin, *b = lin + tau;
            float r = 0;
            {
#pragma clang fp reassociate(on)
                for (int i = 0; i < W; ++i) r += a[i] * b[i];
            }
            const double d = std::max(0.0, e0 + (energy[tau + W] - energy[tau]) - 2.0 * r);
            sum += d;
            diff[tau] = (float)(sum > 1e-12 ? d * tau / sum : 1.0);
        }
        int tau = -1;
        for (int t = tauMin; t < T; ++t) {
            if (diff[t] < tuning.yinThreshold) {
                while (t + 1 < T && diff[t + 1] < diff[t]) ++t;
                tau = t;
                break;
            }
        }
        if (tau < 0) {
            tau = tauMin;
            for (int t = tauMin; t < T; ++t) if (diff[t] < diff[tau]) tau = t;
        }
        double frac = 0;
        if (tau >= 1 && tau < T) {
            const double y0 = diff[tau - 1], y1 = diff[tau], y2 = diff[tau + 1];
            const double den = y0 - 2 * y1 + y2;
            if (std::fabs(den) > 1e-12) frac = std::clamp(0.5 * (y0 - y2) / den, -1.0, 1.0);
        }
        f0 = (float)(analysisRate / (tau + frac));
        ap = diff[tau];
        const int mid = T / 2;
        levelDb = (float)(10 * std::log10((energy[mid + W] - energy[mid]) / W + 1e-12));
    }

    // Every 10 ms of thinned sound: track, fix octave jumps, then decide the frame before (median of 3) and map it.
    void analyseHop(float extra, VoiceChangerPitch *out) {
        for (int i = 0; i < span; ++i) lin[i] = dec[(decCount - span + i) & (decSize - 1)];
        float f0, ap, level;
        yin(f0, ap, level);
        pushLevel(level);
        const float floorDb = noiseFloor();
        const bool levelOk = level > floorDb + tuning.voicedAboveFloorDb && level > tuning.voicedMinDb;
        const bool voiced = ap < tuning.voicedAp && levelOk;
        float corrected = 0, settled = -1;  // settled: the frame before, now that this one is in (-1 = no change)
        if (voiced) {
            static constexpr float kMul[3] = {0.5f, 1, 2};
            const float stepCost[3] = {tuning.octDownCost, 0, tuning.octUpCost};
            const bool ranged = warm() && medianUse > 0;
            const bool linked = octAge <= (int)tuning.gapFrames;
            const float w = tuning.jumpCost * std::min(1.0f, std::max(1.0f, tuning.contFrames) / (float)std::max(1, octAge));
            float hz[3], path[3];
            int from[3] = {1, 1, 1};
            for (int k = 0; k < 3; ++k) {
                hz[k] = f0 * kMul[k];
                float cost = stepCost[k];
                if (!(hz[k] >= 50 && hz[k] <= 650)) cost += 1e6f;
                if (ranged) cost += tuning.rangeCost * std::max(0.0f, std::fabs(semitones(hz[k] / medianUse)) - tuning.rangeSt);
                if (linked) {
                    float best = 1e30f;
                    for (int j = 0; j < 3; ++j) {
                        const float c = octPath[j] + w * std::fabs(semitones(hz[k] / octHz[j]));
                        if (c < best) { best = c; from[k] = j; }
                    }
                    cost += best;
                }
                path[k] = cost;
            }
            int pick = 1;
            for (int k = 0; k < 3; ++k) if (path[k] < path[pick]) pick = k;
            const float low = path[pick];
            for (int k = 0; k < 3; ++k) { octPath[k] = std::min(path[k] - low, 1e6f); }
            if (linked && octAge == 1) settled = octHz[from[pick]];  // the frame before, seen from this one
            for (int k = 0; k < 3; ++k) octHz[k] = hz[k];
            octAge = 0;
            corrected = hz[pick];
        }
        if (octAge < 1000) octAge++;
        // shift the last three frames
        for (int k = 0; k < 2; ++k) {
            lastF0[k] = lastF0[k + 1]; lastAp[k] = lastAp[k + 1];
            lastLevel[k] = lastLevel[k + 1]; lastCentre[k] = lastCentre[k + 1];
        }
        if (settled > 0 && lastF0[1] > 0) lastF0[1] = settled;  // (lastF0[1] is now the frame before)
        lastF0[2] = corrected; lastAp[2] = ap; lastLevel[2] = level;
        lastCentre[2] = (decCount - span / 2) * down;
        hops++;
        if (hops < 2) return;
        // the frame before: median of 3 when all three are voiced
        float f = lastF0[1];
        if (hops >= 3 && f > 0 && lastF0[0] > 0 && lastF0[2] > 0) {
            const float a = lastF0[0], b = lastF0[1], c = lastF0[2];
            f = std::max(std::min(a, b), std::min(std::max(a, b), c));
        }
        const bool frameLevelOk = lastLevel[1] > floorDb + tuning.voicedAboveFloorDb && lastLevel[1] > tuning.voicedMinDb;
        mapFrame(f, lastAp[1], frameLevelOk, lastCentre[1], extra, out);
    }

    void mapFrame(float f0, float ap, bool levelOk, int64_t centre, float extra, VoiceChangerPitch *out) {
        const int mb = medianBin(mapBins, seedBin, seedWeight);
        const float measured = (float)binHz(mb);
        glideMedian(measured);
        const float median = medianUse;  // moves smoothly, so learning the median never makes the pitch jump
        medianHz = median;
        const bool voiced = f0 > 0;
        voicedAge = voiced ? 0 : std::min(voicedAge + 1, 1000);
        bool creak = false, rough = false;
        if (voiced) {
            if (prevCount < 3) prev[prevCount++] = f0;
            else { prev[0] = prev[1]; prev[1] = prev[2]; prev[2] = f0; }
            float jitter = 0;
            if (prevCount == 3) {  // zig-zag: the middle frame off the line through its neighbours (not a glide)
                const float mean = (prev[0] + prev[1] + prev[2]) / 3;
                jitter = std::fabs(prev[1] - 0.5f * (prev[0] + prev[2])) / mean;
            }
            rough = jitter > tuning.creakJitter;
            // Until the median is known (the first guess may be far off) only very low and rough frames are creak.
            const bool known = warm();
            creak = f0 < tuning.creakHz || (known && f0 < tuning.creakRatio * measured) || rough;
            // The speaker's median also learns from smooth low frames (a deep voice talks below 70 Hz; without them
            // its median would stay at the first guess). Rough frames and octave-low ones (fry) stay out.
            if (creak && !rough && (f0 >= 0.5f * measured || !known)) learnMedian(f0);
        } else {
            prevCount = 0;
            creak = levelOk && ap >= tuning.creakApLow && ap <= tuning.creakApHigh && lastGoodAge <= 15;
        }
        frames++;
        float target = 0, aiWant = 0;  // aiWant: the pitch the AI voice should sing now (0 = unvoiced)
        if (voiced && !creak) {
            learnMedian(f0);
            const float off = semitones(voice.targetHz / median);
            const float dev = std::clamp(semitones(f0 / median), -12.0f, 12.0f);
            lastDev = dev;
            const float shift = off + (voice.intonation - 1) * dev;
            const float alpha = 1 - std::exp(-10.0f / std::max(1.0f, tuning.smoothMs));
            shiftFrame = shiftKnown ? shiftFrame + alpha * (shift - shiftFrame) : shift;
            shiftKnown = true;
            const float full = std::fabs(semitones(voice.targetHz / voice.assumedInputHz));
            shapePower = full > 0.25f ? std::clamp(std::fabs(off) / full, 0.0f, 1.0f) : (std::fabs(off) > 0.25f ? 1.0f : 0.0f);
            const float total = std::clamp(strength * shiftFrame + extra, -tuning.maxSemitones, tuning.maxSemitones);
            target = f0 * std::exp2(total / 12);
            aiWant = target;
            lastGoodHz = target;
            lastGoodAge = 0;
            voicedFrames++;
        } else {
            lastGoodAge++;
            if (creak && lastGoodHz > 0) {
                target = lastGoodHz;  // hold: the pitch stays put through creak
                creakFrames++;
                voicedFrames++;
            }
            if (creak && shiftKnown) {  // the intonation part holds; the offset still follows the median as it learns
                const float shift = semitones(voice.targetHz / median) + (voice.intonation - 1) * lastDev;
                shiftFrame += (1 - std::exp(-10.0f / std::max(1.0f, tuning.smoothMs))) * (shift - shiftFrame);
            }
            // The AI voice through creak: while it sings, it moves with a gradual fall or rise (not below
            // creakRatio x median, mapped) and holds through a sudden drop (an octave drop, creak) or rough frames;
            // a voiced sound that starts in creak starts at its own pitch (not below the floor); an aperiodic
            // moment holds only while the AI voice is still singing (it never starts from an old pitch).
            if (creak && shiftKnown) {
                // (an aperiodic frame keeps it going only up to aiHoldFrames after the last voiced frame)
                const bool going = aiHz > 0 && aiAge <= (int)tuning.contFrames && voicedAge <= (int)tuning.aiHoldFrames;
                const float total = std::clamp(strength * shiftFrame + extra, -tuning.maxSemitones, tuning.maxSemitones);
                const float floorHz = tuning.creakRatio * median * std::exp2(total / 12);
                if (going) {
                    float ratio = 1;
                    if (voiced && !rough && prevCount >= 2) {
                        const float r = prev[prevCount - 1] / prev[prevCount - 2];
                        if (std::fabs(semitones(r)) <= 2.5f) ratio = r;
                    }
                    aiWant = std::max(aiHz * ratio, std::min(aiHz, floorHz));
                } else if (voiced) {
                    aiWant = std::max(f0 * std::exp2(total / 12), floorHz);
                }
            }
        }
        // Realistic mode's pitch: the band's centre is where the speaker's median lands.
        const float bandCentre = shiftKnown ? median * std::exp2(std::clamp(strength * semitones(voice.targetHz / median) + extra,
                                                                               -tuning.maxSemitones, tuning.maxSemitones) / 12) : 0;
        const float aiTarget = aiPitch(aiWant, bandCentre);
        const int64_t index = ++flagLatest;
        flagRing[index % kFlagFrames] = (uint8_t)(voiced || creak);
        flagCentre[index % kFlagFrames] = centre;
        if (out) {
            out->voiced = voiced ? 1 : 0;
            out->f0In = voiced ? f0 : 0;
            out->f0Target = aiTarget;
            if (out->newFrames < VOICECHANGER_MAX_PITCH_FRAMES) {
                out->frameHz[out->newFrames] = aiTarget;
                out->framePos[out->newFrames] = centre;
                out->newFrames++;
            }
        }
    }

    // Was the sound at mic position `pos` voiced (or creak)?
    bool voicedAt(int64_t pos) const {
        if (flagLatest < 0) return false;
        const int64_t latestCentre = flagCentre[flagLatest % kFlagFrames];
        if (pos >= latestCentre) return flagRing[flagLatest % kFlagFrames] != 0;
        const int64_t back = (latestCentre - pos + hopIn / 2) / hopIn;
        if (back >= kFlagFrames || back > flagLatest) return false;
        return flagRing[(flagLatest - back) % kFlagFrames] != 0;
    }

    // Tone EQ: new gains from the measured long-term spectrum (once per 256 samples).
    void updateEq() {
        const double minBlocks = tuning.eqStartSeconds * rate / kEqBlock;
        const bool ready = measuredBlocks >= std::max(1.0, minBlocks) && voice.eqAmount > 0;
        float corr[kBands] = {};
        if (ready) {
            double dbOut[kBands], tNorm = 0, mNorm = 0;
            int n = 0;
            for (int k = 0; k < kBands; ++k) dbOut[k] = 10 * std::log10(measured[k] + 1e-20);
            for (int k = 6; k <= 12; ++k) { tNorm += voice.ltas[k]; mNorm += dbOut[k]; ++n; }
            tNorm /= n; mNorm /= n;
            float raw[kBands];
            for (int k = 0; k < kBands; ++k)
                raw[k] = bandOk[k] ? (float)((voice.ltas[k] - tNorm) - (dbOut[k] - mNorm)) : 0.0f;
            for (int k = 0; k < kBands; ++k) {
                float s = 0; int c = 0;
                for (int j = std::max(0, k - 1); j <= std::min(kBands - 1, k + 1); ++j) if (bandOk[j]) { s += raw[j]; ++c; }
                corr[k] = c ? s / c : 0;
            }
        }
        for (int m = 0; m < kEq; ++m) {
            float want = 0;
            if (ready && eqOk[m]) {
                const int k = std::min(3 * m, kBands - 1);
                float s = 0; int c = 0;
                for (int j = std::max(0, k - 1); j <= std::min(kBands - 1, k + 1); ++j) if (bandOk[j]) { s += corr[j]; ++c; }
                want = c ? s / c : 0;
                want = std::clamp(want * voice.eqAmount, -tuning.eqMaxDb, tuning.eqMaxDb);
            }
            eqTarget[m] = want;
            const float step = tuning.eqStepDb;
            eqSlow[m] += std::clamp(eqTarget[m] - eqSlow[m], -step, step);
            const float applied = eqSlow[m] * strength;
            if (eqOk[m] && std::fabs(applied - eqApplied[m]) > 0.001f) {
                eq[m].peak(eqHz[m], 1.41, applied, rate);
                eqApplied[m] = applied;
            }
        }
    }

    void updatePresence() {
        const float want = voice.presenceDb * strength;
        if (std::fabs(want - presenceApplied) > 0.001f) {
            presence.peak(std::min((double)tuning.presenceHz, 0.4 * rate), tuning.presenceQ, want, rate);
            presenceApplied = want;
        }
    }

    void count(double startNs, int n) {
        const double spent = nowNs() - startNs;
        spentNs += spent;
        windowNs += spent;
        windowFrames += n;
        const double tenMs = 0.01 * rate;
        if (windowFrames >= tenMs) {
            worstMs = std::max(worstMs, windowNs * (tenMs / windowFrames) / 1e6);
            windowNs = 0;
            windowFrames = 0;
        }
    }

    void clearSound() {
        for (auto &f : antiAlias) f.clear();
        std::memset(dec, 0, sizeof(float) * (size_t)decSize);
        std::memset(original, 0, sizeof(float) * (size_t)inSize);
        decPhase = 0; decCount = 0; inPos = 0; hops = 0;
        for (int k = 0; k < 3; ++k) { lastF0[k] = 0; lastAp[k] = 1; lastLevel[k] = -140; lastCentre[k] = 0; }
        prevCount = 0;
        lastGoodAge = 999;
        for (int k = 0; k < 3; ++k) { octHz[k] = 0; octPath[k] = 0; }
        octAge = 999;
        aiHz = 0; aiAge = 999; voicedAge = 999;
        flagLatest = -1;
        frames = voicedFrames = creakFrames = 0;
        sibTop.clear(); sibOrigTop.clear();
        sibKeep = 0; voicedNow = 0;
        for (int k = 0; k < kBandsPadded; ++k) { bz1[k] = bz2[k] = bacc[k] = 0; }
        blockAt = 0; blockVoiced = 0;
        for (auto &f : eq) f.clear();
        presence.clear();
        for (int b = 0; b < kBreath; ++b) { breathBand[b].clear(); breathNoise[b].clear(); breathEnv[b] = 0; }
        noiseState = 0x9E3779B9u;
        spentNs = spentFrames = windowNs = windowFrames = worstMs = 0;
    }

    void flushAll() {
        for (auto &f : antiAlias) f.flush();
        sibTop.flush(); sibOrigTop.flush();
        for (auto &f : eq) f.flush();
        presence.flush();
        for (int b = 0; b < kBreath; ++b) { breathBand[b].flush(); breathNoise[b].flush(); }
        for (int k = 0; k < kBandsPadded; ++k) {
            if (std::fabs(bz1[k]) < 1e-25f) bz1[k] = 0;
            if (std::fabs(bz2[k]) < 1e-25f) bz2[k] = 0;
        }
        if (std::fabs(sibKeep) < 1e-20f) sibKeep = 0;
        if (std::fabs(voicedNow) < 1e-20f) voicedNow = 0;
        for (int b = 0; b < kBreath; ++b) if (breathEnv[b] < 1e-20f) breathEnv[b] = 0;
    }
};

extern "C" {

VoiceChanger *voicechanger_new(double sampleRate, int maxFrames) {
    if (!(sampleRate >= 8000 && sampleRate <= 768000) || maxFrames <= 0) return nullptr;
    auto *c = new (std::nothrow) VoiceChanger();
    if (!c) return nullptr;
    c->rate = sampleRate;
    c->maxFrames = maxFrames;
    c->down = std::max(1, (int)std::lround(sampleRate / 16000.0));
    c->analysisRate = sampleRate / c->down;
    c->hop = std::max(1, (int)std::lround(0.010 * c->analysisRate));
    c->hopIn = c->hop * c->down;
    c->window = (int)std::lround(0.025 * c->analysisRate);
    c->tauMax = (int)std::ceil(c->analysisRate / 55.0);
    c->tauMin = (int)std::floor(c->analysisRate / 600.0);
    c->span = c->window + c->tauMax;
    c->decSize = 1;
    while (c->decSize < c->span + c->hop + 16) c->decSize <<= 1;
    c->inSize = 1;
    while (c->inSize < (int)(0.5 * sampleRate) + maxFrames + 16) c->inSize <<= 1;
    c->dec = new (std::nothrow) float[c->decSize]();
    c->lin = new (std::nothrow) float[c->span]();
    c->energy = new (std::nothrow) double[c->span + 1]();
    c->diff = new (std::nothrow) float[c->tauMax + 2]();
    c->original = new (std::nothrow) float[c->inSize]();
    if (!c->dec || !c->lin || !c->energy || !c->diff || !c->original) {
        voicechanger_delete(c);
        return nullptr;
    }
    // Low-pass before thinning: 6th-order Butterworth at a quarter of the analysis rate (4 kHz at 16 kHz).
    if (c->down > 1) {
        const double qs[3] = {0.5176, 0.7071, 1.9319};
        for (int k = 0; k < 3; ++k) c->antiAlias[k].lowPass(0.25 * c->analysisRate, qs[k], sampleRate);
    }
    const double nyquistUse = 0.45 * sampleRate;
    for (int k = 0; k < kBands; ++k) {
        const double centre = 125.0 * std::pow(2.0, k / 3.0);
        c->bandOk[k] = centre * std::pow(2.0, 1 / 6.0) < nyquistUse;
        Biquad b;
        b.bandPass(std::min(centre, 0.45 * sampleRate), centre / (centre * (std::pow(2.0, 1 / 6.0) - std::pow(2.0, -1 / 6.0))), sampleRate);
        c->bb0[k] = (float)b.b0; c->bb2[k] = (float)b.b2; c->ba1[k] = (float)b.a1; c->ba2[k] = (float)b.a2;
    }
    for (int m = 0; m < kEq; ++m) {
        c->eqHz[m] = 125.0 * std::pow(2.0, m);
        c->eqOk[m] = c->eqHz[m] < nyquistUse;
    }
    const double breathLo[kBreath] = {1500, 2500, 4000, 6000}, breathHi[kBreath] = {2500, 4000, 6000, 9000};
    for (int b = 0; b < kBreath; ++b) {
        const double centre = std::sqrt(breathLo[b] * breathHi[b]), q = centre / (breathHi[b] - breathLo[b]);
        c->breathOk[b] = breathHi[b] < nyquistUse;
        if (!c->breathOk[b]) continue;
        c->breathBand[b].bandPass(centre, q, sampleRate);
        c->breathNoise[b].bandPass(centre, q, sampleRate);
        // Scale the band's noise so its average size (mean |x|) is 1, like the loudness it follows.
        Biquad probe = c->breathBand[b];
        probe.clear();
        double power = 0;
        for (int i = 0; i < (int)sampleRate; ++i) {
            const double h = probe.run(i == 0 ? 1.0 : 0.0);
            power += h * h;
        }
        const double sigma = std::sqrt(power / 3.0);  // uniform noise in -1 ... 1 has variance 1/3
        c->breathNorm[b] = sigma > 0 ? 1.0 / (std::sqrt(2.0 / kPi) * sigma) : 0;
    }
    c->sibTop.highPass(std::min((double)c->tuning.sibilanceHz, 0.4 * sampleRate), 0.7071, sampleRate);
    c->sibOrigTop = c->sibTop;
    c->sibStep = (float)(1 - std::exp(-1.0 / (0.005 * sampleRate)));
    c->voicedStep = (float)(1 - std::exp(-1.0 / (0.010 * sampleRate)));
    c->breathAttack = (float)(1 - std::exp(-1.0 / (c->tuning.breathAttackMs * 0.001 * sampleRate)));
    c->breathRelease = (float)(1 - std::exp(-1.0 / (c->tuning.breathReleaseMs * 0.001 * sampleRate)));
    c->clearSound();
    return c;
}

void voicechanger_delete(VoiceChanger *c) {
    if (!c) return;
    delete[] c->dec;
    delete[] c->lin;
    delete[] c->energy;
    delete[] c->diff;
    delete[] c->original;
    delete c;
}

void voicechanger_set(VoiceChanger *c, const VoiceChangerVoice *voice, float strength) {
    if (!c) return;
    if (voice) {
        const float oldTarget = c->voice.targetHz;
        if (!c->hasVoice || std::memcmp(voice, &c->asSet, sizeof(VoiceChangerVoice)) != 0) {
            c->asSet = *voice;
            c->applyVoice();
            // a new target: move the held shift with it (the next voiced frame works it out again)
            if (c->hasVoice && c->shiftKnown && oldTarget > 0) c->shiftFrame += semitones(c->voice.targetHz / oldTarget);
        }
        c->hasVoice = true;
        c->strengthTarget = std::clamp(strength, 0.0f, 1.0f);
    } else {
        c->strengthTarget = 0;  // fades out; the voice is kept for that
    }
}

void voicechanger_reset(VoiceChanger *c) {
    if (!c) return;
    c->clearSound();
    c->strength = c->strengthTarget;  // nothing old to glide from
    c->shiftNow = c->shiftFrame;
    if (c->hasVoice) {
        const double shape = std::log((double)c->voice.formant) * c->strength * c->shapePower;
        c->shapeLogNow = shape;
    }
}

void voicechanger_set_speaker(VoiceChanger *c, float medianHz, float weightFrames) {
    if (!c) return;
    const bool ok = std::isfinite(medianHz) && medianHz >= 50 && medianHz <= 500 && std::isfinite(weightFrames) && weightFrames > 0;
    c->speakerHz = ok ? medianHz : 0;
    c->speakerWeight = ok ? weightFrames : 0;
    c->seeded = false;   // the first guess is made again
    c->medianUse = 0;
    if (c->hasVoice) c->applyVoice();
}

void voicechanger_analyse(VoiceChanger *c, const float *in, int frames, float extraSemitones, VoiceChangerPitch *out) {
    if (out) out->newFrames = 0;
    if (!c || !in || frames <= 0) return;
    const double start = nowNs();
    if (!c->hasVoice) {
        if (out) { out->pitchScale = std::exp2(extraSemitones / 12); out->formantScale = 1 / out->pitchScale; }
        return;
    }
    if (!c->shiftKnown) {  // before any voice: shift as if the speaker had the assumed pitch
        c->shiftFrame = semitones(c->voice.targetHz / c->voice.assumedInputHz);
        c->shiftNow = c->shiftFrame;
        c->shiftKnown = true;
        c->shapePower = 1;
    }
    const int decMask = c->decSize - 1, inMask = c->inSize - 1;
    for (int i = 0; i < frames; ++i) {
        const float x = in[i];
        c->original[c->inPos & inMask] = x;
        c->inPos++;
        double v = x;
        if (c->down > 1) {
            for (auto &f : c->antiAlias) v = f.run(v);
            if (++c->decPhase < c->down) continue;
            c->decPhase = 0;
        }
        c->dec[c->decCount & decMask] = (float)v;
        c->decCount++;
        if (c->decCount >= c->span && c->decCount % c->hop == 0) c->analyseHop(extraSemitones, out);
    }
    // Per callback: strength, shift and voice shape glide toward where they're heading.
    const float strengthStep = (float)(frames / (std::max(0.001f, c->tuning.strengthGlideS) * c->rate));
    c->strength += std::clamp(c->strengthTarget - c->strength, -strengthStep, strengthStep);
    c->shiftNow += (c->shiftFrame - c->shiftNow) * std::min(1.0f, (float)frames / c->hopIn);
    const double shapeWant = std::log((double)c->voice.formant) * c->strength * c->shapePower;
    c->shapeLogNow += (shapeWant - c->shapeLogNow) * (1 - std::exp(-frames / (c->tuning.formantGlideMs * 0.001 * c->rate)));
    const float total = std::clamp(c->strength * c->shiftNow + extraSemitones, -c->tuning.maxSemitones, c->tuning.maxSemitones);
    c->semitonesNow = total;
    c->pitchScale = std::exp2(total / 12);
    c->formantScale = (float)(std::exp(c->shapeLogNow) / c->pitchScale);
    if (out) {
        out->pitchScale = c->pitchScale;
        out->formantScale = c->formantScale;
        if (out->newFrames == 0) { out->voiced = 0; out->f0In = 0; out->f0Target = 0; }
    }
    c->flushAll();
    c->count(start, frames);
}

void voicechanger_post(VoiceChanger *c, float *io, int frames, int delayFrames) {
    if (!c || !io || frames <= 0 || !c->hasVoice) return;
    const double start = nowNs();
    const float s = c->strength;
    const VoiceChangerVoice &v = c->voice;
    c->updatePresence();
    const bool sibilance = v.sibilanceKeep > 0 || c->sibKeep > 1e-6f;
    const bool presence = v.presenceDb != 0;
    const bool breath = v.breathDb > -90 && s > 0;
    const float breathGain = breath ? std::pow(10.0f, v.breathDb / 20) * s : 0;
    const bool measure = v.eqAmount > 0;
    const int inMask = c->inSize - 1;
    const int64_t first = c->inPos - std::max(0, delayFrames) - frames;  // mic position of io[0]
    bool voiced = c->voicedAt(first);
    for (int i = 0; i < frames; ++i) {
        if ((i & 31) == 0 && i > 0) voiced = c->voicedAt(first + i);
        c->voicedNow += ((voiced ? 1.0f : 0.0f) - c->voicedNow) * c->voicedStep;
        double y = io[i];
        if (sibilance) {
            const int64_t at = first + i;
            const bool have = at >= 0 && at > c->inPos - c->inSize;
            const double x = have ? c->original[at & inMask] : 0.0;
            const double top = c->sibTop.run(y), originalTop = c->sibOrigTop.run(x);
            const float want = voiced ? 0.0f : v.sibilanceKeep * s;
            c->sibKeep += (want - c->sibKeep) * c->sibStep;
            y += c->sibKeep * (originalTop - top);
        }
        if (measure) {
            const float yf = (float)y;
#pragma clang loop vectorize(enable)
            for (int k = 0; k < kBandsPadded; ++k) {
                const float o = c->bb0[k] * yf + c->bz1[k];
                c->bz1[k] = -c->ba1[k] * o + c->bz2[k];
                c->bz2[k] = c->bb2[k] * yf - c->ba2[k] * o;
                c->bacc[k] += o * o;
            }
            c->blockVoiced += voiced ? 1.0f : 0.0f;
            if (++c->blockAt == kEqBlock) {
                if (c->blockVoiced > 0.5f * kEqBlock) {
                    c->measuredBlocks++;
                    const double a = std::max(1.0 / (double)c->measuredBlocks, kEqBlock / (c->tuning.eqSeconds * c->rate));
                    for (int k = 0; k < kBands; ++k) c->measured[k] += a * (c->bacc[k] / kEqBlock - c->measured[k]);
                }
                for (int k = 0; k < kBandsPadded; ++k) c->bacc[k] = 0;
                c->blockAt = 0;
                c->blockVoiced = 0;
                c->updateEq();
            }
        }
        if (measure) {  // always run while in use (a 0 dB peak passes the sound unchanged), so no stale state clicks
            for (int m = 0; m < kEq; ++m) if (c->eqOk[m]) y = c->eq[m].run(y);
        }
        if (presence) y = c->presence.run(y);
        if (breath) {
            double add = 0;
            const float gate = c->voicedNow;
            for (int b = 0; b < kBreath; ++b) {
                if (!c->breathOk[b]) continue;
                const float level = (float)std::fabs(c->breathBand[b].run(y));
                float &env = c->breathEnv[b];
                env += (level - env) * (level > env ? c->breathAttack : c->breathRelease);
                const double n = c->breathNoise[b].run(noise(c->noiseState)) * c->breathNorm[b];
                add += env * n;
            }
            y += add * breathGain * gate;
        }
        io[i] = (float)y;
    }
    c->flushAll();
    c->count(start, 0);
}

int voicechanger_tune(VoiceChanger *c, const char *key, float value) {
    if (!c || !key || !std::isfinite(value)) return 0;
    for (int k = 0; k < kVoiceKeyCount; ++k) {
        if (std::strcmp(key, kVoiceKeys[k].name) == 0) {
            c->overridden[k] = true;
            c->overrideValue[k] = value;
            if (c->hasVoice) c->applyVoice();
            return 1;
        }
    }
    for (const auto &t : kTuneKeys) {
        if (std::strcmp(key, t.name) == 0) {
            c->tuning.*(t.field) = value;
            // settings that shape filters made at the start
            c->breathAttack = (float)(1 - std::exp(-1.0 / (std::max(0.1f, c->tuning.breathAttackMs) * 0.001 * c->rate)));
            c->breathRelease = (float)(1 - std::exp(-1.0 / (std::max(0.1f, c->tuning.breathReleaseMs) * 0.001 * c->rate)));
            c->sibTop.highPass(std::min((double)c->tuning.sibilanceHz, 0.4 * c->rate), 0.7071, c->rate);
            c->sibOrigTop.highPass(std::min((double)c->tuning.sibilanceHz, 0.4 * c->rate), 0.7071, c->rate);
            c->presenceApplied = 1e9f;  // made again on the next post
            if (c->hasVoice) c->applyVoice();
            return 1;
        }
    }
    return 0;
}

void voicechanger_get_stats(const VoiceChanger *c, VoiceChangerStats *out) {
    if (!out) return;
    std::memset(out, 0, sizeof(*out));
    if (!c) return;
    out->strength = c->strength;
    out->medianHz = c->medianHz;
    out->semitones = c->semitonesNow;
    out->formant = (float)std::exp(c->shapeLogNow);
    out->voicedShare = c->frames ? (float)c->voicedFrames / (float)c->frames : 0;
    out->creakShare = c->voicedFrames ? (float)c->creakFrames / (float)c->voicedFrames : 0;
    for (int m = 0; m < kEq; ++m) out->eqDb[m] = c->eqApplied[m];
    out->frames = c->frames;
    const double tenMs = 0.01 * c->rate;
    out->analyseMs = c->inPos > 0 ? c->spentNs / 1e6 * tenMs / (double)c->inPos : 0;
    out->worstMs = c->worstMs;
    out->learnedFrames = c->learned;
}

}  // extern "C"
