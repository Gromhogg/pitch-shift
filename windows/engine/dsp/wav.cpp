#include "dsp/wav.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>

namespace ps {

namespace {
void put16(std::string& s, uint16_t v) { s.append(reinterpret_cast<const char*>(&v), 2); }
void put32(std::string& s, uint32_t v) { s.append(reinterpret_cast<const char*>(&v), 4); }

std::filesystem::path to_path(const std::string& utf8) {
    return std::filesystem::path(std::u8string(utf8.begin(), utf8.end()));
}
}  // namespace

bool write_wav(const std::string& path, const float* data, size_t frames, int channels, int rate) {
    const uint32_t bytes = uint32_t(frames * size_t(channels) * sizeof(float));
    std::string h;
    h += "RIFF";
    put32(h, 4 + (8 + 18) + (8 + 4) + (8 + bytes));
    h += "WAVE";
    h += "fmt ";
    put32(h, 18);
    put16(h, 3);  // 32-bit float
    put16(h, uint16_t(channels));
    put32(h, uint32_t(rate));
    put32(h, uint32_t(rate * channels * 4));
    put16(h, uint16_t(channels * 4));
    put16(h, 32);
    put16(h, 0);
    h += "fact";
    put32(h, 4);
    put32(h, uint32_t(frames));
    h += "data";
    put32(h, bytes);
    std::ofstream f(to_path(path), std::ios::binary);
    if (!f) return false;
    f.write(h.data(), std::streamsize(h.size()));
    f.write(reinterpret_cast<const char*>(data), std::streamsize(bytes));
    return bool(f);
}

bool write_wav(const std::string& path, const std::vector<float>& interleaved, int channels, int rate) {
    if (channels <= 0) return false;
    return write_wav(path, interleaved.data(), interleaved.size() / size_t(channels), channels, rate);
}

WavData read_wav(const std::string& path) {
    WavData out;
    std::ifstream f(to_path(path), std::ios::binary);
    if (!f) return out;
    std::string all((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    if (all.size() < 12 || all.compare(0, 4, "RIFF") != 0 || all.compare(8, 4, "WAVE") != 0) return out;
    uint16_t format = 0, channels = 0, bits = 0;
    uint32_t rate = 0;
    size_t pos = 12;
    while (pos + 8 <= all.size()) {
        uint32_t size = 0;
        std::memcpy(&size, all.data() + pos + 4, 4);
        const std::string id = all.substr(pos, 4);
        const size_t body = pos + 8;
        if (body + size > all.size()) size = uint32_t(all.size() - body);
        if (id == "fmt " && size >= 16) {
            std::memcpy(&format, all.data() + body, 2);
            std::memcpy(&channels, all.data() + body + 2, 2);
            std::memcpy(&rate, all.data() + body + 4, 4);
            std::memcpy(&bits, all.data() + body + 14, 2);
            if (format == 0xFFFE && size >= 26) std::memcpy(&format, all.data() + body + 24, 2);  // extensible
        } else if (id == "data" && channels > 0) {
            if (format == 3 && bits == 32) {
                out.samples.resize(size / 4);
                std::memcpy(out.samples.data(), all.data() + body, out.samples.size() * 4);
            } else if (format == 1 && bits == 16) {
                out.samples.resize(size / 2);
                for (size_t i = 0; i < out.samples.size(); ++i) {
                    int16_t v;
                    std::memcpy(&v, all.data() + body + i * 2, 2);
                    out.samples[i] = float(v) / 32768.0f;
                }
            } else {
                return {};
            }
            out.channels = channels;
            out.rate = int(rate);
            return out;
        }
        pos = body + size + (size & 1);
    }
    return {};
}

}  // namespace ps
