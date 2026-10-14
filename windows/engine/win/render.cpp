#include "win/render.h"

#include "win/devices.h"

#include <avrt.h>

namespace ps {

namespace {
// "The default speakers" as a device name for ActivateAudioInterfaceAsync (DEVINTERFACE_AUDIO_RENDER).
// Streams opened this way move by themselves when the default changes.
const wchar_t* kDefaultRender = L"{E6327CAD-DCEC-4949-AE8A-991E976A79D2}";

void initialize(IAudioClient* client, int channels) {
    WAVEFORMATEX format = float_format(kRate, channels);
    check(client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                             AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                                 AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                             300000 /* 30 ms */, 0, &format, nullptr),
          "Start playing (Initialize)");
}
}  // namespace

std::unique_ptr<Renderer> Renderer::to_default(Source source, int channels) {
    auto client = activate_audio_client(kDefaultRender, nullptr);
    initialize(client.Get(), channels);
    return std::unique_ptr<Renderer>(new Renderer(client, std::move(source), channels));
}

std::unique_ptr<Renderer> Renderer::to_endpoint(const std::wstring& endpoint_id, Source source, int channels) {
    ComPtr<IMMDevice> device;
    if (endpoint_id.empty()) {
        check(device_enumerator()->GetDefaultAudioEndpoint(eRender, eConsole, &device), "No speakers found");
    } else {
        device = device_by_id(endpoint_id);
    }
    ComPtr<IAudioClient> client;
    check(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(client.GetAddressOf())),
          "Open speakers");
    initialize(client.Get(), channels);
    return std::unique_ptr<Renderer>(new Renderer(client, std::move(source), channels));
}

Renderer::Renderer(ComPtr<IAudioClient> client, Source source, int channels)
    : client_(std::move(client)), channels_(channels), source_(std::move(source)) {
    event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    check(client_->SetEventHandle(event_), "Start playing (SetEventHandle)");
    check(client_->GetBufferSize(&buffer_frames_), "Start playing (GetBufferSize)");
    check(client_->GetService(__uuidof(IAudioRenderClient), reinterpret_cast<void**>(render_.GetAddressOf())),
          "Start playing (GetService)");
    fill(buffer_frames_);  // start with a full buffer (of silence, usually) so there's no click
    check(client_->Start(), "Start playing (Start)");
    thread_ = std::thread([this] { run(); });
}

Renderer::~Renderer() {
    stop();
    if (event_) CloseHandle(event_);
}

double Renderer::latency_ms() const {
    REFERENCE_TIME latency = 0;
    if (FAILED(client_->GetStreamLatency(&latency))) return 0;
    return double(latency) / 10000.0;
}

void Renderer::stop() {
    if (thread_.joinable()) {
        stop_ = true;
        SetEvent(event_);
        thread_.join();
    }
    if (client_) client_->Stop();
}

void Renderer::fill(UINT32 frames) {
    if (frames == 0) return;
    BYTE* data = nullptr;
    const HRESULT hr = render_->GetBuffer(frames, &data);
    if (FAILED(hr)) {
        error_ = hr;
        return;
    }
    source_(reinterpret_cast<float*>(data), frames);
    render_->ReleaseBuffer(frames, 0);
    frames_ += frames;
}

void Renderer::run() {
    ComScope com;
    DWORD task_index = 0;
    HANDLE task = AvSetMmThreadCharacteristicsW(L"Pro Audio", &task_index);
    while (!stop_) {
        WaitForSingleObject(event_, 100);
        if (stop_) break;
        UINT32 padding = 0;
        const HRESULT hr = client_->GetCurrentPadding(&padding);
        if (FAILED(hr)) {
            error_ = hr;  // for example, the speakers were unplugged
            break;
        }
        if (padding == 0) ++starved_;  // everything was played before we came back: Windows filled in silence
        fill(buffer_frames_ - padding);
        if (FAILED(error_.load())) break;
    }
    if (task) AvRevertMmThreadCharacteristics(task);
}

}  // namespace ps
