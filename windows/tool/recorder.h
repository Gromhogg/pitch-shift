// Keeps the most recent recorded sound (up to a limit) so the checks can measure it.
#pragma once
#include <cstddef>
#include <mutex>
#include <vector>

namespace ps::tool {

class Recorder {
public:
    explicit Recorder(int channels = 2, double max_seconds = 20) : channels_(channels), max_seconds_(max_seconds) {}

    void add(const float* data, size_t frames) {
        std::lock_guard<std::mutex> lock(m_);
        buf_.insert(buf_.end(), data, data + frames * size_t(channels_));
        const size_t max = size_t(48000 * max_seconds_) * size_t(channels_);
        if (buf_.size() > max) buf_.erase(buf_.begin(), buf_.begin() + std::ptrdiff_t(buf_.size() - max));
    }
    void clear() {
        std::lock_guard<std::mutex> lock(m_);
        buf_.clear();
    }
    std::vector<float> take() {
        std::lock_guard<std::mutex> lock(m_);
        return buf_;
    }
    int channels() const { return channels_; }

private:
    int channels_;
    double max_seconds_;
    std::mutex m_;
    std::vector<float> buf_;
};

}  // namespace ps::tool
