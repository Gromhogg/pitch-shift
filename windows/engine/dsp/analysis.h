// Measures a test tone: its pitch, how loud it is, and how clean it is.
// Used by the checks that run on GitHub (there is no Windows PC to listen on).
#pragma once
#include <cstddef>
#include <vector>

namespace ps {

struct ToneMeasure {
    double frequency = 0;     // Hz
    double level_db = -200;   // loudness of the tone itself, dB below full scale (0 dB = peak of 1.0)
    double rms_db = -200;     // loudness of everything, dB below full scale (a full-scale tone is -3 dB)
    double thdn_db = 0;       // everything that isn't the tone, compared to the tone (lower = cleaner)
    double peak = 0;          // largest sample
    size_t frames = 0;
};

// Converts an amplitude to dB (1.0 -> 0 dB). Silence gives -200.
double to_db(double amplitude);

// The amplitude of a tone at exactly `hz` (a best-fit sine).
double tone_amplitude(const float* samples, size_t count, double rate, double hz);

// The amplitude of a faint tone at exactly `hz` next to much louder tones. tone_amplitude() cuts the sound off
// sharply at both ends, which spills a little of every other tone onto `hz`: a loud tone 54 Hz away shows up at
// up to 1 / (pi x 54 Hz x seconds) of its level (-51 dB in 2 s). This uses a smooth (Hann) window instead, which
// keeps that spill more than 120 dB down, so a tone 60 dB below a loud one reads 60 dB below it.
double faint_tone_amplitude(const float* samples, size_t count, double rate, double hz);

// The level of a steady tone at `hz`, measured in short pieces (Hann window each, so other tones don't leak in).
// `level_db` is the middle value of the pieces: a one-off hiccup (a few ms of sound lost on the way, or the tone's
// timing jumping once) only changes a piece or two. One best-fit sine over the whole recording drops by up to a few
// dB after such a jump, because the parts before and after it no longer line up.
struct SteadyLevel {
    double level_db = -200;   // middle value of the pieces
    double lowest_db = -200;  // the quietest piece
    double highest_db = -200; // the loudest piece
    size_t pieces = 0;
};
SteadyLevel steady_level(const float* samples, size_t count, double rate, double hz, double piece_seconds = 0.1);

// Finds the tone near `expected_hz` (within about -20% / +25%) and measures it.
ToneMeasure measure_tone(const float* samples, size_t count, double rate, double expected_hz);

// The pitch of a steady tone near `expected_hz`: the middle value of measure_tone's pitch in `piece_seconds` pieces.
// A one-off hiccup only throws off its own piece (over a whole recording it can move the pitch by up to 1 Hz).
double steady_frequency(const float* samples, size_t count, double rate, double expected_hz, double piece_seconds = 0.5);

// Takes one channel out of interleaved sound (left = 0).
std::vector<float> take_channel(const std::vector<float>& interleaved, int channels, int which);

// Makes a sine tone: `channels` interleaved, `seconds` long.
std::vector<float> make_tone(double hz, double amplitude, double rate, int channels, double seconds);

// Makes a voice-like "aah" (one channel): buzz at pitch f0 shaped by mouth resonances at 700, 1220
// and 2600 Hz. Used to check that Natural keeps those resonances and Cartoon moves them.
std::vector<float> make_vowel(double f0, double rate, double seconds, double amplitude = 0.3);

// A made-up song (2 channels, interleaved) for checks that need music rather than a tone: kick, snare, hi-hat,
// a bass line (44-98 Hz), chords, a tune and a little hiss above 7 kHz. 120 beats per minute, peaks at -3 dBFS,
// exactly the same every time.
std::vector<float> make_test_song(double rate, double seconds);

// The "center of gravity" of the sound's spectrum between lo and hi Hz.
double spectral_centroid(const float* samples, size_t count, double rate, double lo_hz, double hi_hz);

// The pitch (fundamental) of a voice-like sound, between lo and hi Hz. 0 if none found.
double estimate_f0(const float* samples, size_t count, double rate, double lo_hz, double hi_hz);

// When a tone starts: the first time (seconds) its level at `hz` (in 10 ms steps) rises above
// `threshold_db`, at or after `from_s`. Negative if never.
double onset_time(const float* samples, size_t count, double rate, double hz, double threshold_db, double from_s = 0);

}  // namespace ps
