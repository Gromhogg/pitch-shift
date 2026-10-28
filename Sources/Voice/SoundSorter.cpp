// 3.5: the AI voice's choice between its main and its second voice (see SoundSorter.h).
#include "SoundSorter.h"

#include <Accelerate/Accelerate.h>
#include <algorithm>
#include <cmath>
#include <cstring>

namespace soundsorter {

namespace {
const int kWin = 400, kHop = 160, kFft = 512, kSpec = kFft / 2 + 1;

// YAMNet class indices (yamnet_class_map.csv) of each group
const int kSpeech[] = {0, 1, 2, 3, 4, 12};              // speech, child speech, conversation, narration, babbling, whispering
const int kLaugh[] = {13, 14, 15, 16, 17, 18};          // laughter, baby laughter, giggle, snicker, belly laugh, chuckle
const int kHum[] = {32, 27, 28, 490};                   // humming, chant, mantra, hum
const int kSing[] = {24, 25, 26, 29, 249, 250};         // singing, choir, yodeling, child singing, vocal music, a capella
const int kBreath[] = {23, 36, 37, 38, 39, 40, 33, 34}; // sigh, breathing, wheeze, snoring, gasp, pant, groan, grunt
const int kCough[] = {42, 43, 44, 45, 54};              // cough, throat clearing, sneeze, sniff, hiccup
const int kWhistle[] = {35, 396};                       // whistling, whistle
const int kClick[] = {378, 380, 485, 354, 57, 58, 56, 353, 454, 486, 461};  // typing, keyboard, clicking, tap, snapping,
                                                        // clapping, hands, knock, thump, clickety-clack, slap
const int kScream[] = {6, 7, 8, 9, 11, 19, 21, 22};     // shout, bellow, whoop, yell, screaming, crying, whimper, wail

template <size_t N> float most(const float *s, const int (&ix)[N]) {
    float m = 0;
    for (int i : ix) m = std::max(m, s[i]);
    return m;
}
}  // namespace

const char *groupName(int g) {
    static const char *names[kGroups] = {"speech", "laugh", "hum", "sing", "breath", "cough", "whistle", "click", "scream"};
    return g >= 0 && g < kGroups ? names[g] : "?";
}

void groupScores(const float *s, float *g) {
    g[Speech] = most(s, kSpeech);
    g[Laugh] = most(s, kLaugh);
    g[Hum] = most(s, kHum);
    g[Sing] = most(s, kSing);
    g[Breath] = most(s, kBreath);
    g[Cough] = most(s, kCough);
    g[Whistle] = most(s, kWhistle);
    g[Click] = most(s, kClick);
    g[Scream] = most(s, kScream);
}

struct LogMel::Impl {
    FFTSetup fft = nullptr;
    std::vector<float> hann, frame, re, im, mag, mel, lifted;  // mel: kSpec x kBands
};

LogMel::LogMel() : p(new Impl) {
    p->fft = vDSP_create_fftsetup(9, kFFTRadix2);  // 2^9 = 512
    p->hann.resize(kWin);
    for (int i = 0; i < kWin; i++) p->hann[(size_t)i] = (float)(0.5 - 0.5 * std::cos(2 * M_PI * i / kWin));  // periodic
    p->frame.assign(kFft, 0.0f);
    p->re.assign(kFft / 2, 0.0f);
    p->im.assign(kFft / 2, 0.0f);
    p->mag.assign(kSpec, 0.0f);
    p->lifted.assign(kWindow, 0.0f);
    // tf.signal.linear_to_mel_weight_matrix(64, 257, 16000, 125, 7500): HTK mel, triangles in mel, the DC row zero
    auto mel = [](double f) { return 1127.0 * std::log(1.0 + f / 700.0); };
    const double lo = mel(125.0), hi = mel(7500.0);
    p->mel.assign((size_t)kSpec * kBands, 0.0f);
    for (int k = 1; k < kSpec; k++) {
        const double m = mel(8000.0 * k / (kSpec - 1));
        for (int b = 0; b < kBands; b++) {
            const double l = lo + (hi - lo) * b / (kBands + 1), c = lo + (hi - lo) * (b + 1) / (kBands + 1),
                         u = lo + (hi - lo) * (b + 2) / (kBands + 1);
            const double w = std::max(0.0, std::min((m - l) / (c - l), (u - m) / (u - c)));
            p->mel[(size_t)k * kBands + b] = (float)w;
        }
    }
}

LogMel::~LogMel() {
    if (p->fft) vDSP_destroy_fftsetup(p->fft);
    delete p;
}

float LogMel::run(const float *x, float *patch, float levelDb, float maxLiftDb) {
    // the loudest 10 ms (non-overlapping 160-sample frames)
    float loud = 0;
    for (int s = 0; s + kHop <= kWindow; s += kHop) {
        float e = 0;
        vDSP_svesq(x + s, 1, &e, kHop);
        loud = std::max(loud, e / kHop);
    }
    const float loudDb = 10 * std::log10(loud + 1e-12f);
    const float g = std::pow(10.0f, std::min(maxLiftDb, levelDb - loudDb) / 20);
    vDSP_vsmul(x, 1, &g, p->lifted.data(), 1, kWindow);
    const float *y = p->lifted.data();
    DSPSplitComplex z{p->re.data(), p->im.data()};
    for (int f = 0; f < kFrames; f++) {
        std::fill(p->frame.begin(), p->frame.end(), 0.0f);
        vDSP_vmul(y + f * kHop, 1, p->hann.data(), 1, p->frame.data(), 1, kWin);
        vDSP_ctoz((const DSPComplex *)p->frame.data(), 2, &z, 1, kFft / 2);
        vDSP_fft_zrip(p->fft, &z, 1, 9, kFFTDirection_Forward);
        // vDSP's packed real FFT is 2x the true DFT; DC in re[0], Nyquist in im[0]
        p->mag[0] = std::fabs(p->re[0]) * 0.5f;
        p->mag[kSpec - 1] = std::fabs(p->im[0]) * 0.5f;
        for (int k = 1; k < kFft / 2; k++) p->mag[(size_t)k] = 0.5f * std::sqrt(p->re[(size_t)k] * p->re[(size_t)k] + p->im[(size_t)k] * p->im[(size_t)k]);
        float *out = patch + (size_t)f * kBands;
        // mel = mag (1 x 257) . W (257 x 64)
        vDSP_mmul(p->mag.data(), 1, p->mel.data(), 1, out, 1, 1, kBands, kSpec);
        for (int b = 0; b < kBands; b++) out[b] = std::log(out[b] + 0.001f);
    }
    return loudDb;
}

int Rule::decide(const Features &f, const char **why) {
    const float *g = f.group;
    const char *reason = "main";
    bool want = false, hold = false;
    if (f.loudDb < quietMaxDb || (f.voiced == 0 && f.loudDb < f.floorDb + quietDb)) {
        hold = true;
        reason = "quiet: keep";
    } else if (g[Click] > clickMax) {
        reason = "click";
    } else if (g[Scream] > screamMax) {
        reason = "scream";
    } else {
        float other = std::max({g[Laugh], g[Hum], g[Sing], g[Breath]});
        if (coughs > 0.5f) other = std::max(other, g[Cough]);
        if (whistles > 0.5f) other = std::max(other, g[Whistle]);
        const float noteShare = f.voiced > 0 ? (float)f.note / (float)f.voiced : 0;
        const float voicedShare = f.frames > 0 ? (float)f.voiced / (float)f.frames : 0;
        const bool tune = f.voiced >= tuneMin && voicedShare >= tuneVoiced && noteShare >= tuneNote;
        const bool sung = f.sung * 2 > f.frames;
        if (other >= enter && g[Speech] < speechMax) {
            want = true;
            reason = "sorter";
        } else if (tune && (g[Speech] < tuneSpeechMax || (sung && g[Speech] < tuneSungSpeechMax))) {
            want = true;
            reason = "tune";
        } else {
            reason = g[Speech] >= speechMax ? "speech" : "unsure";
        }
    }
    if (!hold) {
        if (want) { runOn++; runOff = 0; }
        else { runOff++; runOn = 0; }
    }
    dwell++;
    if (!on && want && runOn >= (int)enterHops) {
        on = true;
        dwell = 0;
    } else if (on && !want && !hold && ((runOff >= (int)exitHops && dwell >= (int)minHops) || g[Speech] >= speechExit ||
                                        g[Click] > clickMax)) {
        on = false;
        dwell = 0;
    }
    if (why) *why = reason;
    return on ? 1 : 0;
}

bool Rule::tune(const std::string &k, float v) {
    struct Item { const char *name; float Rule::*field; };
    static const Item items[] = {
        {"svEnter", &Rule::enter}, {"svSpeechMax", &Rule::speechMax}, {"svCoughs", &Rule::coughs},
        {"svWhistles", &Rule::whistles}, {"svClickMax", &Rule::clickMax}, {"svScreamMax", &Rule::screamMax},
        {"svTuneNote", &Rule::tuneNote}, {"svTuneVoiced", &Rule::tuneVoiced}, {"svTuneMin", &Rule::tuneMin},
        {"svTuneSpeechMax", &Rule::tuneSpeechMax}, {"svTuneSungSpeechMax", &Rule::tuneSungSpeechMax},
        {"svQuietDb", &Rule::quietDb}, {"svQuietMaxDb", &Rule::quietMaxDb}, {"svEnterHops", &Rule::enterHops}, {"svExitHops", &Rule::exitHops},
        {"svMinHops", &Rule::minHops}, {"svSpeechExit", &Rule::speechExit},
    };
    for (const Item &it : items)
        if (k == it.name) { this->*it.field = v; return true; }
    return false;
}

}  // namespace soundsorter
