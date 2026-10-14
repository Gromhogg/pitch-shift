// A ring buffer of sound samples for one writer thread and one reader thread (no locks).
// Positions count samples since the start, so the reader can also look a little way back.
#pragma once
#include <algorithm>
#include <atomic>
#include <cstdint>
#include <vector>

namespace ps {

class SampleRing {
public:
    explicit SampleRing(size_t capacity) : data_(capacity) {}

    size_t capacity() const { return data_.size(); }
    uint64_t write_pos() const { return write_.load(std::memory_order_acquire); }
    uint64_t read_pos() const { return read_.load(std::memory_order_acquire); }
    size_t queued() const { return size_t(write_pos() - read_pos()); }

    // Writer: adds samples. The caller makes sure there's room.
    void write(const float* in, size_t n) {
        uint64_t w = write_.load(std::memory_order_relaxed);
        for (size_t i = 0; i < n; ++i) data_[(w + i) % data_.size()] = in[i];
        write_.store(w + n, std::memory_order_release);
    }

    // Reader: sample at an absolute position (must be written, and not overwritten yet).
    float at(uint64_t pos) const { return data_[pos % data_.size()]; }

    // Reader: copies n samples starting at the read position, then moves past them.
    void read(float* out, size_t n) {
        uint64_t r = read_.load(std::memory_order_relaxed);
        for (size_t i = 0; i < n; ++i) out[i] = data_[(r + i) % data_.size()];
        read_.store(r + n, std::memory_order_release);
    }

    void skip(size_t n) { read_.store(read_.load(std::memory_order_relaxed) + n, std::memory_order_release); }

    // Reader: forgets everything queued.
    void clear() { read_.store(write_.load(std::memory_order_acquire), std::memory_order_release); }

private:
    std::vector<float> data_;
    std::atomic<uint64_t> write_{0}, read_{0};
};

}  // namespace ps
