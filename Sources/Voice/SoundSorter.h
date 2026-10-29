// 3.5: the AI voice's choice, piece by piece, between its main voice (speech, and anything in doubt) and its second
// voice (hums, hummed tunes, singing, laughs, sighs, breaths; coughs and sneezes), made on the AI worker thread from
//   - YAMNet's sound classes (Google, Apache-2.0; the network runs with Core ML in VoiceModel.mm, its log-mel front
//     end is here) over the 0.975 s of sound up to the newest (so it hears the piece and what comes after it), and
//   - the voice changer's pitch frames (VoiceChanger.h VOICECHANGER_FRAME_*): how much of it is voiced and note-like.
// Clicks, claps, typing never go to the second voice (they stay the main voice, or pass as they are: SoundGate.h).
// Plain C++17 (Accelerate for the FFT), no Core ML here, so it can be tested on its own. Everything is made in the
// constructor; run/decide make no memory and take no locks.
#ifndef SOUND_SORTER_H
#define SOUND_SORTER_H

#ifdef __cplusplus
#include <cstdint>
#include <string>
#include <vector>

namespace soundsorter {

constexpr int kRate = 16000;
constexpr int kWindow = 15600;       // samples in one patch: 96 frames of 25 ms, hop 10 ms (0.975 s)
constexpr int kFrames = 96, kBands = 64, kClasses = 521;
// The sorter file's own small head (one layer on YAMNet's 1024 embedding values, trained on free recordings: speech,
// laughs, breaths and sighs, coughs and sneezes, hums, singing, whistles, other sounds): output "classes", softmax.
enum Head { HSpeech, HLaugh, HSigh, HBody, HHum, HSing, HWhistle, HOther, kHead };

enum Group { Speech, Laugh, Hum, Sing, Breath, Cough, Whistle, Click, Scream, kGroups };
const char *groupName(int g);

// YAMNet's front end: tf.signal.stft magnitude (periodic Hann 400, hop 160, FFT 512), linear_to_mel_weight_matrix
// (64 bands, 125-7500 Hz, HTK mel), log(mel + 0.001). The window is first lifted so its loudest 10 ms sits at
// `levelDb` (at most `maxLiftDb`): a quiet mic hums and laughs like a loud one.
class LogMel {
public:
    LogMel();
    ~LogMel();
    LogMel(const LogMel &) = delete;
    LogMel &operator=(const LogMel &) = delete;
    // x: kWindow samples. patch: kFrames * kBands values (frame by frame). Returns the window's loudest 10 ms (dBFS).
    float run(const float *x, float *patch, float levelDb = -20, float maxLiftDb = 30);
private:
    struct Impl;
    Impl *p;
};

// The largest score of each group's classes (YAMNet's 521 sigmoid scores in, kGroups values out).
void groupScores(const float *scores, float *groups);

// What one piece's decision looks at.
struct Features {
    float group[kGroups] = {};  // YAMNet group scores (0 = none: no sorter)
    float head[kHead] = {};     // the head's probabilities (all 0 = the sorter file has no head)
    bool hasHead = false;
    float loudDb = -120;        // the window's loudest 10 ms (dBFS)
    float floorDb = -120;       // the room's noise (dBFS)
    int voiced = 0, frames = 0; // voiced frames / frames known, around the piece
    int note = 0;               // voiced frames that are note-like (a held or sung note, a hum)
    int sung = 0;               // frames inside a sung passage (VoiceChanger's singOn)
    float rangeSt = 0;          // spread of the voiced frames' pitch (10-90 %, half-steps)
};

// The rule, with hysteresis (the same rule replayed offline: research/voicechanger/second/tools/simrule.py).
// Into the second voice when the sorter is sure of a laugh, a hum or singing, of a breath / sigh / cough for two
// pieces in a row (speech nearly absent), or when the pitch is note-like (a hum or hummed tune: YAMNet hears a quiet
// hummed tune as speech, so the pitch decides it); out again as soon as none holds (after two pieces at least), at
// once when speech is sure, and never for clicks, claps, typing, shouting or crying. Silence keeps the choice.
class Rule {
public:
    // One piece: 1 = the second voice, 0 = the main voice. `why` (may be null) gets a short reason for traces.
    int decide(const Features &f, const char **why = nullptr);
    void reset() { on = false; runBreath = runOff = dwell = runUnvoiced = 0; }
    bool tune(const std::string &key, float value);
    bool isOn() const { return on; }
    // settings ("sv..." tune keys)
    float laugh = 0.35f, laughSpeech = 0.35f;   // laughter this sure while speech is below that
    float hum = 0.2f, humSpeech = 0.3f;         // humming / singing
    float breath = 0.6f, breathSpeech = 0.1f;   // a breath, sigh, gasp (or a cough / sneeze) ...
    float breathHops = 2;                       // ... for this many pieces in a row
    float coughs = 1;           // 1 = coughs and sneezes count with breaths (lower priority: 0 = never)
    float whistles = 0, whistle = 0.5f;         // 1 = whistles too (0: they stay the main voice / pass as they are)
    float clickMax = 0.3f;      // clicks, claps, typing above this: never the second voice
    float screamMax = 0.5f;     // shouting, screaming, crying above this: the main voice
    float tuneEnter = 0.55f;    // a hum / hummed tune by the pitch: this share of the voiced frames note-like ...
    float tuneMin = 30;         // ... with at least this many voiced frames (speech stays below 0.48 on every set)
    float tuneStay = 0.3f, tuneStayMin = 20;    // ... and once in, it stays while this holds
    float quietDb = 8;          // no voice and less than this above the room's noise, ...
    float quietMaxDb = -60;     // ... or quieter than this (dBFS): keep the choice (silence decides nothing)
    float exitHops = 3, minHops = 2;  // pieces with nothing to stay for; pieces to stay at least
    float speechExit = 0.6f;    // speech this sure (YAMNet; the head's speech when there is a head): back at once
    float headEnter = 0.7f;     // the head: laugh + sigh + hum + singing (+ coughs) this sure ...
    float headSpeech = 0.2f;    // ... and speech below this: the second voice
    float headExit = 0.4f;      // ... and speech this sure: back to the main voice at once
    float useHead = 1;          // 0 = ignore the head
    float headMaxVoiced = 25;   // the head alone: at most this many voiced frames (of ~98) ...
    float headNote = 0.3f;      // ... or this share of them note-like ...
    float headYamSpeech = 0;    // ... or YAMNet's speech below this (0: no); and always YAMNet's speech below
    float headYamMax = 0.9f;
    float unvoicedHops = 3;     // a piece with no voiced frame: only after this many sure breaths in a row
    float tuneSpeech = 1.01f;   // without a head: a tune by its pitch alone below this YAMNet speech score
private:
    bool on = false;
    int runBreath = 0, runOff = 0, dwell = 0, runUnvoiced = 0;
};

}  // namespace soundsorter
#endif
#endif
