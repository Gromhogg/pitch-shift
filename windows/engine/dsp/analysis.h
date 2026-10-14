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

// Finds the tone near `expected_hz` (within about -20% / +25%) and measures it.
ToneMeasure measure_tone(const float* samples, size_t count, double rate, double expected_hz);

// Takes one channel out of interleaved sound (left = 0).
std::vector<float> take_channel(const std::vector<float>& interleaved, int channels, int which);

// Makes a sine tone: `channels` interleaved, `seconds` long.
std::vector<float> make_tone(double hz, double amplitude, double rate, int channels, double seconds);

}  // namespace ps
