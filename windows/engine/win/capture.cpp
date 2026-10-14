#include "win/capture.h"

#include "win/devices.h"

#include <avrt.h>
#include <mmdeviceapi.h>

#include <vector>

#if __has_include(<audioclientactivationparams.h>)
#include <audioclientactivationparams.h>
#else
// Copies of the Windows SDK definitions, for compilers whose headers don't have them yet (MinGW).
typedef enum AUDIOCLIENT_ACTIVATION_TYPE {
    AUDIOCLIENT_ACTIVATION_TYPE_DEFAULT = 0,
    AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK = 1
} AUDIOCLIENT_ACTIVATION_TYPE;
typedef enum PROCESS_LOOPBACK_MODE {
    PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE = 0,
    PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE = 1
} PROCESS_LOOPBACK_MODE;
typedef struct AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS {
    DWORD TargetProcessId;
    PROCESS_LOOPBACK_MODE ProcessLoopbackMode;
} AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS;
typedef struct AUDIOCLIENT_ACTIVATION_PARAMS {
    AUDIOCLIENT_ACTIVATION_TYPE ActivationType;
    union {
        AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS ProcessLoopbackParams;
    };
} AUDIOCLIENT_ACTIVATION_PARAMS;
#define VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK L"VAD\\Process_Loopback"
#endif

namespace ps {

WAVEFORMATEX float_format(int rate, int channels) {
    WAVEFORMATEX f{};
    f.wFormatTag = WAVE_FORMAT_IEEE_FLOAT;
    f.nChannels = WORD(channels);
    f.nSamplesPerSec = DWORD(rate);
    f.wBitsPerSample = 32;
    f.nBlockAlign = WORD(channels * 4);
    f.nAvgBytesPerSec = DWORD(rate * channels * 4);
    f.cbSize = 0;
    return f;
}

namespace {

// Gets told when Windows has finished setting up the sound connection we asked for.
// It must be "agile" (callable from any thread), which IAgileObject tells Windows.
class ActivationWaiter final : public IActivateAudioInterfaceCompletionHandler, public IAgileObject {
public:
    ActivationWaiter() : done_(CreateEventW(nullptr, TRUE, FALSE, nullptr)) {}

    STDMETHODIMP QueryInterface(REFIID riid, void** out) override {
        if (!out) return E_POINTER;
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IActivateAudioInterfaceCompletionHandler)) {
            *out = static_cast<IActivateAudioInterfaceCompletionHandler*>(this);
        } else if (riid == __uuidof(IAgileObject)) {
            *out = static_cast<IAgileObject*>(this);
        } else {
            *out = nullptr;
            return E_NOINTERFACE;
        }
        AddRef();
        return S_OK;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return ULONG(InterlockedIncrement(&refs_)); }
    STDMETHODIMP_(ULONG) Release() override {
        const LONG left = InterlockedDecrement(&refs_);
        if (left == 0) delete this;
        return ULONG(left);
    }
    STDMETHODIMP ActivateCompleted(IActivateAudioInterfaceAsyncOperation*) override {
        SetEvent(done_);
        return S_OK;
    }
    bool wait(DWORD ms) { return WaitForSingleObject(done_, ms) == WAIT_OBJECT_0; }

private:
    ~ActivationWaiter() { CloseHandle(done_); }
    LONG refs_ = 1;
    HANDLE done_;
};

}  // namespace

ComPtr<IAudioClient> activate_audio_client(const wchar_t* device, PROPVARIANT* params) {
    auto* waiter = new ActivationWaiter();
    ComPtr<IActivateAudioInterfaceAsyncOperation> operation;
    HRESULT hr = ActivateAudioInterfaceAsync(device, __uuidof(IAudioClient), params, waiter, &operation);
    if (FAILED(hr)) {
        waiter->Release();
        throw WinError("ActivateAudioInterfaceAsync", hr);
    }
    const bool finished = waiter->wait(10000);
    waiter->Release();
    if (!finished) throw WinError("ActivateAudioInterfaceAsync (no answer)", HRESULT_FROM_WIN32(ERROR_TIMEOUT));
    HRESULT result = E_FAIL;
    ComPtr<IUnknown> unknown;
    check(operation->GetActivateResult(&result, &unknown), "GetActivateResult");
    check(result, "Activate audio interface");
    ComPtr<IAudioClient> client;
    check(unknown.As(&client), "IAudioClient");
    return client;
}

std::unique_ptr<Capture> Capture::from_process(DWORD pid, bool include_tree, Sink sink) {
    AUDIOCLIENT_ACTIVATION_PARAMS params{};
    params.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
    params.ProcessLoopbackParams.TargetProcessId = pid;
    params.ProcessLoopbackParams.ProcessLoopbackMode =
        include_tree ? PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE : PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE;
    PROPVARIANT pv{};
    pv.vt = VT_BLOB;
    pv.blob.cbSize = sizeof(params);
    pv.blob.pBlobData = reinterpret_cast<BYTE*>(&params);
    auto client = activate_audio_client(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, &pv);

    // The process-loopback "device" has no format of its own; we ask for 48 kHz stereo float and
    // Windows converts to it.
    WAVEFORMATEX format = float_format();
    check(client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                             AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
                                 AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM,
                             200000 /* 20 ms */, 0, &format, nullptr),
          "Start app recording (Initialize)");
    return std::unique_ptr<Capture>(new Capture(client, std::move(sink), "app recording", kChannels));
}

std::unique_ptr<Capture> Capture::from_endpoint(const std::wstring& endpoint_id, Sink sink, int channels) {
    auto device = device_by_id(endpoint_id);
    ComPtr<IAudioClient> client;
    check(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                           reinterpret_cast<void**>(client.GetAddressOf())),
          "Open recording device");
    WAVEFORMATEX format = float_format(kRate, channels);
    check(client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                             AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                                 AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                             1000000 /* 100 ms */, 0, &format, nullptr),
          "Start recording (Initialize)");
    return std::unique_ptr<Capture>(new Capture(client, std::move(sink), "recording", channels));
}

Capture::Capture(ComPtr<IAudioClient> client, Sink sink, const char* what, int channels)
    : client_(std::move(client)), channels_(channels), sink_(std::move(sink)) {
    event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    check(client_->SetEventHandle(event_), (std::string(what) + " (SetEventHandle)").c_str());
    check(client_->GetService(__uuidof(IAudioCaptureClient), reinterpret_cast<void**>(capture_.GetAddressOf())),
          (std::string(what) + " (GetService)").c_str());
    check(client_->Start(), (std::string(what) + " (Start)").c_str());
    thread_ = std::thread([this] { run(); });
}

Capture::~Capture() {
    stop();
    if (event_) CloseHandle(event_);
}

void Capture::stop() {
    if (thread_.joinable()) {
        stop_ = true;
        SetEvent(event_);
        thread_.join();
    }
    if (client_) client_->Stop();
}

Capture::Stats Capture::stats() const {
    Stats s;
    s.frames = frames_;
    s.packets = packets_;
    s.silent_packets = silent_;
    s.gaps = gaps_;
    s.error = error_;
    return s;
}

void Capture::run() {
    ComScope com;
    DWORD task_index = 0;
    HANDLE task = AvSetMmThreadCharacteristicsW(L"Pro Audio", &task_index);
    std::vector<float> zeros;
    while (!stop_) {
        WaitForSingleObject(event_, 100);
        if (stop_) break;
        // Read every packet that's waiting (also when the wake-up signal didn't come).
        for (;;) {
            UINT32 next = 0;
            HRESULT hr = capture_->GetNextPacketSize(&next);
            if (FAILED(hr)) {
                error_ = hr;
                stop_ = true;
                break;
            }
            if (next == 0) break;
            BYTE* data = nullptr;
            UINT32 frames = 0;
            DWORD flags = 0;
            hr = capture_->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
            if (FAILED(hr)) {
                error_ = hr;
                stop_ = true;
                break;
            }
            ++packets_;
            if (flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) ++gaps_;
            const float* samples = reinterpret_cast<const float*>(data);
            if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) || !data) {
                ++silent_;
                zeros.assign(size_t(frames) * size_t(channels_), 0.0f);
                samples = zeros.data();
            }
            if (frames > 0 && sink_) sink_(samples, frames);
            frames_ += frames;
            capture_->ReleaseBuffer(frames);
        }
    }
    if (task) AvRevertMmThreadCharacteristics(task);
}

}  // namespace ps
