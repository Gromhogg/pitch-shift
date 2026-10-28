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
    float loudDb = -120;        // the window's loudest 10 ms (dBFS)
    float floorDb = -120;       // the room's noise (dBFS)
    int voiced = 0, frames = 0; // voiced frames / frames known, around the piece
    int note = 0;               // voiced frames that are note-like (a held or sung note, a hum)
    int sung = 0;               // frames inside a sung passage (VoiceChanger's singOn)
    float rangeSt = 0;          // spread of the voiced frames' pitch (10-90 %, half-steps)
};

// The rule, with hysteresis. Tune keys ("sv..."), see SoundSorter.cpp.
class Rule {
public:
    // One piece: 1 = the second voice, 0 = the main voice. `why` (may be null) gets a short reason for traces.
    int decide(const Features &f, const char **why = nullptr);
    void reset() { on = false; runOn = runOff = dwell = 0; }
    bool tune(const std::string &key, float value);
    bool isOn() const { return on; }
    // settings
    float enter = 0.45f;        // a non-speech group this sure (laughs, hums, singing, sighs/breaths) ...
    float speechMax = 0.3f;     // ... while speech is below this
    float coughs = 1;           // 1 = coughs and sneezes count as non-speech too (lower priority: 0 = never)
    float whistles = 0;         // 1 = whistles go to the second voice (0: the main voice / the original, SoundGate)
    float clickMax = 0.3f;      // clicks, claps, typing above this: never the second voice
    float screamMax = 0.5f;     // shouting, screaming, crying above this: the main voice
    float tuneNote = 0.6f;      // a hum or hummed tune by the pitch alone: this share of the voiced frames note-like ...
    float tuneVoiced = 0.35f;   // ... at least this share of the frames voiced ...
    float tuneMin = 30;         // ... and at least this many voiced frames
    float tuneSpeechMax = 0.5f; // ... while speech is below this (a hummed tune reads as speech to YAMNet: see below)
    float tuneSungSpeechMax = 1.01f;  // ... or below this inside a sung passage (VoiceChanger's 2 s rule)
    float quietDb = 8;          // no voice and less than this above the room's noise, ...
    float quietMaxDb = -60;     // ... or quieter than this (dBFS): keep the choice (silence decides nothing)
    float enterHops = 1, exitHops = 1, minHops = 2;  // pieces in a row to switch; pieces to stay at least
    float speechExit = 0.6f;    // speech this sure: back to the main voice at once
private:
    bool on = false;
    int runOn = 0, runOff = 0, dwell = 0;
};

}  // namespace soundsorter
#endif
#endif
