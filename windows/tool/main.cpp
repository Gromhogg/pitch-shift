// PitchShiftTool.exe <command> [options]
//   diag                      list sound devices and app sound sessions (JSON)
//   tonegen [--freq 440] [--amp 0.25] [--seconds 600] [--device "name"]
//                             play a test tone (to the default speakers unless --device)
//   probe [--out folder]      check how app volumes affect app recording (see probe.cpp)
//   restore [--file path]     put back app volumes that Pitch Shift lowered
//   set-default <playback|recording> "name"
//                             make a device the default (used by the GitHub checks)
//   selftest                  shift a made-up tone with Rubber Band and check the pitch
#include "tool/tool.h"

#include "dsp/analysis.h"
#include "dsp/music_shifter.h"
#include "win/com.h"
#include "win/devices.h"
#include "win/quiet.h"

#include <cmath>
#include <cstdio>
#include <iostream>

namespace ps::tool {

bool Args::has(const wchar_t* flag) const {
    for (const auto& a : items)
        if (a == flag) return true;
    return false;
}

std::wstring Args::get(const wchar_t* flag, const std::wstring& fallback) const {
    for (size_t i = 0; i + 1 < items.size(); ++i)
        if (items[i] == flag) return items[i + 1];
    return fallback;
}

double Args::number(const wchar_t* flag, double fallback) const {
    const auto text = get(flag);
    if (text.empty()) return fallback;
    try {
        return std::stod(text);
    } catch (...) {
        return fallback;
    }
}

std::wstring Args::positional(size_t index, const std::wstring& fallback) const {
    size_t seen = 0;
    for (size_t i = 1; i < items.size(); ++i) {
        if (items[i].rfind(L"--", 0) == 0) {
            ++i;  // skip the flag's value
            continue;
        }
        if (seen++ == index) return items[i];
    }
    return fallback;
}

void say(const std::string& line) {
    std::fwrite(line.data(), 1, line.size(), stdout);
    std::fputc('\n', stdout);
    std::fflush(stdout);
}

int restore(const Args& args) {
    ComScope com;
    const std::wstring file = args.get(L"--file", restore_file_path());
    const auto result = restore_all(file);
    say(nlohmann::json{{"restored", result.restored}, {"failed", result.failed}, {"pending", result.pending},
                       {"log", result.log}}
            .dump());
    return result.failed == 0 ? 0 : 1;
}

int set_default(const Args& args) {
    ComScope com;
    const std::wstring direction = args.positional(0);
    const std::wstring name = args.positional(1);
    const EDataFlow flow = direction == L"recording" ? eCapture : eRender;
    const auto endpoint = find_endpoint(flow, name);
    if (!endpoint) {
        say("No active device named like \"" + utf8(name) + "\".");
        return 1;
    }
    const HRESULT hr = set_default_endpoint_all(endpoint->id);
    say("Default " + utf8(direction) + " device -> " + utf8(endpoint->name) + ": " + hr_text(hr));
    return SUCCEEDED(hr) ? 0 : 1;
}

int selftest(const Args&) {
    const int rate = 48000;
    MusicShifter shifter(rate, 2, 2.0);
    const auto in = make_tone(440.0, 0.25, rate, 2, 4.0);
    std::vector<float> out;
    for (size_t i = 0; i < in.size() / 2; i += 480) shifter.process(in.data() + i * 2, 480, out);
    const auto left = take_channel(out, 2, 0);
    const size_t n = size_t(rate * 1.5);
    if (left.size() < n) {
        say("selftest: Rubber Band gave too little sound");
        return 1;
    }
    const auto m = measure_tone(left.data() + left.size() - n, n, rate, 493.88);
    const double expected = 440.0 * std::pow(2.0, 2.0 / 12);
    const bool ok = std::fabs(m.frequency - expected) < 0.5 && std::fabs(m.level_db - to_db(0.25)) < 1.0;
    say(nlohmann::json{{"selftest", ok ? "pass" : "fail"}, {"frequency", m.frequency}, {"expected", expected},
                       {"level_db", m.level_db}, {"thdn_db", m.thdn_db}}
            .dump());
    return ok ? 0 : 1;
}

}  // namespace ps::tool

int wmain(int argc, wchar_t** argv) {
    using namespace ps::tool;
    Args args;
    for (int i = 1; i < argc; ++i) args.items.emplace_back(argv[i]);
    const std::wstring command = args.items.empty() ? L"" : args.items[0];
    try {
        if (command == L"tonegen") return tonegen(args);
        if (command == L"diag") return diag(args);
        if (command == L"probe") return probe(args);
        if (command == L"restore") return restore(args);
        if (command == L"set-default") return set_default(args);
        if (command == L"selftest") return selftest(args);
    } catch (const std::exception& e) {
        say(std::string("Error: ") + e.what());
        return 2;
    }
    say("Usage: PitchShiftTool <diag|tonegen|probe|restore|set-default|selftest> [options]");
    return command.empty() ? 0 : 1;
}
