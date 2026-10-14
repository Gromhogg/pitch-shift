// record: records from a recording device into a WAV file, like a call app using the microphone.
#include "tool/tool.h"

#include "dsp/wav.h"
#include "tool/recorder.h"
#include "win/capture.h"
#include "win/devices.h"

#include <chrono>
#include <thread>

namespace ps::tool {

int record(const Args& args) {
    ComScope com;
    const std::wstring device = args.get(L"--device", L"CABLE Output");
    const double seconds = args.number(L"--seconds", 5);
    const int channels = int(args.number(L"--channels", 1));
    const std::wstring out = args.get(L"--out", L"record.wav");
    std::wstring id = device;
    if (device.rfind(L"{", 0) != 0) {
        const auto e = find_endpoint(eCapture, device);
        if (!e) {
            say("record: no recording device named like \"" + utf8(device) + "\"");
            return 1;
        }
        id = e->id;
    }
    Recorder rec(channels, seconds + 1);
    auto capture = Capture::from_endpoint(id, [&](const float* d, size_t n) { rec.add(d, n); }, channels);
    say("record: pid " + std::to_string(GetCurrentProcessId()) + ", " + std::to_string(seconds) + " s");
    std::this_thread::sleep_for(std::chrono::duration<double>(seconds));
    capture->stop();
    const auto data = rec.take();
    write_wav(utf8(out), data, channels, kRate);
    say("record: saved " + std::to_string(data.size() / size_t(channels)) + " frames");
    return 0;
}

}  // namespace ps::tool
