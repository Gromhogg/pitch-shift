// Saves and loads sound as .wav files (32-bit float), so test recordings can be played on any computer.
#pragma once
#include <string>
#include <vector>

namespace ps {

struct WavData {
    std::vector<float> samples;  // interleaved
    int channels = 0;
    int rate = 0;
};

// `path` is UTF-8. Returns false if the file couldn't be written.
bool write_wav(const std::string& path, const float* interleaved, size_t frames, int channels, int rate);
bool write_wav(const std::string& path, const std::vector<float>& interleaved, int channels, int rate);

// Reads 32-bit float or 16-bit PCM files. Returns empty data if the file can't be read.
WavData read_wav(const std::string& path);

}  // namespace ps
