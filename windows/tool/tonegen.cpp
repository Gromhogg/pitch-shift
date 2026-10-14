// tonegen: plays a steady test tone, like a music app would. The checks record it and measure it.
#include "tool/tool.h"

#include "win/devices.h"
#include "win/render.h"

#include <chrono>
#include <cmath>
#include <thread>

namespace ps::tool {

int tonegen(const Args& args) {
    ComScope com;
    const double freq = args.number(L"--freq", 440.0);
    const double amp = args.number(L"--amp", 0.25);
    const double seconds = args.number(L"--seconds", 600.0);
    const std::wstring device_name = args.get(L"--device");

    std::wstring endpoint_id;
    if (!device_name.empty()) {
        const auto e = find_endpoint(eRender, device_name);
        if (!e) {
            say("tonegen: no playback device named like \"" + utf8(device_name) + "\"");
            return 1;
        }
        endpoint_id = e->id;
    }

    double phase = 0;
    const double step = 2 * 3.14159265358979323846 * freq / kRate;
    auto renderer = Renderer::to_endpoint(endpoint_id, [&](float* out, size_t frames) {
        for (size_t i = 0; i < frames; ++i) {
            const float v = float(amp * std::sin(phase));
            phase += step;
            if (phase > 2 * 3.14159265358979323846) phase -= 2 * 3.14159265358979323846;
            for (int c = 0; c < kChannels; ++c) out[i * kChannels + size_t(c)] = v;
        }
    });
    say("tonegen: pid " + std::to_string(GetCurrentProcessId()) + ", " + std::to_string(freq) + " Hz");

    const auto end = std::chrono::steady_clock::now() + std::chrono::duration<double>(seconds);
    while (std::chrono::steady_clock::now() < end) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        if (FAILED(renderer->error())) {
            say("tonegen: playing stopped: " + hr_text(renderer->error()));
            return 3;
        }
    }
    renderer->stop();
    return 0;
}

}  // namespace ps::tool
