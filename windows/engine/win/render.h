// Plays 48 kHz stereo float sound to a speaker device (or the default one).
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
    // Fill `data` with `frames` frames of interleaved stereo sound. Called on the playing thread.
    using Source = std::function<void(float* data, size_t frames)>;

    // Empty endpoint_id = the current default speakers.
    static std::unique_ptr<Renderer> to_endpoint(const std::wstring& endpoint_id, Source source);

    ~Renderer();
    Renderer(const Renderer&) = delete;
    Renderer& operator=(const Renderer&) = delete;

    void stop();
    HRESULT error() const { return error_; }
    uint64_t frames() const { return frames_; }

private:
    Renderer(ComPtr<IAudioClient> client, Source source);
    void run();
    void fill(UINT32 frames);

    ComPtr<IAudioClient> client_;
    ComPtr<IAudioRenderClient> render_;
    HANDLE event_ = nullptr;
    UINT32 buffer_frames_ = 0;
    Source source_;
    std::thread thread_;
    std::atomic<bool> stop_{false};
    std::atomic<uint64_t> frames_{0};
    std::atomic<HRESULT> error_{S_OK};
};

}  // namespace ps
