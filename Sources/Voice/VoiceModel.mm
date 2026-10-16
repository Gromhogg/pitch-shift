// Voice changer, Realistic mode (see VoiceModel.h): an RVC v2 voice run with Core ML on its own worker thread.
// Objective-C++ with ARC. Apple silicon only; Intel Macs keep the stubs at the bottom for good.
//
// How the sound flows (live):
//   sound thread                         worker thread ("Pitch Shift AI voice", user-interactive)
//   push: mic --> ring `in` (chain rate) --> libsamplerate --> ring `in16` (16 kHz)
//         pitch frames --> ring `pitch`      every hop (H frames of 10 ms) once the window [E-T, E) is there:
//                                             ContentVec (Core ML) -> features
//                                             pitch per 10 ms frame (from A1's tracker, nearest frame) -> 1..255
//                                             NSF source (float64 phase, carried across hops) + fixed noise
//                                             generator (Core ML) -> the last DEC frames at 48 kHz
//                                             drop the left margin -> SOLA crossfade -> loudness = the mic's
//                                             -> (resample to the chain rate) -> ring `out` (+ a provisional tail)
//   pull: out <-- ring `out` at a fixed delay, or Natural's sound delayed to the same delay (10 ms crossfades)
// Every ring is indexed by the absolute sample position, so the AI voice, the mic and Natural's sound line up.
// libsamplerate keeps output sample i exactly at input time i / ratio; it only hands it over a little later (its
// "lag", measured once), which the fixed delay includes.
//
// Model files (made by research/voicechanger/pack_voices.sh):
//   encoder  in "audio" Float32 [1, T*160] (16 kHz) -> out "features" Float32 [1, T/2, 768]
//   voice    in "features" [1, T/2, 768], "pitch" Int32 [1, T], "source" Float32 [1, 1, DEC*upp],
//            "noise" Float32 [1, 192, FLOW] -> out "audio" Float32 [1, DEC*upp]
//   metadata: rate, upp, window_frames (T), dec_frames, flow_frames, hop_ms, context_ms (+ xfade_ms, sola_ms,
//   margin_ms on newer files).
#include "VoiceModel.h"

#include <cstdio>
#include <cstring>

namespace {
void say(char *err, int errSize, const char *text) {
    if (err && errSize > 0) std::snprintf(err, (size_t)errSize, "%s", text);
}
}  // namespace

#if __arm64__

#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>
#include <Accelerate/Accelerate.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <samplerate.h>
#include <time.h>
#include <unistd.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <string>
#include <vector>

namespace {

const int kRate16 = 16000;
const int kFrame16 = 160;      // samples in a 10 ms frame at 16 kHz
const int kFeatureDim = 768;
const int kNoiseChannels = 192;
const int kZpFrames = 4096;    // fixed z-noise table: 192 x 4096
const int kSourceNoise = 1 << 18;
const int kPitchSlots = 2048;  // 20 s of 10 ms pitch frames

double nowMs() {
    static mach_timebase_info_data_t tb = [] { mach_timebase_info_data_t t; mach_timebase_info(&t); return t; }();
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

double threadCpuMs() {
    struct timespec ts;
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

int64_t pow2AtLeast(int64_t n) {
    int64_t p = 1;
    while (p < n) p <<= 1;
    return p;
}

// Mono sound kept by absolute position (slot = position mod size). One thread writes, another reads.
struct Ring {
    std::vector<float> buf;
    int64_t mask = 0;
    void init(int64_t minSize) {
        buf.assign((size_t)pow2AtLeast(std::max<int64_t>(minSize, 2)), 0.0f);
        mask = (int64_t)buf.size() - 1;
    }
    int64_t size() const { return mask + 1; }
    void put(int64_t pos, const float *x, int n) {
        for (int i = 0; i < n; i++) buf[(size_t)((pos + i) & mask)] = x[i];
    }
    float at(int64_t pos) const { return buf[(size_t)(pos & mask)]; }
    // Positions below `valid` read as silence (nothing was there yet).
    void get(int64_t pos, float *x, int n, int64_t valid = INT64_MIN) const {
        for (int i = 0; i < n; i++) x[i] = pos + i < valid ? 0.0f : buf[(size_t)((pos + i) & mask)];
    }
};

// Deterministic Gaussian numbers (xorshift + Box-Muller), so every run makes the same noise.
struct Gauss {
    uint64_t s;
    explicit Gauss(uint64_t seed) : s(seed ? seed : 0x9E3779B97F4A7C15ull) {}
    double uniform() {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17;
        return ((s >> 11) + 0.5) * (1.0 / 9007199254740992.0);
    }
    float next() {
        double u1 = uniform(), u2 = uniform();
        return (float)(std::sqrt(-2.0 * std::log(u1)) * std::cos(2 * M_PI * u2));
    }
};

// Mono libsamplerate converter (sinc, medium quality). Identity ratio: no converter, no lag.
class Resampler {
public:
    ~Resampler() { if (state_) src_delete(state_); }
    bool init(double ratio, int maxIn) {
        if (state_) { src_delete(state_); state_ = nullptr; }
        ratio_ = ratio;
        identity_ = std::fabs(ratio - 1.0) < 1e-12;
        outCap_ = (int)std::ceil(maxIn * ratio) + 64;
        out_.assign((size_t)outCap_, 0.0f);
        if (identity_) return true;
        int err = 0;
        state_ = src_new(SRC_SINC_MEDIUM_QUALITY, 1, &err);
        return state_ != nullptr;
    }
    void reset() { if (state_) src_reset(state_); }
    bool identity() const { return identity_; }
    double ratio() const { return ratio_; }

    // The most the output count can trail input * ratio (output samples), measured once with tiny pieces.
    static double lag(double ratio) {
        if (std::fabs(ratio - 1.0) < 1e-12) return 0;
        int err = 0;
        SRC_STATE *s = src_new(SRC_SINC_MEDIUM_QUALITY, 1, &err);
        if (!s) return 0;
        std::vector<float> in(7, 0.0f), out(256);
        double worst = 0;
        long fed = 0, made = 0;
        for (int k = 0; k < 6000; k++) {
            SRC_DATA d{};
            d.data_in = in.data(); d.input_frames = 7; d.data_out = out.data(); d.output_frames = 256; d.src_ratio = ratio;
            src_process(s, &d);
            fed += d.input_frames_used; made += d.output_frames_gen;
            worst = std::max(worst, fed * ratio - made);
        }
        src_delete(s);
        return worst;
    }

    // Feeds n samples (n <= maxIn); hands each piece made to sink(ptr, count).
    template <class Sink> void run(const float *x, int n, Sink &&sink) { run(state_, x, n, sink); }

    // The same with a throw-away copy of the state (for the provisional tail, which must not move the real one).
    template <class Sink> void runCopy(const float *x, int n, Sink &&sink) {
        if (identity_) { sink(x, n); return; }
        int err = 0;
        SRC_STATE *c = src_clone(state_, &err);
        if (!c) return;
        run(c, x, n, sink);
        src_delete(c);
    }

private:
    template <class Sink> void run(SRC_STATE *st, const float *x, int n, Sink &&sink) {
        if (identity_) { sink(x, n); return; }
        long used = 0;
        while (used < n) {
            SRC_DATA d{};
            d.data_in = x + used; d.input_frames = n - used;
            d.data_out = out_.data(); d.output_frames = outCap_; d.src_ratio = ratio_;
            if (src_process(st, &d) != 0) return;
            used += d.input_frames_used;
            if (d.output_frames_gen > 0) sink(out_.data(), (int)d.output_frames_gen);
            if (d.input_frames_used == 0 && d.output_frames_gen == 0) return;
        }
    }
    SRC_STATE *state_ = nullptr;
    double ratio_ = 1;
    bool identity_ = true;
    int outCap_ = 0;
    std::vector<float> out_;
};

MLComputeUnits unitsFor(int u) {
    switch (u) {
        case VOICEMODEL_COMPUTE_CPU: return MLComputeUnitsCPUOnly;
        case VOICEMODEL_COMPUTE_GPU: return MLComputeUnitsCPUAndGPU;
        case VOICEMODEL_COMPUTE_ANE: return MLComputeUnitsCPUAndNeuralEngine;
        default: return MLComputeUnitsAll;
    }
}

const char *unitsName(int u) {
    switch (u) {
        case VOICEMODEL_COMPUTE_CPU: return "CPU";
        case VOICEMODEL_COMPUTE_GPU: return "GPU";
        case VOICEMODEL_COMPUTE_ANE: return "Neural Engine";
        default: return "all";
    }
}

int metaInt(NSDictionary *meta, NSString *key, int fallback) {
    id v = meta[key];
    if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) return [v intValue];
    return fallback;
}

// Our own memory, wrapped as an MLMultiArray (C order).
struct Buffer {
    std::vector<uint8_t> bytes;
    MLMultiArray *array = nil;
    size_t count = 0;
    bool make(NSArray<NSNumber *> *shape, MLMultiArrayDataType type) {
        count = 1;
        for (NSNumber *d in shape) count *= (size_t)d.integerValue;
        size_t each = type == MLMultiArrayDataTypeInt32 || type == MLMultiArrayDataTypeFloat32 ? 4 : 2;
        bytes.assign(count * each, 0);
        NSMutableArray<NSNumber *> *strides = [NSMutableArray array];
        NSInteger st = 1;
        for (NSInteger i = (NSInteger)shape.count - 1; i >= 0; i--) { [strides insertObject:@(st) atIndex:0]; st *= shape[i].integerValue; }
        NSError *why = nil;
        array = [[MLMultiArray alloc] initWithDataPointer:bytes.data() shape:shape dataType:type strides:strides deallocator:nil error:&why];
        return array != nil;
    }
    float *f() { return (float *)bytes.data(); }
    int32_t *i() { return (int32_t *)bytes.data(); }
    // If Core ML handed back its own array instead of writing into ours, copy it in.
    bool take(MLMultiArray *o) {
        if (!o) return false;
        if (o == array) return true;
        if ((size_t)o.count != count || o.dataType != array.dataType) return false;
        uint8_t *dst = bytes.data();
        size_t want = bytes.size();
        [o getBytesWithHandler:^(const void *b, NSInteger size) {
            if (b != dst) std::memcpy(dst, b, std::min<size_t>((size_t)size, want));
        }];
        return true;
    }
};

}  // namespace

// The loaded models. Shared by streams; free it only after every stream using it is deleted.
struct VoiceModel {
    MLModel *encoder = nil;
    MLModel *voice = nil;
    int unitsEncoder = 0, unitsVoice = 0;
    bool cpuOnly = false;          // fell back to the CPU (or asked for it): needs the bigger reserve
    int encoderSamples = 0;        // T * 160
    int featureFrames = 0;         // T / 2
    int T = 0;                     // pitch frames (10 ms)
    int decSamples = 0;            // DEC * upp
    int flowFrames = 0;            // FLOW
    int rate = 48000, upp = 480;
    int hopMs = 160, contextMs = 0, decFrames = 0, xfadeMs = 40, solaMs = 10, marginMs = 60;
    double loadMs = 0, warmMs = 0, probeHopMs = 0;
    std::string describe;
};

namespace {

// Everything a stream needs for one model (made off the sound thread, then handed to the worker).
struct Runner {
    VoiceModel *model = nullptr;
    Buffer audio16, features, pitch, source, noise, audioOut;
    id<MLFeatureProvider> encoderIn = nil, voiceIn = nil;
    MLPredictionOptions *encoderOptions = nil, *voiceOptions = nil;
    std::vector<float> sourceNoise;   // kSourceNoise values
    std::vector<float> zp;            // kNoiseChannels x kZpFrames
    std::vector<double> f0;           // T values, Hz
    std::vector<float> y, block, tail, sola, fadeIn, fadeOut, gains;
};

bool predict(MLModel *m, id<MLFeatureProvider> in, MLPredictionOptions *opt, NSString *outName, Buffer &out) {
    @autoreleasepool {
        NSError *why = nil;
        id<MLFeatureProvider> r = [m predictionFromFeatures:in options:opt error:&why];
        if (!r) return false;
        return out.take([r featureValueForName:outName].multiArrayValue);
    }
}

bool makeRunner(VoiceModel *m, Runner &r) {
    r.model = m;
    NSError *why = nil;
    if (!r.audio16.make(@[@1, @(m->encoderSamples)], MLMultiArrayDataTypeFloat32)) return false;
    if (!r.features.make(@[@1, @(m->featureFrames), @(kFeatureDim)], MLMultiArrayDataTypeFloat32)) return false;
    if (!r.pitch.make(@[@1, @(m->T)], MLMultiArrayDataTypeInt32)) return false;
    if (!r.source.make(@[@1, @1, @(m->decSamples)], MLMultiArrayDataTypeFloat32)) return false;
    if (!r.noise.make(@[@1, @(kNoiseChannels), @(m->flowFrames)], MLMultiArrayDataTypeFloat32)) return false;
    if (!r.audioOut.make(@[@1, @(m->decSamples)], MLMultiArrayDataTypeFloat32)) return false;
    r.encoderIn = [[MLDictionaryFeatureProvider alloc] initWithDictionary:@{@"audio" : [MLFeatureValue featureValueWithMultiArray:r.audio16.array]} error:&why];
    r.voiceIn = [[MLDictionaryFeatureProvider alloc] initWithDictionary:@{
        @"features" : [MLFeatureValue featureValueWithMultiArray:r.features.array],
        @"pitch" : [MLFeatureValue featureValueWithMultiArray:r.pitch.array],
        @"source" : [MLFeatureValue featureValueWithMultiArray:r.source.array],
        @"noise" : [MLFeatureValue featureValueWithMultiArray:r.noise.array],
    } error:&why];
    if (!r.encoderIn || !r.voiceIn) return false;
    r.encoderOptions = [MLPredictionOptions new];
    r.encoderOptions.outputBackings = @{@"features" : r.features.array};
    r.voiceOptions = [MLPredictionOptions new];
    r.voiceOptions.outputBackings = @{@"audio" : r.audioOut.array};
    Gauss g(1234);
    r.sourceNoise.resize(kSourceNoise);
    for (auto &v : r.sourceNoise) v = g.next();
    Gauss gz(4321);
    r.zp.resize((size_t)kNoiseChannels * kZpFrames);
    for (auto &v : r.zp) v = gz.next();
    r.f0.assign((size_t)m->T, 0.0);
    r.y.assign((size_t)m->decSamples, 0.0f);
    return true;
}

}  // namespace

struct VoiceStream {
    // fixed at creation
    double rate = 48000;
    int maxFrames = 512;
    bool offline = false;
    int H = 16, X = 4, S = 1;      // hop, crossfade, search (10 ms frames)
    int reserveMs = 60;
    int latency = 0;               // chain samples
    int64_t aheadA = 0;            // converted stream index - input index ((X + S) * 10 ms)
    double inLag16 = 0;            // 16 kHz samples the input resampler holds back
    double outLag = 0;             // chain samples the output resampler holds back
    int rampLen = 480;             // 10 ms crossfade between the AI voice and Natural
    int modelRate = 48000;

    // sound thread -> worker
    Ring in;
    std::atomic<int64_t> inEnd{0};
    std::vector<int64_t> pitchPos;
    std::vector<float> pitchHz;
    std::atomic<int64_t> pitchEnd{0};
    std::atomic<int64_t> wakeAt{0};

    // worker -> sound thread
    Ring out;
    std::atomic<int64_t> outFinal{0};  // converted samples final up to here
    std::atomic<int64_t> outProv{0};   // ... plus a provisional tail up to here (late hops fade out on it)
    std::atomic<int64_t> outStart{INT64_MAX};  // first converted index ever written (after a model is attached)

    // worker state
    std::atomic<VoiceModel *> pending{nullptr};
    Runner *run = nullptr;
    Resampler toModel, toChain;
    Ring in16;
    int64_t in16End = 0;
    int64_t inUsed = 0;
    int64_t hop = -1;              // next hop to make (E = (hop + 1) * H)
    int64_t written = 0;           // converted samples written (chain rate)
    int64_t phaseAt = INT64_MIN;   // model-rate sample where `phase` applies
    double phase = 0;
    float lastGain = 0;
    std::vector<float> scratch, scratch16;
    pthread_t thread{};
    bool threadStarted = false;
    std::atomic<bool> quit{false};
    dispatch_semaphore_t wake = nullptr;
    double attachWallMs = 0, attachCpuMs = 0;

    // sound thread state
    Ring natural;
    int64_t pulled = 0;
    float mix = 0;                 // 1 = the AI voice, 0 = Natural
    bool playing = false;          // the AI voice has played (so a fall back counts as a miss)
    bool lateNow = false;

    // tuning (tests)
    std::atomic<int> slowMs{0}, slowEvery{1};
    std::atomic<float> gainMaxDb{18};

    // stats
    std::atomic<int> loaded{0};
    std::atomic<int64_t> hops{0}, misses{0}, fallbackFrames{0}, skipped{0};
    std::atomic<double> sumHopMs{0}, worstHopMs{0}, cpuShare{0};

    // ------------------------------------------------------------------------------------------- worker side
    // Moves new mic sound through the 16 kHz resampler.
    void resampleNew() {
        int64_t end = inEnd.load(std::memory_order_acquire);
        if (end - inUsed > in.size() - 4096) inUsed = end - (in.size() - 4096);  // fell far behind: skip
        while (inUsed < end) {
            int n = (int)std::min<int64_t>(end - inUsed, (int64_t)scratch.size());
            in.get(inUsed, scratch.data(), n);
            inUsed += n;
            toModel.run(scratch.data(), n, [&](const float *p, int m) {
                in16.put(in16End, p, m);
                in16End += m;
            });
        }
    }

    // Target pitch (Hz) at chain-sample position c, from A1's tracker frames (nearest one; newer than the newest
    // frame: hold the newest).
    double pitchAt(double c, int64_t pend, int64_t &cursor) const {
        if (pend <= 0) return 0;
        int64_t oldest = std::max<int64_t>(0, pend - kPitchSlots + 8);
        if (cursor < oldest) cursor = oldest;
        while (cursor + 1 < pend && pitchPos[(size_t)((cursor + 1) % kPitchSlots)] <= c) cursor++;
        int64_t a = cursor, b = std::min(cursor + 1, pend - 1);
        double pa = (double)pitchPos[(size_t)(a % kPitchSlots)], pb = (double)pitchPos[(size_t)(b % kPitchSlots)];
        if (c >= pb) return pitchHz[(size_t)(b % kPitchSlots)];  // the newest frames lack look-ahead: hold
        if (c < pa - rate * 0.02) return 0;
        return std::fabs(c - pa) <= std::fabs(pb - c) ? pitchHz[(size_t)(a % kPitchSlots)] : pitchHz[(size_t)(b % kPitchSlots)];
    }

    static int coarse(double f) {
        if (f <= 0) return 1;
        const double melMin = 1127 * std::log(1 + 50.0 / 700), melMax = 1127 * std::log(1 + 1100.0 / 700);
        double m = (1127 * std::log(1 + f / 700) - melMin) * 254 / (melMax - melMin) + 1;
        m = std::max(1.0, std::min(255.0, m));
        return (int)std::lrint(m);
    }

    // One hop: frames [E - T, E). Returns false if the models failed.
    bool makeHop(int64_t E) {
        Runner &r = *run;
        VoiceModel &m = *r.model;
        const int T = m.T, upp = m.upp, DEC = m.decFrames, FLOW = m.flowFrames;
        const int M = DEC - H - X - S;
        double t0 = nowMs();
        // 1. the window at 16 kHz
        in16.get((E - T) * kFrame16, r.audio16.f(), T * kFrame16, 0);
        // 2. pitch for every frame (frame j's centre is 16 kHz sample 160 j + 80)
        int64_t pend = pitchEnd.load(std::memory_order_acquire), cursor = 0;
        const double toChain16 = rate / kRate16;
        for (int t = 0; t < T; t++) {
            int64_t j = E - T + t;
            double f = j < 0 ? 0 : pitchAt((kFrame16 * (double)j + kFrame16 / 2) * toChain16, pend, cursor);
            r.f0[(size_t)t] = f;
            r.pitch.i()[t] = coarse(f);
        }
        // 3. NSF source for the last DEC frames at the model rate (phase in double, carried across hops)
        const int64_t decStart = (E - DEC) * (int64_t)upp;
        double ph = phaseAt == decStart ? phase : 0.0;
        const int64_t keep = decStart + (int64_t)H * upp;
        float *src = r.source.f();
        for (int t = 0; t < DEC; t++) {
            const double f = r.f0[(size_t)(T - DEC + t)];
            const double inc = f / modelRate;
            for (int i = 0; i < upp; i++) {
                const int64_t s = decStart + (int64_t)t * upp + i;
                if (s == keep) { phaseAt = keep; phase = ph; }
                const float n = r.sourceNoise[(size_t)(((s % kSourceNoise) + kSourceNoise) % kSourceNoise)];
                src[t * upp + i] = f > 0 ? (float)(0.1 * std::sin(2 * M_PI * ph)) + 0.003f * n : 0.1f / 3 * n;
                ph += inc;
                if (ph >= 1) ph -= std::floor(ph);
            }
        }
        // 4. fixed z noise for the last FLOW frames
        float *zn = r.noise.f();
        for (int c = 0; c < kNoiseChannels; c++)
            for (int t = 0; t < FLOW; t++) {
                int64_t a = E - FLOW + t;
                zn[(size_t)c * FLOW + t] = r.zp[(size_t)c * kZpFrames + (size_t)(((a % kZpFrames) + kZpFrames) % kZpFrames)];
            }
        // 5. the models
        if (!predict(m.encoder, r.encoderIn, r.encoderOptions, @"features", r.features)) return false;
        if (!predict(m.voice, r.voiceIn, r.voiceOptions, @"audio", r.audioOut)) return false;
        const int slow = slowMs.load();
        if (slow > 0 && slowEvery.load() > 0 && (hop % slowEvery.load()) == 0) usleep((useconds_t)slow * 1000);
        // 6. drop the left margin; SOLA: the best offset o in [0, S*upp] against the last tail, crossfade X*upp
        const float *y = r.audioOut.f() + (size_t)M * upp;
        const int hopN = H * upp, xN = X * upp, sN = S * upp;
        int o = 0;
        if (hops.load() > 0 && xN > 0 && sN > 0) {
            double best = -1e30;
            float energy = 0;
            vDSP_svesq(y, 1, &energy, (vDSP_Length)xN);
            for (int k = 0; k <= sN; k++) {
                float dot = 0;
                vDSP_dotpr(y + k, 1, r.sola.data(), 1, &dot, (vDSP_Length)xN);
                double score = dot / std::sqrt((double)energy + 1e-8);
                if (score > best) { best = score; o = k; }
                if (k < sN) energy += y[k + xN] * y[k + xN] - y[k] * y[k];
            }
        }
        float *blk = r.block.data();
        std::memcpy(blk, y + o, sizeof(float) * (size_t)hopN);
        for (int i = 0; i < xN; i++) blk[i] = blk[i] * r.fadeIn[(size_t)i] + r.sola[(size_t)i] * r.fadeOut[(size_t)i];
        std::memcpy(r.sola.data(), y + o + hopN, sizeof(float) * (size_t)xN);
        std::memcpy(r.tail.data(), r.sola.data(), sizeof(float) * (size_t)xN);
        // 7. loudness: follow the mic's own loudness, 10 ms by 10 ms (RVC's "rms mix" at 0), up to +gainMaxDb
        const float gmax = std::pow(10.0f, gainMaxDb.load() / 20);
        const int frames = H + X;
        for (int f = 0; f < frames; f++) {
            const int64_t a = E - H - X - S + f;  // the 16 kHz frame this output frame came from
            double ein = 0;
            for (int i = -kFrame16 / 2; i < kFrame16 * 3 / 2; i++) {
                int64_t p = a * kFrame16 + i;
                float v = p < 0 ? 0 : in16.at(p);
                ein += v * v;
            }
            double rin = std::sqrt(ein / (2 * kFrame16));
            double eout = 0;
            int cnt = 0;
            for (int i = -upp / 2; i < upp * 3 / 2; i++) {
                int p = o + f * upp + i;
                if (p < 0 || p >= (int)(r.audioOut.count - (size_t)M * upp)) continue;
                eout += (double)y[p] * y[p];
                cnt++;
            }
            double rout = std::max(1e-3, std::sqrt(eout / std::max(1, cnt)));
            r.gains[(size_t)f] = (float)std::min<double>(gmax, rin / rout);
        }
        float g0 = lastGain;
        for (int f = 0; f < H; f++) {  // ramp from the last frame's gain to this frame's, sample by sample
            float g1 = r.gains[(size_t)f];
            for (int i = 0; i < upp; i++) blk[f * upp + i] *= g0 + (g1 - g0) * (i + 1) / upp;
            g0 = g1;
        }
        const float gEnd = g0;
        for (int f = 0; f < X; f++) {
            float g1 = r.gains[(size_t)(H + f)];
            for (int i = 0; i < upp; i++) r.tail[(size_t)(f * upp + i)] *= g0 + (g1 - g0) * (i + 1) / upp;
            g0 = g1;
        }
        lastGain = gEnd;
        // 8. into the output ring (chain rate): the final block, then the provisional tail after it
        toChain.run(blk, hopN, [&](const float *p, int n) {
            out.put(written, p, n);
            written += n;
        });
        int64_t prov = written;
        toChain.runCopy(r.tail.data(), xN, [&](const float *p, int n) {
            out.put(prov, p, n);
            prov += n;
        });
        outFinal.store(written, std::memory_order_release);
        outProv.store(std::max(prov, written), std::memory_order_release);
        // 9. stats
        double ms = nowMs() - t0;
        hops.fetch_add(1);
        sumHopMs.store(sumHopMs.load() + ms);
        if (ms > worstHopMs.load()) worstHopMs.store(ms);
        double wall = nowMs() - attachWallMs;
        if (wall > 0) cpuShare.store((threadCpuMs() - attachCpuMs) / wall);
        return true;
    }

    // Starts a model on this stream (worker thread, or the caller's in offline mode).
    void adopt(VoiceModel *m) {
        Runner *r = new Runner();
        if (!makeRunner(m, *r)) { delete r; return; }
        const int upp = m->upp, xN = X * upp, hopN = H * upp;
        r->block.assign((size_t)hopN, 0.0f);
        r->tail.assign((size_t)xN, 0.0f);
        r->sola.assign((size_t)xN, 0.0f);
        r->fadeIn.resize((size_t)xN);
        r->fadeOut.resize((size_t)xN);
        for (int i = 0; i < xN; i++) {
            double s = std::sin(0.5 * M_PI * i / std::max(1, xN));
            r->fadeIn[(size_t)i] = (float)(s * s);
            r->fadeOut[(size_t)i] = 1 - r->fadeIn[(size_t)i];
        }
        r->gains.assign((size_t)(H + X), 0.0f);
        delete run;
        run = r;
        modelRate = m->rate;
        toChain.init(rate / m->rate, hopN + xN + 64);
        // start at the newest complete hop (the window before it is history, or silence)
        resampleNew();
        hop = std::max<int64_t>(0, in16End / ((int64_t)H * kFrame16) - 1);
        const int64_t m0 = hop * (int64_t)H * upp;  // model-rate index of this hop's block
        written = (int64_t)std::llround(m0 * rate / m->rate);
        outFinal.store(written, std::memory_order_release);
        outProv.store(written, std::memory_order_release);
        outStart.store(written, std::memory_order_release);
        lastGain = 0;
        phaseAt = INT64_MIN;
        attachWallMs = nowMs();
        attachCpuMs = threadCpuMs();
        loaded.store(1);
    }

    // Makes every hop whose window is complete.
    void work() {
        VoiceModel *m = pending.exchange(nullptr);
        if (m) adopt(m);
        resampleNew();
        if (!run) {  // no model yet: only keep the 16 kHz copy moving; look again in 100 ms
            wakeAt.store(inEnd.load(std::memory_order_relaxed) + (int64_t)(rate * 0.1), std::memory_order_release);
            return;
        }
        const int64_t step = (int64_t)H * kFrame16;
        // fell more than a second behind (a stall): jump to the newest hop; Natural covers the gap
        const int64_t newest = in16End / step - 1;
        if (newest - hop > (int64_t)(1.0 * kRate16 / step) + 1) {
            skipped.fetch_add(newest - hop);
            hop = newest;
            const int64_t m0 = hop * (int64_t)H * run->model->upp;
            toChain.reset();
            written = (int64_t)std::llround(m0 * rate / run->model->rate);
            std::fill(run->sola.begin(), run->sola.end(), 0.0f);
            lastGain = 0;
            outFinal.store(written, std::memory_order_release);
            outProv.store(written, std::memory_order_release);
        }
        while (!quit.load() && (hop + 1) * step <= in16End) {
            if (!makeHop((hop + 1) * H)) { hop++; break; }
            hop++;
            resampleNew();
        }
        // wake again when the next hop's sound is in (chain samples)
        wakeAt.store((int64_t)std::ceil(((hop + 1) * step + inLag16 + 1) * rate / kRate16), std::memory_order_release);
    }

    static void *threadMain(void *arg) {
        auto *s = (VoiceStream *)arg;
        pthread_setname_np("Pitch Shift AI voice");
        while (!s->quit.load()) {
            dispatch_semaphore_wait(s->wake, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC));
            if (s->quit.load()) break;
            @autoreleasepool { s->work(); }
        }
        return nullptr;
    }

    // -------------------------------------------------------------------------------------- sound thread side
    void push(const float *mic, int frames, const float *f0Hz, const int64_t *f0Pos, int n) {
        int64_t end = inEnd.load(std::memory_order_relaxed);
        if (mic) in.put(end, mic, frames);
        else for (int i = 0; i < frames; i++) in.buf[(size_t)((end + i) & in.mask)] = 0;
        int64_t pe = pitchEnd.load(std::memory_order_relaxed);
        for (int k = 0; k < n && f0Hz && f0Pos; k++) {
            pitchPos[(size_t)(pe % kPitchSlots)] = f0Pos[k];
            pitchHz[(size_t)(pe % kPitchSlots)] = f0Hz[k];
            pe++;
        }
        pitchEnd.store(pe, std::memory_order_release);
        inEnd.store(end + frames, std::memory_order_release);
        if (offline) {
            @autoreleasepool { work(); }
        } else if (end + frames >= wakeAt.load(std::memory_order_acquire)) {
            dispatch_semaphore_signal(wake);
        }
    }

    void pull(const float *naturalNow, int naturalDelay, float *outBuf, int frames) {
        const int64_t P = pulled;
        if (naturalNow) natural.put(P, naturalNow, frames);
        else for (int i = 0; i < frames; i++) natural.buf[(size_t)((P + i) & natural.mask)] = 0;
        const int64_t natBack = std::max<int64_t>(0, latency - std::max(0, naturalDelay));
        const int64_t fin = outFinal.load(std::memory_order_acquire);
        const int64_t prov = outProv.load(std::memory_order_acquire);
        const int64_t first = outStart.load(std::memory_order_acquire);
        const int64_t q0 = P - latency + aheadA;  // converted index for this callback's first sample
        const int64_t qEnd = q0 + frames;         // one past the last
        // Decide for the whole callback: play the AI voice when all of it is final and (when coming back) a ramp's
        // worth more is ready too; fall back when it is not final (a late hop: the provisional tail carries the fade).
        float target;
        if (loaded.load(std::memory_order_relaxed) && q0 >= first && qEnd <= fin && (mix > 0 || qEnd + rampLen <= fin)) {
            target = 1;
        } else {
            target = 0;
            if (playing && mix > 0 && !lateNow) { misses.fetch_add(1); lateNow = true; }
        }
        if (target == 1) lateNow = false;
        const float step = 1.0f / (float)rampLen;
        for (int i = 0; i < frames; i++) {
            const int64_t pos = P + i;
            const int64_t np = pos - natBack;
            const float nat = np >= 0 ? natural.at(np) : 0.0f;
            const int64_t q = q0 + i;
            float ai = 0;
            bool have = q >= first && q < prov;
            if (have) ai = out.at(q);
            if (target > mix) mix = std::min(1.0f, mix + step);
            else if (target < mix) mix = std::max(0.0f, mix - (have ? step : 4 * step));  // out of AI sound: hurry
            outBuf[i] = mix * ai + (1 - mix) * nat;
        }
        if (mix >= 1) playing = true;
        if (playing && mix < 1) fallbackFrames.fetch_add(frames);
        pulled = P + frames;
    }
};

extern "C" {

VoiceModel *voicemodel_load(const char *encoderPath, const char *voicePath, int computeUnits, char *err, int errSize) {
    if (!encoderPath || !voicePath) { say(err, errSize, "no model files"); return nullptr; }
    @autoreleasepool {
        double t0 = nowMs();
        auto *m = new VoiceModel();
        NSURL *encURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:encoderPath]];
        NSURL *voiceURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:voicePath]];
        int ue = computeUnits, uv = computeUnits;
        if (computeUnits == VOICEMODEL_COMPUTE_AUTO) { ue = VOICEMODEL_COMPUTE_ANE; uv = VOICEMODEL_COMPUTE_GPU; }
        auto open = [&](NSURL *url, int units) -> MLModel * {
            MLModelConfiguration *cfg = [MLModelConfiguration new];
            cfg.computeUnits = unitsFor(units);
            NSError *why = nil;
            return [MLModel modelWithContentsOfURL:url configuration:cfg error:&why];
        };
        m->encoder = open(encURL, ue);
        m->voice = open(voiceURL, uv);
        if ((!m->encoder || !m->voice) && (ue != VOICEMODEL_COMPUTE_CPU || uv != VOICEMODEL_COMPUTE_CPU)) {
            ue = uv = VOICEMODEL_COMPUTE_CPU;  // the CPU always works
            m->encoder = open(encURL, ue);
            m->voice = open(voiceURL, uv);
        }
        if (!m->encoder || !m->voice) {
            say(err, errSize, "the voice model files can't be opened");
            delete m;
            return nullptr;
        }
        m->unitsEncoder = ue;
        m->unitsVoice = uv;
        m->cpuOnly = ue == VOICEMODEL_COMPUTE_CPU && uv == VOICEMODEL_COMPUTE_CPU;
        // shapes and names
        MLModelDescription *ed = m->encoder.modelDescription, *vd = m->voice.modelDescription;
        NSArray<NSNumber *> *ein = ed.inputDescriptionsByName[@"audio"].multiArrayConstraint.shape;
        NSArray<NSNumber *> *eout = ed.outputDescriptionsByName[@"features"].multiArrayConstraint.shape;
        NSArray<NSNumber *> *vf = vd.inputDescriptionsByName[@"features"].multiArrayConstraint.shape;
        NSArray<NSNumber *> *vp = vd.inputDescriptionsByName[@"pitch"].multiArrayConstraint.shape;
        NSArray<NSNumber *> *vs = vd.inputDescriptionsByName[@"source"].multiArrayConstraint.shape;
        NSArray<NSNumber *> *vn = vd.inputDescriptionsByName[@"noise"].multiArrayConstraint.shape;
        NSArray<NSNumber *> *va = vd.outputDescriptionsByName[@"audio"].multiArrayConstraint.shape;
        if (ein.count != 2 || eout.count != 3 || vf.count != 3 || vp.count != 2 || vs.count != 3 || vn.count != 3 || va.count != 2 ||
            ![eout isEqualToArray:vf] || eout[2].intValue != kFeatureDim || vn[1].intValue != kNoiseChannels ||
            vs[2].intValue != va[1].intValue || ein[1].intValue != vp[1].intValue * kFrame16 ||
            vd.inputDescriptionsByName[@"pitch"].multiArrayConstraint.dataType != MLMultiArrayDataTypeInt32) {
            say(err, errSize, "the voice model files don't fit together");
            delete m;
            return nullptr;
        }
        m->encoderSamples = ein[1].intValue;
        m->featureFrames = eout[1].intValue;
        m->T = vp[1].intValue;
        m->decSamples = vs[2].intValue;
        m->flowFrames = vn[2].intValue;
        NSDictionary *meta = vd.metadata[MLModelCreatorDefinedKey];
        NSDictionary *emeta = ed.metadata[MLModelCreatorDefinedKey];
        m->rate = metaInt(meta, @"rate", 48000);
        m->upp = metaInt(meta, @"upp", m->rate / 100);
        m->hopMs = metaInt(meta, @"hop_ms", 160);
        m->contextMs = metaInt(meta, @"context_ms", metaInt(emeta, @"context_ms", 0));
        m->decFrames = metaInt(meta, @"dec_frames", m->decSamples / m->upp);
        m->xfadeMs = metaInt(meta, @"xfade_ms", 40);
        m->solaMs = metaInt(meta, @"sola_ms", 10);
        m->marginMs = metaInt(meta, @"margin_ms", m->decFrames * 10 - m->hopMs - m->xfadeMs - m->solaMs);
        if (m->contextMs <= 0) m->contextMs = m->T * 10 - m->hopMs - m->xfadeMs - m->solaMs;
        if (m->decFrames * m->upp != m->decSamples || m->flowFrames < m->decFrames || m->T < m->flowFrames ||
            m->decFrames * 10 < m->hopMs + m->xfadeMs + m->solaMs || m->rate != 48000) {
            say(err, errSize, "the voice model files have unexpected sizes");
            delete m;
            return nullptr;
        }
        m->loadMs = nowMs() - t0;
        // Warm up (macOS prepares the models for the chip on the first calls) and time a few hops.
        Runner r;
        if (!makeRunner(m, r)) { say(err, errSize, "out of memory"); delete m; return nullptr; }
        double tw = nowMs();
        for (int k = 0; k < 2; k++) {
            if (!predict(m->encoder, r.encoderIn, r.encoderOptions, @"features", r.features) ||
                !predict(m->voice, r.voiceIn, r.voiceOptions, @"audio", r.audioOut)) {
                say(err, errSize, "the voice model doesn't run");
                delete m;
                return nullptr;
            }
        }
        m->warmMs = nowMs() - tw;
        double tp = nowMs();
        for (int k = 0; k < 3; k++) {
            predict(m->encoder, r.encoderIn, r.encoderOptions, @"features", r.features);
            predict(m->voice, r.voiceIn, r.voiceOptions, @"audio", r.audioOut);
        }
        m->probeHopMs = (nowMs() - tp) / 3;
        char buf[256];
        std::snprintf(buf, sizeof buf, "encoder on %s, voice on %s; hop %d ms, past sound %d ms; one hop %.0f ms; ready in %.1f s",
                      unitsName(ue), unitsName(uv), m->hopMs, m->contextMs, m->probeHopMs, (nowMs() - t0) / 1000);
        m->describe = buf;
        return m;
    }
}

void voicemodel_free(VoiceModel *model) { delete model; }

const char *voicemodel_describe(const VoiceModel *model) { return model ? model->describe.c_str() : ""; }

VoiceStream *voicestream_new(VoiceModel *model, double chainRate, int maxFrames, int offline, const VoiceStreamConfig *config) {
    if (chainRate < 8000 || chainRate > 384000 || maxFrames <= 0) return nullptr;
    VoiceStreamConfig c = config ? *config : VoiceStreamConfig{160, 480, 40, 10, 60};
    if (model) { c.hopMs = model->hopMs; c.crossfadeMs = model->xfadeMs; c.solaMs = model->solaMs; }
    if (c.hopMs < 10 || c.hopMs % 10 || c.crossfadeMs % 10 || c.solaMs % 10 || c.crossfadeMs < 0 || c.solaMs < 0) return nullptr;
    auto *s = new VoiceStream();
    s->rate = chainRate;
    s->maxFrames = maxFrames;
    s->offline = offline != 0;
    s->H = c.hopMs / 10; s->X = c.crossfadeMs / 10; s->S = c.solaMs / 10;
    s->reserveMs = std::max(0, c.reserveMs);
    if (model && model->cpuOnly) s->reserveMs = std::max(s->reserveMs, 70);  // the CPU's slow hops need more room
    s->rampLen = std::max(1, (int)std::lrint(chainRate * 0.01));
    s->aheadA = (int64_t)std::llround((s->X + s->S) * chainRate / 100);
    s->inLag16 = Resampler::lag(kRate16 / chainRate);
    s->outLag = Resampler::lag(chainRate / 48000.0);
    // fixed delay = hop + crossfade + search + reserve + what the resamplers hold back + one callback
    s->latency = (int)std::llround((c.hopMs + c.crossfadeMs + c.solaMs + s->reserveMs) * chainRate / 1000)
               + (int)std::ceil(s->inLag16 * chainRate / kRate16) + (int)std::ceil(s->outLag) + std::min(maxFrames, (int)(chainRate * 0.011));
    if (s->offline) s->latency = (int)std::llround((c.hopMs + c.crossfadeMs + c.solaMs) * chainRate / 1000)
                               + (int)std::ceil(s->inLag16 * chainRate / kRate16) + (int)std::ceil(s->outLag) + 64;
    const int64_t ringSize = (int64_t)(chainRate * 4) + maxFrames;
    s->in.init(ringSize);
    s->out.init(ringSize);
    s->natural.init(s->latency + 4 * (int64_t)maxFrames + 64);
    s->in16.init((int64_t)kRate16 * 8);
    s->pitchPos.assign(kPitchSlots, 0);
    s->pitchHz.assign(kPitchSlots, 0.0f);
    s->scratch.assign(8192, 0.0f);
    if (!s->toModel.init(kRate16 / chainRate, 8192)) { delete s; return nullptr; }
    s->wake = dispatch_semaphore_create(0);
    if (model) s->pending.store(model);
    if (s->offline) {
        if (model) { s->pending.store(nullptr); s->adopt(model); }
        return s;
    }
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
    pthread_attr_setstacksize(&attr, 4 << 20);
    s->threadStarted = pthread_create(&s->thread, &attr, VoiceStream::threadMain, s) == 0;
    pthread_attr_destroy(&attr);
    if (!s->threadStarted) { delete s; return nullptr; }
    dispatch_semaphore_signal(s->wake);
    return s;
}

int voicestream_set_model(VoiceStream *stream, VoiceModel *model) {
    if (!stream || !model) return 0;
    if (model->hopMs != stream->H * 10 || model->xfadeMs != stream->X * 10 || model->solaMs != stream->S * 10) return 0;
    if (model->cpuOnly && stream->reserveMs < 70) return 0;  // its delay would be too short for the CPU: make a new stream
    if (stream->offline) { stream->adopt(model); return 1; }
    stream->pending.store(model);
    dispatch_semaphore_signal(stream->wake);
    return 1;
}

void voicestream_delete(VoiceStream *stream) {
    if (!stream) return;
    if (stream->threadStarted) {
        stream->quit.store(true);
        dispatch_semaphore_signal(stream->wake);
        pthread_join(stream->thread, nullptr);
    }
    delete stream->run;
    delete stream;
}

int voicestream_latency_frames(const VoiceStream *stream) { return stream ? stream->latency : 0; }

void voicestream_push(VoiceStream *stream, const float *mic, int frames, const float *f0Hz, const int64_t *f0Pos, int n) {
    if (stream && frames > 0) stream->push(mic, frames, f0Hz, f0Pos, n);
}

void voicestream_pull(VoiceStream *stream, const float *naturalNow, int naturalDelay, float *out, int frames) {
    if (!out || frames <= 0) return;
    if (!stream) {
        if (naturalNow && naturalNow != out) std::memcpy(out, naturalNow, sizeof(float) * (size_t)frames);
        return;
    }
    stream->pull(naturalNow, naturalDelay, out, frames);
}

int voicestream_tune(VoiceStream *stream, const char *key, float value) {
    if (!stream || !key) return 0;
    std::string k(key);
    if (k == "aiSlowMs") { stream->slowMs.store((int)value); return 1; }
    if (k == "aiSlowEvery") { stream->slowEvery.store(std::max(1, (int)value)); return 1; }
    if (k == "aiGainMaxDb") { stream->gainMaxDb.store(value); return 1; }
    return 0;
}

void voicestream_get_stats(const VoiceStream *stream, VoiceStreamStats *out) {
    if (!out) return;
    std::memset(out, 0, sizeof(*out));
    if (!stream) return;
    out->loaded = stream->loaded.load() && stream->playing ? 1 : 0;
    out->hops = stream->hops.load();
    out->misses = stream->misses.load();
    out->fallbackSeconds = stream->fallbackFrames.load() / stream->rate;
    out->averageHopMs = out->hops ? stream->sumHopMs.load() / (double)out->hops : 0;
    out->worstHopMs = stream->worstHopMs.load();
    out->cpuShare = stream->cpuShare.load();
}

}  // extern "C"

#else  // Intel Macs: the AI voices need Apple silicon.

extern "C" {

VoiceModel *voicemodel_load(const char *, const char *, int, char *err, int errSize) {
    say(err, errSize, "needs Apple silicon");
    return nullptr;
}

void voicemodel_free(VoiceModel *) {}
const char *voicemodel_describe(const VoiceModel *) { return ""; }
VoiceStream *voicestream_new(VoiceModel *, double, int, int, const VoiceStreamConfig *) { return nullptr; }
int voicestream_set_model(VoiceStream *, VoiceModel *) { return 0; }
void voicestream_delete(VoiceStream *) {}
int voicestream_latency_frames(const VoiceStream *) { return 0; }
void voicestream_push(VoiceStream *, const float *, int, const float *, const int64_t *, int) {}

void voicestream_pull(VoiceStream *, const float *naturalNow, int, float *out, int frames) {
    if (out && naturalNow && out != naturalNow && frames > 0) std::memcpy(out, naturalNow, sizeof(float) * (size_t)frames);
}

int voicestream_tune(VoiceStream *, const char *, float) { return 0; }

void voicestream_get_stats(const VoiceStream *, VoiceStreamStats *out) {
    if (out) std::memset(out, 0, sizeof(*out));
}

}  // extern "C"

#endif
