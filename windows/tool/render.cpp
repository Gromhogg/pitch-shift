// Offline commands (no sound devices needed):
//   make-song --out song.wav [--seconds 20]
//       writes a made-up song (drums, bass, chords, a tune, a little hiss) for checks that need music
//   render-file IN OUT [--steps 8] [--advanced] [--steps-at "4:8,8:-5"]
//       shifts a WAV file with the same code as live (normal mode or Advanced processing), like the Mac app's
//       --render-file: the output lines up with the input and has the same length, so the two can be compared.
#include "tool/tool.h"

#include "dsp/advanced_shifter.h"
#include "dsp/analysis.h"
#include "dsp/wav.h"
#include "win/com.h"

#include <chrono>
#include <nlohmann/json.hpp>
#include <sstream>

namespace ps::tool {

int make_song(const Args& args) {
    const std::wstring out = args.get(L"--out", L"song.wav");
    const double seconds = args.number(L"--seconds", 20);
    const int rate = 48000;
    const auto song = make_test_song(rate, seconds);
    if (!write_wav(utf8(out), song, 2, rate)) {
        say("make-song: could not write " + utf8(out));
        return 1;
    }
    say("make-song: wrote " + utf8(out) + " (" + std::to_string(seconds) + " s)");
    return 0;
}

int render_file(const Args& args) {
    const std::wstring in_path = args.positional(0), out_path = args.positional(1);
    if (in_path.empty() || out_path.empty()) {
        say("Usage: render-file IN OUT [--steps 8] [--advanced] [--steps-at \"4:8,8:-5\"]");
        return 1;
    }
    const double steps = args.number(L"--steps", 0);
    const bool advanced = args.has(L"--advanced");
    // "4:8,8:-5" -> at 4 s go to +8, at 8 s go to -5
    std::vector<std::pair<double, double>> changes;
    std::stringstream list(utf8(args.get(L"--steps-at")));
    std::string item;
    while (std::getline(list, item, ',')) {
        const auto colon = item.find(':');
        if (colon == std::string::npos) continue;
        try {
            changes.emplace_back(std::stod(item.substr(0, colon)), std::stod(item.substr(colon + 1)));
        } catch (...) {
        }
    }
    const auto in = read_wav(utf8(in_path));
    if (in.channels == 0 || in.samples.empty()) {
        say("render-file: could not read " + utf8(in_path) + " (32-bit float or 16-bit WAV)");
        return 1;
    }
    const auto start = std::chrono::steady_clock::now();
    const auto out = render_offline(in.samples, in.channels, in.rate, steps, advanced, changes);
    const double took = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    if (out.empty() || !write_wav(utf8(out_path), out, 2, in.rate)) {
        say("render-file: could not shift or write " + utf8(out_path));
        return 1;
    }
    const double seconds = double(in.samples.size() / size_t(in.channels)) / in.rate;
    say(nlohmann::json{{"render", utf8(out_path)},
                       {"steps", steps},
                       {"advanced", advanced},
                       {"seconds", seconds},
                       {"took_seconds", took},
                       {"times_real_time", took > 0 ? seconds / took : 0}}
            .dump());
    return 0;
}

}  // namespace ps::tool
