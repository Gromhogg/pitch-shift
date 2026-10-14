// Plays 48 kHz float sound to a speaker device.
#pragma once
#include "win/capture.h"

#include <atomic>
#include <functional>
#include <memory>
#include <string>
#include <thread>

namespace ps {

class Renderer {
public:
    // Fill `data` with `frames` frames of interleaved sound. Called on the playing thread.
    using Source = std::function<void(float* data, size_t frames)>;

    // The current default speakers, following Windows when the default changes (for example when
    // headphones are plugged in), so nothing needs rebuilding.
    static std::unique_ptr<Renderer> to_default(Source source, int channels = kChannels);
    // One device, by endpoint id. Empty id = the default speakers right now (doesn't follow changes).
    static std::unique_ptr<Renderer> to_endpoint(const std::wstring& endpoint_id, Source source, int channels = kChannels);

    ~Renderer();
    Renderer(const Renderer&) = delete;
    Renderer& operator=(const Renderer&) = delete;

    void stop();
    HRESULT error() const { return error_; }
    uint64_t frames() const { return frames_; }
    double buffer_ms() const { return buffer_frames_ * 1000.0 / kRate; }
    double latency_ms() const;  // what Windows says the stream adds

private:
    Renderer(ComPtr<IAudioClient> client, Source source, int channels);
    void run();
    void fill(UINT32 frames);

    ComPtr<IAudioClient> client_;
    ComPtr<IAudioRenderClient> render_;
    HANDLE event_ = nullptr;
    UINT32 buffer_frames_ = 0;
    int channels_;
    Source source_;
    std::thread thread_;
    std::atomic<bool> stop_{false};
    std::atomic<uint64_t> frames_{0};
    std::atomic<HRESULT> error_{S_OK};
};

}  // namespace ps
