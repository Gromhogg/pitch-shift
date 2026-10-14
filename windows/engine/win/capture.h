// Records sound as 48 kHz stereo float: either the sound one app (and its child processes) is
// playing ("process loopback"), everything except one app, or a recording device like a microphone.
#pragma once
#include "win/com.h"

#include <audioclient.h>
#include <mmreg.h>

#include <atomic>
#include <functional>
#include <memory>
#include <string>
#include <thread>

namespace ps {

constexpr int kRate = 48000;
constexpr int kChannels = 2;

// 32-bit float, interleaved.
WAVEFORMATEX float_format(int rate = kRate, int channels = kChannels);

class Capture {
public:
    // Called on the recording thread with `frames` frames of interleaved sound (2 channels unless asked).
    using Sink = std::function<void(const float* data, size_t frames)>;

    // The sound of process `pid` and its children (include_tree = true),
    // or everything except that process and its children (include_tree = false).
    static std::unique_ptr<Capture> from_process(DWORD pid, bool include_tree, Sink sink);
    // A recording device (microphone, "CABLE Output", ...), by endpoint id. Windows converts it to
    // 48 kHz with `channels` channels.
    static std::unique_ptr<Capture> from_endpoint(const std::wstring& endpoint_id, Sink sink, int channels = kChannels);

    ~Capture();
    Capture(const Capture&) = delete;
    Capture& operator=(const Capture&) = delete;

    void stop();

    struct Stats {
        uint64_t frames = 0;
        uint64_t packets = 0;
        uint64_t silent_packets = 0;  // packets Windows marked as silence
        uint64_t gaps = 0;            // packets Windows marked as "something was lost before this"
        HRESULT error = S_OK;         // why recording stopped early, if it did
    };
    Stats stats() const;

    int channels() const { return channels_; }

private:
    Capture(ComPtr<IAudioClient> client, Sink sink, const char* what, int channels);
    void run();

    ComPtr<IAudioClient> client_;
    ComPtr<IAudioCaptureClient> capture_;
    HANDLE event_ = nullptr;
    int channels_ = kChannels;
    Sink sink_;
    std::thread thread_;
    std::atomic<bool> stop_{false};
    std::atomic<uint64_t> frames_{0}, packets_{0}, silent_{0}, gaps_{0};
    std::atomic<HRESULT> error_{S_OK};
};

// Waits for ActivateAudioInterfaceAsync and returns the IAudioClient it made.
// `device` is VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK or a device interface path; `params` may be null.
ComPtr<IAudioClient> activate_audio_client(const wchar_t* device, PROPVARIANT* params);

}  // namespace ps
