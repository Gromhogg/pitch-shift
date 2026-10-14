// End-to-end checks on a real Windows sound system, with VB-CABLE standing in for the speakers
// and for the call app's microphone. Each writes a JSON report (and WAV recordings) to --out.
//   e2e-music: a 440 Hz test player shifted +2 comes out at 493.9 Hz, the original is 50+ dB
//              quieter, the level stays within 1 dB; also 0 (bypass), stop, a child process,
//              All sound with two tones, the total delay, and 60 s without dropouts.
//   e2e-advanced: "Advanced processing": 440 Hz at +8, -5 and +15 lands on the right pitch, a bass note at +8
//              lands an octave lower than a plain shift would put it, switching on and off, the total delay
//              (at most 0.8 s), quick amount changes, and 60 s without dropouts.
//   e2e-voice: a made-up voice through the voice path into the cable: pitch, Natural vs Cartoon,
//              runs only while a "call app" records, and the Test button.
//   e2e-crash: the app is ended suddenly while an app is quiet: the watchdog puts it back,
//              also when the quiet app had quit too.
#include "tool/tool.h"

#include "dsp/analysis.h"
#include "dsp/wav.h"
#include "tool/recorder.h"
#include "win/apps.h"
#include "win/cable.h"
#include "win/capture.h"
#include "win/devices.h"
#include "win/mic_default.h"
#include "win/music.h"
#include "win/process.h"
#include "win/quiet.h"
#include "win/sessions.h"
#include "win/voice.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <optional>
#include <thread>

namespace ps::tool {

namespace fs = std::filesystem;
using json = nlohmann::json;

namespace {

void sleep_s(double seconds) { std::this_thread::sleep_for(std::chrono::duration<double>(seconds)); }

double round3(double v) { return std::round(v * 1000) / 1000; }

class Report {
public:
    explicit Report(fs::path out) : out_(std::move(out)) {
        std::error_code ec;
        fs::create_directories(out_, ec);
        j_ = {{"checks", json::object()}, {"info", json::object()}, {"notes", json::array()}};
        j_["os"] = os_text();
        j_["machine"] = machine_arch();
    }
    void check(const std::string& name, bool pass, json value, const std::string& meaning) {
        if (value.is_number_float()) value = round3(value.get<double>());
        say(std::string(pass ? "  PASS " : "  FAIL ") + name + " = " + value.dump() + "  (" + meaning + ")");
        j_["checks"][name] = {{"pass", pass}, {"value", value}, {"meaning", meaning}};
        if (!pass) ++failures_;
    }
    void info(const std::string& name, json value, const std::string& meaning = "") {
        if (value.is_number_float()) value = round3(value.get<double>());
        say("  INFO " + name + " = " + value.dump() + (meaning.empty() ? "" : "  (" + meaning + ")"));
        j_["info"][name] = value;
    }
    void note(const std::string& text) {
        say("  note: " + text);
        j_["notes"].push_back(text);
    }
    void wav(const std::string& name, const std::vector<float>& data, int channels) {
        write_wav((out_ / (name + ".wav")).string(), data, channels, kRate);
    }
    int finish(const std::string& file) {
        j_["failures"] = failures_;
        std::ofstream f(out_ / file, std::ios::binary);
        f << j_.dump(2);
        say(failures_ == 0 ? "All checks passed." : std::to_string(failures_) + " check(s) failed.");
        return failures_ == 0 ? 0 : 1;
    }
    const fs::path& out() const { return out_; }
    json& data() { return j_; }

private:
    fs::path out_;
    json j_;
    int failures_ = 0;
};

// Listens to what reaches the cable's recording side (the stand-in for the speakers).
class CableEar {
public:
    explicit CableEar(const std::wstring& id, double max_seconds = 20) : rec_(2, max_seconds) {
        cap_ = Capture::from_endpoint(id, [this](const float* d, size_t n) { rec_.add(d, n); });
    }
    std::vector<float> listen(double seconds) {
        rec_.clear();
        sleep_s(seconds);
        return rec_.take();
    }

private:
    Recorder rec_;
    std::unique_ptr<Capture> cap_;
};

std::vector<float> left_of(const std::vector<float>& stereo) { return take_channel(stereo, 2, 0); }

double level_at(const std::vector<float>& mono, double hz) {
    return to_db(tone_amplitude(mono.data(), mono.size(), kRate, hz));
}

// Test players are started so they don't count as our own processes (like a real music app).
std::unique_ptr<ChildProcess> start_player(const std::wstring& args, Report& report) {
    try {
        return start_detached(self_path(), L"tonegen " + args, parent_pid_of(GetCurrentProcessId()));
    } catch (const std::exception& e) {
        report.note(std::string("could not start the player outside our own processes: ") + e.what());
        return start_process(self_path(), L"tonegen " + args);
    }
}

std::optional<Session> wait_session(DWORD pid, double seconds = 15) {
    const auto end = std::chrono::steady_clock::now() + std::chrono::duration<double>(seconds);
    while (std::chrono::steady_clock::now() < end) {
        for (auto& s : sessions_of(pid))
            if (s.state == AudioSessionStateActive) return s;
        sleep_s(0.1);
    }
    return std::nullopt;
}

std::vector<float> volumes_of(DWORD pid) {
    for (auto& s : sessions_of(pid))
        if (s.state != AudioSessionStateExpired) return channel_volumes(s.channel_volume().Get());
    return {};
}

bool all_equal(const std::vector<float>& v, float x) {
    if (v.empty()) return false;
    for (float f : v)
        if (std::fabs(f - x) > x * 0.01f + 1e-6f) return false;
    return true;
}

bool wait_volumes(DWORD pid, float x, double seconds) {
    const auto end = std::chrono::steady_clock::now() + std::chrono::duration<double>(seconds);
    while (std::chrono::steady_clock::now() < end) {
        if (all_equal(volumes_of(pid), x)) return true;
        sleep_s(0.1);
    }
    return false;
}

bool wait_music_state(MusicPath& music, const std::string& state, double seconds) {
    const auto end = std::chrono::steady_clock::now() + std::chrono::duration<double>(seconds);
    while (std::chrono::steady_clock::now() < end) {
        if (music.status()["state"] == state) return true;
        sleep_s(0.1);
    }
    return false;
}

// The child player (not the console helper "conhost.exe" Windows may start next to it).
DWORD child_of(DWORD parent) {
    const ProcessSnapshot snap;
    const std::wstring player = lower(file_name_of(self_path()));
    for (DWORD pid : snap.tree(parent)) {
        const auto* p = snap.find(pid);
        if (pid != parent && p && p->exe_name == player) return pid;
    }
    return 0;
}

struct CableIds {
    std::wstring input, output;
};

std::optional<CableIds> cable_ids(Report& report) {
    const auto cable = find_cable();
    if (!cable.present) {
        report.note("VB-CABLE is not installed, so there's nothing to measure.");
        return std::nullopt;
    }
    if (default_endpoint_id(eRender, eConsole) != cable.feed_id) set_default_endpoint_all(cable.feed_id);
    return CableIds{cable.feed_id, cable.mic_id};
}

}  // namespace

// ---------------- e2e-music ----------------

int e2e_music(const Args& args) {
    ComScope com;
    Report r(args.get(L"--out", L"e2e-out"));
    const auto ids = cable_ids(r);
    if (!ids) return r.finish("e2e_music.json") + 2;
    const double long_seconds = args.number(L"--seconds", 60);
    CableEar ear(ids->output, long_seconds + 5);
    MusicPath music((r.out() / L"restore.json").wstring(), L"");
    const double target = 440.0 * std::pow(2.0, 2.0 / 12);

    // ---- A. One app, +2.
    say("A. one app, +2 half-steps");
    auto a = start_player(L"--freq 440 --amp 0.25 --seconds 900", r);
    if (!wait_session(a->pid())) r.note("player A's sound never showed up");
    sleep_s(1.0);
    const auto base_left = left_of(ear.listen(2.0));
    const auto base = measure_tone(base_left.data(), base_left.size(), kRate, 440.0);
    r.info("baseline_level_db", base.level_db, "the player's tone at the cable before shifting");
    music.set_semitones(2);
    music.start_pid(a->pid());
    const bool started = wait_music_state(music, "running", 10);
    r.check("app_running", started, music.status()["state"], "the path starts");
    sleep_s(2.0);  // let Rubber Band and the cushion settle
    {
        const auto rec = ear.listen(3.0);
        const auto left = left_of(rec);
        const auto m = measure_tone(left.data(), left.size(), kRate, target);
        const double original = level_at(left, 440.0);
        r.check("app_pitch_hz", std::fabs(m.frequency - target) < 0.5, m.frequency, "440 Hz +2 = 493.9 Hz");
        r.check("app_level_change_db", std::fabs(m.level_db - base.level_db) <= 1.0, m.level_db - base.level_db,
                "shifted tone is as loud as the original (within 1 dB)");
        r.check("app_original_down_db", m.level_db - original >= 50, m.level_db - original,
                "the original is at least 50 dB quieter than the shifted tone");
        r.check("app_quieted", all_equal(volumes_of(a->pid()), kQuietLevel), volumes_of(a->pid()),
                "the player's hidden volume is 0.001");
        r.info("app_thdn_db", m.thdn_db);
        const std::string speaker = music.status().value("speaker", "");
        r.check("status_speaker", speaker.find("CABLE") != std::string::npos, speaker,
                "the status names the speakers it plays to (here the cable)");
        r.wav("music_app_plus2", rec, 2);
    }

    // ---- B. 0 half-steps skips Rubber Band.
    say("B. 0 half-steps");
    music.set_semitones(0);
    sleep_s(1.5);
    {
        const auto left = left_of(ear.listen(2.0));
        const auto m = measure_tone(left.data(), left.size(), kRate, 440.0);
        r.check("zero_pitch_hz", std::fabs(m.frequency - 440.0) < 0.5, m.frequency, "at 0 the pitch is unchanged");
        r.check("zero_level_change_db", std::fabs(m.level_db - base.level_db) <= 0.5, m.level_db - base.level_db,
                "at 0 the level is unchanged");
    }

    // ---- C. Off puts the volume back.
    say("C. switch off");
    music.stop();
    wait_music_state(music, "off", 5);
    r.check("stop_restores_volume", wait_volumes(a->pid(), 1.0f, 3), volumes_of(a->pid()),
            "switching off puts the player's volume back");
    {
        const auto left = left_of(ear.listen(1.5));
        const auto m = measure_tone(left.data(), left.size(), kRate, 440.0);
        r.check("stop_level_change_db", std::fabs(m.level_db - base.level_db) <= 0.3, m.level_db - base.level_db,
                "the original plays normally again");
    }
    a->kill();

    // ---- D. An app whose sound comes from a child process (like a browser).
    say("D. sound from a child process");
    auto p = start_player(L"--freq 440 --amp 0.25 --seconds 900 --spawn-child", r);
    DWORD child = 0;
    for (int i = 0; i < 100 && !child; ++i) {
        sleep_s(0.1);
        child = child_of(p->pid());
    }
    r.info("child_pid", child);
    if (!child || !wait_session(child)) r.note("the child player's sound never showed up");
    music.set_semitones(2);
    music.start_pid(p->pid());
    wait_music_state(music, "running", 10);
    sleep_s(2.0);
    {
        const auto rec = ear.listen(3.0);
        const auto left = left_of(rec);
        const auto m = measure_tone(left.data(), left.size(), kRate, target);
        const double original = level_at(left, 440.0);
        r.check("child_pitch_hz", std::fabs(m.frequency - target) < 0.5, m.frequency, "the child's sound is shifted");
        r.check("child_level_change_db", std::fabs(m.level_db - base.level_db) <= 1.0, m.level_db - base.level_db,
                "same level");
        r.check("child_original_down_db", m.level_db - original >= 50, m.level_db - original,
                "the child's original is 50+ dB quieter");
        r.wav("music_child_plus2", rec, 2);
    }
    music.stop();
    wait_music_state(music, "off", 5);
    r.check("child_restored", wait_volumes(child, 1.0f, 3), volumes_of(child), "the child's volume comes back");
    // End the parent and its child (a leftover player would spoil the next checks).
    for (DWORD pid : ProcessSnapshot().tree(p->pid())) {
        if (HANDLE h = OpenProcess(PROCESS_TERMINATE, FALSE, pid)) {
            TerminateProcess(h, 9);
            CloseHandle(h);
        }
    }
    p->kill();

    // ---- E. All sound, two players.
    say("E. all sound, two players");
    auto t1 = start_player(L"--freq 440 --amp 0.25 --seconds 900", r);
    auto t2 = start_player(L"--freq 660 --amp 0.25 --seconds 900", r);
    wait_session(t1->pid());
    wait_session(t2->pid());
    music.set_semitones(2);
    music.start_all();
    wait_music_state(music, "running", 10);
    sleep_s(2.5);
    {
        const auto rec = ear.listen(3.0);
        const auto left = left_of(rec);
        const double target2 = 660.0 * std::pow(2.0, 2.0 / 12);
        const auto m1 = measure_tone(left.data(), left.size(), kRate, target);
        const auto m2 = measure_tone(left.data(), left.size(), kRate, target2);
        const double o1 = level_at(left, 440.0), o2 = level_at(left, 660.0);
        r.check("all_pitch1_hz", std::fabs(m1.frequency - target) < 0.5, m1.frequency, "440 -> 493.9 Hz");
        r.check("all_pitch2_hz", std::fabs(m2.frequency - target2) < 0.5, m2.frequency, "660 -> 740.0 Hz");
        r.check("all_level1_change_db", std::fabs(m1.level_db - base.level_db) <= 1.0, m1.level_db - base.level_db, "");
        r.check("all_level2_change_db", std::fabs(m2.level_db - base.level_db) <= 1.0, m2.level_db - base.level_db, "");
        r.check("all_original1_down_db", m1.level_db - o1 >= 45, m1.level_db - o1,
                "45+ dB here: with two tones, Rubber Band's own faint by-products (about -60 dB) sit at that pitch too");
        r.check("all_original2_down_db", m2.level_db - o2 >= 45, m2.level_db - o2,
                "45+ dB here: with two tones, Rubber Band's own faint by-products (about -60 dB) sit at that pitch too");
        r.wav("music_all_plus2", rec, 2);
    }
    music.stop();
    wait_music_state(music, "off", 5);
    r.check("all_restored", wait_volumes(t1->pid(), 1.0f, 3) && wait_volumes(t2->pid(), 1.0f, 3),
            json::array({volumes_of(t1->pid()), volumes_of(t2->pid())}), "both players come back");

    // ---- E2. Two ticked apps (each recorded on its own, then mixed).
    say("E2. two ticked apps");
    music.set_semitones(2);
    music.start_pids({t1->pid(), t2->pid()});
    wait_music_state(music, "running", 10);
    sleep_s(2.5);
    {
        const auto rec = ear.listen(3.0);
        const auto left = left_of(rec);
        const double target2 = 660.0 * std::pow(2.0, 2.0 / 12);
        const auto m1 = measure_tone(left.data(), left.size(), kRate, target);
        const auto m2 = measure_tone(left.data(), left.size(), kRate, target2);
        const double o1 = level_at(left, 440.0), o2 = level_at(left, 660.0);
        r.check("two_apps_pitch1_hz", std::fabs(m1.frequency - target) < 0.5, m1.frequency, "first app 440 -> 493.9 Hz");
        r.check("two_apps_pitch2_hz", std::fabs(m2.frequency - target2) < 0.5, m2.frequency, "second app 660 -> 740.0 Hz");
        r.check("two_apps_level1_change_db", std::fabs(m1.level_db - base.level_db) <= 1.0, m1.level_db - base.level_db, "");
        r.check("two_apps_level2_change_db", std::fabs(m2.level_db - base.level_db) <= 1.0, m2.level_db - base.level_db, "");
        r.check("two_apps_original1_down_db", m1.level_db - o1 >= 45, m1.level_db - o1,
                "45+ dB here: with two tones, Rubber Band's own faint by-products (about -60 dB) sit at that pitch too");
        r.check("two_apps_original2_down_db", m2.level_db - o2 >= 45, m2.level_db - o2,
                "45+ dB here: with two tones, Rubber Band's own faint by-products (about -60 dB) sit at that pitch too");
        r.wav("music_two_apps_plus2", rec, 2);
    }
    music.stop();
    wait_music_state(music, "off", 5);
    r.check("two_apps_restored", wait_volumes(t1->pid(), 1.0f, 3) && wait_volumes(t2->pid(), 1.0f, 3),
            json::array({volumes_of(t1->pid()), volumes_of(t2->pid())}), "both apps come back");
    t1->kill();
    t2->kill();

    // ---- H. A ticked app that isn't open yet joins when it starts (and again after a restart).
    say("H. ticked app opens later");
    {
        wchar_t long_temp[MAX_PATH * 2];
        const DWORD long_len = GetLongPathNameW(fs::temp_directory_path().c_str(), long_temp, MAX_PATH * 2);
        const fs::path temp = long_len ? fs::path(std::wstring(long_temp, long_len)) : fs::temp_directory_path();
        const fs::path fake = temp / L"FakePlayer.exe";
        std::error_code ec;
        fs::copy_file(self_path(), fake, fs::copy_options::overwrite_existing, ec);
        music.set_semitones(2);
        music.start_apps({fake.wstring()});
        sleep_s(1.0);
        const auto waiting = music.status();
        r.check("later_app_waits", waiting["state"] == "waiting" && waiting["apps"].size() == 1 &&
                                       waiting["apps"][0]["running"] == false,
                waiting["state"], "a ticked app that isn't open is listed and waited for");
        for (int round = 0; round < 2; ++round) {
            std::unique_ptr<ChildProcess> player;
            try {
                player = start_detached(fake.wstring(), L"tonegen --freq 440 --amp 0.25 --seconds 900",
                                        parent_pid_of(GetCurrentProcessId()));
            } catch (const std::exception& e) {
                r.note(e.what());
                break;
            }
            wait_session(player->pid());
            wait_music_state(music, "running", 10);
            sleep_s(2.5);
            const auto left = left_of(ear.listen(2.0));
            const auto m = measure_tone(left.data(), left.size(), kRate, target);
            const std::string name = round == 0 ? "later_app_joins" : "later_app_rejoins_after_restart";
            r.check(name, std::fabs(m.frequency - target) < 0.5 && m.level_db - level_at(left, 440.0) >= 50,
                    m.frequency, "it is shifted as soon as it opens");
            player->kill();
            sleep_s(1.0);
        }
        music.stop();
        wait_music_state(music, "off", 5);
    }

    // ---- F. Total delay, measured with short beeps shifted up an octave.
    say("F. total delay");
    auto beeper = start_player(L"--freq 440 --amp 0.25 --seconds 900 --pulse", r);
    wait_session(beeper->pid());
    music.set_semitones(12);
    music.start_pid(beeper->pid());
    wait_music_state(music, "running", 10);
    sleep_s(2.0);
    {
        const auto rec = ear.listen(6.0);
        const auto left = left_of(rec);
        std::vector<double> delays;
        double from = 0;
        for (int i = 0; i < 6; ++i) {
            // The quiet original reaches the cable directly; the shifted copy comes later.
            const double t_in = onset_time(left.data(), left.size(), kRate, 440.0, -88.0, from);
            if (t_in < 0) break;
            const double t_out = onset_time(left.data(), left.size(), kRate, 880.0, -40.0, t_in);
            if (t_out > 0 && t_out - t_in < 0.9) delays.push_back((t_out - t_in) * 1000);
            from = t_in + 0.8;
        }
        std::sort(delays.begin(), delays.end());
        const double delay = delays.empty() ? -1 : delays[delays.size() / 2];
        r.info("delay_samples_ms", delays);
        r.check("total_delay_ms", delay > 0 && delay < 400, delay,
                "from the app playing to the shifted sound (Rubber Band ~110 ms + cushion + Windows)");
        r.info("status_while_beeping", music.status());
        r.wav("music_delay_beeps", rec, 2);
    }
    music.stop();
    wait_music_state(music, "off", 5);
    beeper->kill();

    // ---- G. A long run without dropouts.
    say("G. " + std::to_string(int(long_seconds)) + " s without dropouts");
    auto steady = start_player(L"--freq 440 --amp 0.25 --seconds 900", r);
    wait_session(steady->pid());
    music.set_semitones(2);
    music.start_pid(steady->pid());
    wait_music_state(music, "running", 10);
    sleep_s(3.0);
    music.reset_counts();
    {
        const auto rec = ear.listen(long_seconds);
        const auto status = music.status();
        r.info("long_run_status", status);
        r.check("long_run_dropouts", status["dropouts"] == 0, status["dropouts"], "the cushion never ran dry");
        r.check("long_run_skips", status["skips"] == 0, status["skips"], "nothing had to be skipped");
        r.info("long_run_gaps", status["gaps"], "packets Windows marked as 'something was lost'");
        // Listen for gaps: the shifted tone's level in 50 ms pieces should never dip.
        const auto left = left_of(rec);
        const size_t piece = kRate / 20;
        std::vector<double> levels;
        for (size_t i = 0; i + piece <= left.size(); i += piece)
            levels.push_back(to_db(tone_amplitude(left.data() + i, piece, kRate, target)));
        std::vector<double> sorted = levels;
        std::sort(sorted.begin(), sorted.end());
        const double median = sorted.empty() ? -200 : sorted[sorted.size() / 2];
        const double lowest = sorted.empty() ? -200 : sorted.front();
        r.info("long_run_seconds_recorded", double(left.size()) / kRate);
        r.check("long_run_no_dips", !levels.empty() && lowest > median - 3.0, lowest - median,
                "the shifted tone never dipped more than 3 dB (no audible gaps)");
        const size_t keep = std::min(rec.size(), size_t(kRate) * 2 * 10);
        r.wav("music_long_run_first10s", std::vector<float>(rec.begin(), rec.begin() + std::ptrdiff_t(keep)), 2);
    }
    music.stop();
    wait_music_state(music, "off", 5);
    steady->kill();
    restore_all((r.out() / L"restore.json").wstring());
    return r.finish("e2e_music.json");
}

// ---------------- e2e-advanced ----------------

namespace {

double cents(double hz, double expect) { return hz > 0 && expect > 0 ? 1200 * std::log2(hz / expect) : 9999; }

std::string amount_name(double steps) {
    return (steps < 0 ? "minus" : "plus") + std::to_string(int(std::lround(std::fabs(steps))));
}

std::string hz_text(double hz) {
    char buf[32];
    std::snprintf(buf, sizeof buf, "%.1f Hz", hz);
    return buf;
}

// Waits until the status shows an Advanced player (on; range 12 or 24 if given) or a normal one (off).
bool wait_advanced(MusicPath& music, bool on, double seconds, int range = 0) {
    const auto end = std::chrono::steady_clock::now() + std::chrono::duration<double>(seconds);
    while (std::chrono::steady_clock::now() < end) {
        const auto e = music.status()["advanced_engine"];
        if (on ? e.is_object() && (range == 0 || e["range"] == range) : e.is_null()) return true;
        sleep_s(0.1);
    }
    return false;
}

json engine_value(MusicPath& music, const char* key) {
    const auto e = music.status()["advanced_engine"];
    return e.is_object() && e.contains(key) ? e[key] : json();
}

// From 440 Hz beeps (tonegen --pulse): how long after the quiet original reaches the cable the shifted copy
// (at `out_hz`) arrives, for each beep (ms).
std::vector<double> beep_delays(const std::vector<float>& left, double out_hz) {
    std::vector<double> delays;
    const size_t win = kRate / 50;
    double from = 0;
    for (int tries = 0; tries < 60 && delays.size() < 10; ++tries) {
        const double t_in = onset_time(left.data(), left.size(), kRate, 440.0, -88.0, from);
        if (t_in < 0) break;
        // While the loud shifted copy plays, a little of it shows up near 440 Hz too: only count a start of the
        // original when the shifted copy is quiet.
        const size_t at = size_t(std::max(0.0, t_in - 0.01) * kRate);
        if (at + win > left.size()) break;
        if (to_db(tone_amplitude(left.data() + at, win, kRate, out_hz)) > -50) {
            from = t_in + 0.02;
            continue;
        }
        const double t_out = onset_time(left.data(), left.size(), kRate, out_hz, -40.0, t_in);
        if (t_out > 0 && t_out - t_in > 0.05 && t_out - t_in < 0.9) delays.push_back((t_out - t_in) * 1000);
        from = t_in + 0.8;
    }
    return delays;
}

double median_of(std::vector<double> v) {
    if (v.empty()) return -1;
    std::sort(v.begin(), v.end());
    return v[v.size() / 2];
}

}  // namespace

int e2e_advanced(const Args& args) {
    ComScope com;
    Report r(args.get(L"--out", L"e2e-out"));
    const auto ids = cable_ids(r);
    if (!ids) return r.finish("e2e_advanced.json") + 2;
    const double long_seconds = args.number(L"--seconds", 60);
    CableEar ear(ids->output, long_seconds + 5);
    MusicPath music((r.out() / L"restore_advanced.json").wstring(), L"");

    // ---- A. Pitch: 440 Hz at +8, -5 and +15 (past +12 a new player is made for the full range).
    say("A. Advanced processing: 440 Hz at +8, -5 and +15");
    auto a = start_player(L"--freq 440 --amp 0.25 --seconds 900", r);
    if (!wait_session(a->pid())) r.note("the player's sound never showed up");
    sleep_s(1.0);
    const auto base_left = left_of(ear.listen(2.0));
    const auto base = measure_tone(base_left.data(), base_left.size(), kRate, 440.0);
    r.info("baseline_level_db", base.level_db, "the player's tone at the cable before shifting");
    music.set_advanced(true);
    music.set_semitones(8);
    music.start_pid(a->pid());
    r.check("running", wait_music_state(music, "running", 15), music.status()["state"],
            "the path starts with Advanced processing on");
    r.check("advanced_player_within_12", wait_advanced(music, true, 10, 12), music.status()["advanced_engine"],
            "the status shows the Advanced player, made for -12..+12");
    r.check("status_advanced", music.status()["advanced"] == true, music.status()["advanced"],
            "music.advanced is true in the status");
    r.info("engine_delay_ms_within_12", engine_value(music, "latency_ms"), "the Advanced engine's own delay");
    for (double steps : {8.0, -5.0, 15.0}) {
        const std::string name = amount_name(steps);
        music.set_semitones(steps);
        if (steps > 12)
            r.check("full_range_player_past_12", wait_advanced(music, true, 10, 24), music.status()["advanced_engine"],
                    "going past +12 makes a new player for the full range (more delay), like the Mac");
        sleep_s(3.0);  // a new amount is heard 0.2-0.3 s later; then the slow tone control settles
        const auto rec = ear.listen(3.0);
        const auto left = left_of(rec);
        const double expect = 440.0 * std::pow(2.0, steps / 12);
        const auto m = measure_tone(left.data(), left.size(), kRate, expect);
        r.check("pitch_" + name + "_cents", std::fabs(cents(m.frequency, expect)) < 2.0, cents(m.frequency, expect),
                "440 Hz shifted by " + std::to_string(int(steps)) + " lands on " + hz_text(expect) + " (within 2 cents)");
        r.info("pitch_" + name + "_hz", m.frequency);
        r.info("level_" + name + "_change_db", m.level_db - base.level_db,
               "the slow tone control may move a lone tone's level a little");
        const double original = level_at(left, 440.0);
        r.check("original_down_" + name + "_db", m.level_db - original >= 40, m.level_db - original,
                "the original is at least 40 dB quieter than the shifted tone");
        r.wav("advanced_" + name, rec, 2);
    }
    r.info("engine_delay_ms_full_range", engine_value(music, "latency_ms"));
    r.check("underruns_A", engine_value(music, "underruns") == 0, engine_value(music, "underruns"),
            "the engine's shifters were always ready in time");
    music.stop();
    wait_music_state(music, "off", 5);
    a->kill();

    // ---- B. The bass fold (a low note at +8), and switching off and on.
    say("B. a bass note at +8; switching off and on");
    auto bass = start_player(L"--freq 82.41 --amp 0.25 --seconds 900", r);
    wait_session(bass->pid());
    music.set_semitones(8);
    music.start_pid(bass->pid());
    wait_music_state(music, "running", 15);
    r.check("new_start_within_12", wait_advanced(music, true, 10, 12), music.status()["advanced_engine"],
            "starting again at +8 makes a -12..+12 player (less delay)");
    sleep_s(4.0);
    const double fold_hz = 82.41 * std::pow(2.0, -4.0 / 12), plain_hz = 82.41 * std::pow(2.0, 8.0 / 12);
    {
        const auto rec = ear.listen(3.0);
        const auto left = left_of(rec);
        const double fold = level_at(left, fold_hz), plain = level_at(left, plain_hz);
        const auto m = measure_tone(left.data(), left.size(), kRate, fold_hz);
        r.info("bass_fold_level_db", fold, "65.4 Hz: the bass shifted an octave less (by -4)");
        r.info("bass_plain_level_db", plain, "130.8 Hz: where a plain +8 shift puts it");
        r.check("bass_fold_db", fold - plain >= 10, fold - plain,
                "E2 (82.4 Hz) at +8 lands at 65.4 Hz, an octave below a plain shift (130.8 Hz), 10+ dB stronger there");
        r.check("bass_fold_pitch_cents", std::fabs(cents(m.frequency, fold_hz)) < 3.0, cents(m.frequency, fold_hz),
                "the folded bass is in tune (within 3 cents)");
        r.wav("advanced_bass_plus8", rec, 2);
    }
    music.set_advanced(false);
    r.check("switch_off_reaches_engine", wait_advanced(music, false, 10), music.status()["advanced"],
            "switching off makes a normal player");
    sleep_s(2.5);
    {
        const auto rec = ear.listen(3.0);
        const auto left = left_of(rec);
        const double fold = level_at(left, fold_hz), plain = level_at(left, plain_hz);
        r.check("normal_mode_bass_goes_up", plain - fold >= 10, plain - fold,
                "without Advanced processing the bass goes up with everything else (130.8 Hz)");
        r.wav("normal_bass_plus8", rec, 2);
    }
    music.set_advanced(true);
    r.check("switch_on_again_reaches_engine", wait_advanced(music, true, 10), music.status()["advanced_engine"],
            "switching on again makes an Advanced player");
    r.info("player_rebuilds", music.status()["player_rebuilds"]);
    music.stop();
    wait_music_state(music, "off", 5);
    bass->kill();

    // ---- C. Total delay, measured with short beeps: within -12..+12 and in the full range.
    say("C. total delay");
    auto beeper = start_player(L"--freq 440 --amp 0.25 --seconds 900 --pulse", r);
    wait_session(beeper->pid());
    music.set_semitones(8);
    music.start_pid(beeper->pid());
    wait_music_state(music, "running", 15);
    wait_advanced(music, true, 10, 12);
    for (double steps : {8.0, 15.0}) {
        const std::string name = steps > 12 ? "full_range" : "within_12";
        music.set_semitones(steps);
        if (steps > 12) wait_advanced(music, true, 10, 24);
        sleep_s(3.0);
        const auto rec = ear.listen(8.0);
        const auto delays = beep_delays(left_of(rec), 440.0 * std::pow(2.0, steps / 12));
        const double delay = median_of(delays);
        r.info("delay_samples_ms_" + name, delays);
        r.check("total_delay_ms_" + name, delay > 0 && delay <= 800, delay,
                "from the app playing to the shifted sound, at most 0.8 s (" + amount_name(steps) + ")");
        const auto st = music.status();
        r.info("delay_parts_" + name, json{{"engine_ms", engine_value(music, "latency_ms")},
                                           {"cushion_ms", st["queued_ms"]},
                                           {"output_ms", st["output_ms"]},
                                           {"estimate_ms", st["delay_estimate_ms"]}});
        r.wav("advanced_delay_beeps_" + name, rec, 2);
    }
    music.stop();
    wait_music_state(music, "off", 5);
    beeper->kill();

    // ---- D. Quick amount changes (like clicking - and + fast): no gaps, the shifters always ready.
    say("D. quick amount changes");
    auto steady = start_player(L"--freq 440 --amp 0.25 --seconds 900", r);
    wait_session(steady->pid());
    music.set_semitones(2);
    music.start_pid(steady->pid());
    wait_music_state(music, "running", 15);
    wait_advanced(music, true, 10, 12);
    sleep_s(2.0);
    music.reset_counts();
    const json under_before = engine_value(music, "underruns");
    for (double v : {3.0, 4.0, 5.0, 8.0, 7.0, -2.0, -5.0, 0.0, 12.0, 10.0, 6.0, -12.0, 2.5, 9.0}) {
        music.set_semitones(v);
        sleep_s(0.6);
    }
    for (int i = 0; i < 10; ++i) {
        music.set_semitones(i % 2 ? 5 : 6);
        sleep_s(0.05);
    }
    music.set_semitones(8);
    sleep_s(3.0);
    {
        const auto st = music.status();
        const json under = engine_value(music, "underruns");
        r.check("changes_dropouts", st["dropouts"] == 0, st["dropouts"], "the cushion never ran dry");
        r.check("changes_skips", st["skips"] == 0, st["skips"], "nothing had to be skipped");
        r.check("changes_underruns", under == under_before, under, "the shifters were always ready in time");
        r.info("changes_switches", engine_value(music, "switches"), "amount changes faded in");
        const auto left = left_of(ear.listen(2.0));
        const double expect = 440.0 * std::pow(2.0, 8.0 / 12);
        const auto m = measure_tone(left.data(), left.size(), kRate, expect);
        r.check("changes_end_at_last_amount", std::fabs(cents(m.frequency, expect)) < 2.0, m.frequency,
                "after quick changes it ends at the last amount (+8)");
    }

    // ---- E. A long run without dropouts.
    say("E. " + std::to_string(int(long_seconds)) + " s without dropouts");
    music.reset_counts();
    {
        const json under_before_long = engine_value(music, "underruns");
        const auto rec = ear.listen(long_seconds);
        const auto status = music.status();
        r.info("long_run_status", status);
        r.check("long_run_dropouts", status["dropouts"] == 0, status["dropouts"], "the cushion never ran dry");
        r.check("long_run_skips", status["skips"] == 0, status["skips"], "nothing had to be skipped");
        r.check("long_run_underruns", engine_value(music, "underruns") == under_before_long,
                engine_value(music, "underruns"), "the shifters were always ready in time");
        r.info("long_run_gaps", status["gaps"], "packets Windows marked as 'something was lost'");
        const auto left = left_of(rec);
        const double target = 440.0 * std::pow(2.0, 8.0 / 12);
        const size_t piece = kRate / 20;
        std::vector<double> levels;
        for (size_t i = 0; i + piece <= left.size(); i += piece)
            levels.push_back(to_db(tone_amplitude(left.data() + i, piece, kRate, target)));
        std::vector<double> sorted = levels;
        std::sort(sorted.begin(), sorted.end());
        const double mid = sorted.empty() ? -200 : sorted[sorted.size() / 2];
        const double lowest = sorted.empty() ? -200 : sorted.front();
        r.info("long_run_seconds_recorded", double(left.size()) / kRate);
        r.check("long_run_no_dips", !levels.empty() && lowest > mid - 3.0, lowest - mid,
                "the shifted tone never dipped more than 3 dB (no audible gaps)");
        const size_t keep = std::min(rec.size(), size_t(kRate) * 2 * 10);
        r.wav("advanced_long_run_first10s", std::vector<float>(rec.begin(), rec.begin() + std::ptrdiff_t(keep)), 2);
    }
    music.stop();
    wait_music_state(music, "off", 5);
    steady->kill();
    restore_all((r.out() / L"restore_advanced.json").wstring());
    return r.finish("e2e_advanced.json");
}

// ---------------- e2e-voice ----------------

int e2e_voice(const Args& args) {
    ComScope com;
    Report r(args.get(L"--out", L"e2e-out"));
    const auto cable = find_cable();
    if (!cable.present) {
        r.note("VB-CABLE is not installed.");
        return r.finish("e2e_voice.json") + 2;
    }
    // A made-up "aah" at 120 Hz stands in for the microphone (the runner has none).
    const auto vowel = make_vowel(120.0, kRate, 2.0, 0.3);
    const double in_centroid = spectral_centroid(vowel.data(), vowel.size(), kRate, 300, 4000);
    const double in_f0 = estimate_f0(vowel.data(), vowel.size(), kRate, 70, 400);
    size_t pos = 0;
    VoicePath voice;
    voice.set_test_input([&vowel, pos](float* out, size_t n) mutable {
        for (size_t i = 0; i < n; ++i) {
            out[i] = vowel[pos];
            pos = (pos + 1) % vowel.size();
        }
    });
    voice.set_semitones(4);
    voice.set_natural(true);
    const std::wstring before_console = default_endpoint_id(eCapture, eConsole);
    const std::wstring before_comms = default_endpoint_id(eCapture, eCommunications);
    r.info("default_mic_before", utf8(before_console));
    voice.start(L"");
    sleep_s(1.5);
    r.check("idle_without_call_app", voice.status()["state"] == "idle", voice.status()["state"],
            "nothing runs until an app uses Pitch Shift Mic");
    r.check("voice_on_makes_default_mic",
            default_endpoint_id(eCapture, eConsole) == cable.mic_id &&
                default_endpoint_id(eCapture, eCommunications) == cable.mic_id,
            utf8(default_endpoint_id(eCapture, eConsole)), "while on, Pitch Shift Mic is the default microphone");

    auto listen = [&](const std::string& name) {
        const fs::path wav = r.out() / (name + ".wav");
        auto call = start_process(self_path(), L"record --device \"" + cable.mic_id + L"\" --seconds 7 --out \"" +
                                                   wav.wstring() + L"\" --channels 1");
        bool in_use = false, running = false;
        json last;
        while (call->running()) {
            last = voice.status();
            in_use = in_use || last["in_use"] == true;
            running = running || last["state"] == "running";
            sleep_s(0.2);
        }
        r.info(name + "_status", last);
        r.check(name + "_runs_for_call_app", in_use && running, json{{"in_use", in_use}, {"running", running}},
                "the voice path starts when a call app records from Pitch Shift Mic");
        return read_wav(wav.string());
    };

    double centroid_natural = 0, centroid_cartoon = 0;
    for (int pass = 0; pass < 2; ++pass) {
        const bool natural = pass == 0;
        voice.set_natural(natural);
        sleep_s(0.3);
        const std::string name = natural ? "voice_natural_plus4" : "voice_cartoon_plus4";
        const auto data = listen(name);
        const size_t n = std::min(data.samples.size(), size_t(kRate * 3));
        if (n < size_t(kRate)) {
            r.check(name + "_heard", false, data.samples.size(), "the call app heard the voice");
            continue;
        }
        const float* tail = data.samples.data() + data.samples.size() - n;
        const double f0 = estimate_f0(tail, n, kRate, 70, 400);
        const double centroid = spectral_centroid(tail, n, kRate, 300, 4000);
        double sum2 = 0;
        for (size_t i = 0; i < n; ++i) sum2 += double(tail[i]) * tail[i];
        r.check(name + "_heard", sum2 / double(n) > 1e-5, to_db(std::sqrt(sum2 / double(n))), "the call app heard the voice");
        r.check(name + "_f0_hz", std::fabs(f0 / (in_f0 * std::pow(2.0, 4.0 / 12)) - 1) < 0.03, f0,
                "120 Hz voice +4 = 151.2 Hz");
        (natural ? centroid_natural : centroid_cartoon) = centroid / in_centroid;
    }
    r.check("natural_keeps_formants", std::fabs(centroid_natural - 1.0) < 0.10, centroid_natural,
            "Natural: the voice's resonances stay put (ratio about 1.0)");
    r.check("cartoon_moves_formants", centroid_cartoon > 1.15, centroid_cartoon,
            "Cartoon: the resonances move up with the pitch (ratio about 1.26)");
    sleep_s(3.0);
    r.check("idle_after_call_app_stops", voice.status()["state"] == "idle", voice.status()["state"],
            "the microphone is let go when the call app stops");

    // The Test button: records 5 s (counting down), plays it back, then goes back to normal.
    voice.set_natural(true);
    voice.test_start();
    std::vector<int> countdown;
    bool played = false;
    const auto end = std::chrono::steady_clock::now() + std::chrono::seconds(15);
    std::string state = "recording";
    while (std::chrono::steady_clock::now() < end) {
        const auto s = voice.status()["test"];
        state = s["state"];
        if (state == "recording") {
            const int left = s["seconds_left"];
            if (countdown.empty() || countdown.back() != left) countdown.push_back(left);
        }
        if (state == "playing") played = true;
        if (played && state == "idle") break;
        sleep_s(0.1);
    }
    r.info("test_countdown", countdown);
    r.check("test_button_flow", played && state == "idle" && !countdown.empty() && countdown.front() >= 4,
            json{{"played", played}, {"final", state}}, "Test records 5 s, plays it back, and finishes");
    voice.stop();
    bool given_back = false;
    const bool had_list = default_mic_taken();
    for (int i = 0; i < 30 && !given_back; ++i) {
        sleep_s(0.1);
        given_back = default_endpoint_id(eCapture, eConsole) == before_console &&
                     default_endpoint_id(eCapture, eCommunications) == before_comms;
    }
    if (before_console == cable.mic_id) r.note("the only microphone on this PC is the cable, so giving back can't be seen");
    r.check("voice_off_gives_back_default_mic", given_back && !default_mic_taken(),
            json{{"default", utf8(default_endpoint_id(eCapture, eConsole))}, {"list_was_kept", had_list}},
            "switching off gives back the previous default microphone");

    // A minute of voice into a call app: no gaps.
    say("long voice run");
    {
        const double long_seconds = args.number(L"--seconds", 60);
        VoicePath steady;
        double phase = 0;
        steady.set_test_input([phase](float* out, size_t n) mutable {
            for (size_t i = 0; i < n; ++i) {
                out[i] = float(0.3 * std::sin(phase));
                phase += 2 * 3.14159265358979323846 * 300.0 / kRate;
            }
        });
        steady.set_semitones(4);
        steady.set_natural(true);
        steady.start(L"");
        const fs::path wav = r.out() / "voice_long_run.wav";
        auto call = start_process(self_path(), L"record --device \"" + cable.mic_id + L"\" --seconds " +
                                                   std::to_wstring(int(long_seconds) + 4) + L" --out \"" + wav.wstring() +
                                                   L"\" --channels 1");
        // Start counting once the voice is flowing.
        for (int i = 0; i < 50 && steady.status()["state"] != "running"; ++i) sleep_s(0.1);
        sleep_s(2.0);
        steady.reset_counts();
        call->wait(DWORD(long_seconds * 1000) + 20000);
        const auto status = steady.status();
        r.info("long_voice_status", status);
        r.check("long_voice_dropouts", status["dropouts"] == 0, status["dropouts"], "the voice never ran dry");
        const auto data = read_wav(wav.string());
        const double target = 300.0 * std::pow(2.0, 4.0 / 12);
        const size_t piece = kRate / 20;
        std::vector<double> levels;
        // Skip the first 4 s (start-up), look at the rest in 50 ms pieces.
        for (size_t i = size_t(kRate) * 4; i + piece <= data.samples.size(); i += piece)
            levels.push_back(to_db(tone_amplitude(data.samples.data() + i, piece, kRate, target)));
        std::vector<double> sorted = levels;
        std::sort(sorted.begin(), sorted.end());
        const double median = sorted.empty() ? -200 : sorted[sorted.size() / 2];
        const double lowest = sorted.empty() ? -200 : sorted.front();
        r.info("long_voice_seconds", double(levels.size()) / 20);
        r.check("long_voice_no_dips", levels.size() > 20 * size_t(long_seconds * 0.8) && lowest > median - 3.0,
                lowest - median, "the shifted voice never dipped more than 3 dB (no gaps)");
        r.info("long_voice_trims_repeats", json{{"trims", status["trims"]}, {"repeats", status["repeats"]}});
        steady.stop();
    }
    return r.finish("e2e_voice.json");
}

// ---------------- e2e-crash ----------------

int e2e_crash(const Args& args) {
    ComScope com;
    Report r(args.get(L"--out", L"e2e-out"));
    if (!cable_ids(r)) return r.finish("e2e_crash.json") + 2;
    const std::wstring list = (r.out() / L"crash_restore.json").wstring();
    auto start_host = [&](DWORD pid) {
        return start_process(self_path(), L"host --pid " + std::to_wstring(pid) + L" --semitones 2 --file \"" + list + L"\"");
    };

    say("1. Pitch Shift ends suddenly while an app is quiet");
    auto a = start_player(L"--freq 440 --amp 0.25 --seconds 900", r);
    wait_session(a->pid());
    auto h = start_host(a->pid());
    const bool quieted = wait_volumes(a->pid(), kQuietLevel, 15);
    r.check("host_quieted_app", quieted, volumes_of(a->pid()), "the app was made quiet");
    h->kill();
    const auto t0 = std::chrono::steady_clock::now();
    const bool back = wait_volumes(a->pid(), 1.0f, 10);
    r.check("watchdog_restored", back, std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count(),
            "the watchdog put the volume back (seconds)");

    say("2. the quiet app quits, then Pitch Shift ends suddenly");
    auto h2 = start_host(a->pid());
    const bool quieted_again = wait_volumes(a->pid(), kQuietLevel, 15);
    r.check("host_quieted_again", quieted_again, volumes_of(a->pid()), "");
    a->kill();
    sleep_s(1.0);
    h2->kill();
    sleep_s(8.0);  // the watchdog's two passes
    auto a2 = start_player(L"--freq 440 --amp 0.25 --seconds 900", r);
    const auto s = wait_session(a2->pid());
    const auto levels = s ? channel_volumes(s->channel_volume().Get()) : std::vector<float>{};
    r.check("app_starts_full_after_crash", all_equal(levels, 1.0f), levels,
            "the app that quit while quiet starts at full volume next time");
    a2->kill();
    restore_all(list);

    say("3. Pitch Shift ends suddenly while 'Your voice' is on");
    const auto cable = find_cable();
    const std::wstring before_console = default_endpoint_id(eCapture, eConsole);
    const std::wstring before_comms = default_endpoint_id(eCapture, eCommunications);
    r.info("default_mic_before", utf8(before_console));
    if (before_console == cable.mic_id) r.note("the only microphone on this PC is the cable, so giving back can't be seen");
    auto hv = start_process(self_path(), L"host --voice --file \"" + list + L"\"");
    bool taken = false;
    for (int i = 0; i < 100 && !taken; ++i) {
        sleep_s(0.1);
        taken = default_mic_taken() && default_endpoint_id(eCapture, eConsole) == cable.mic_id &&
                default_endpoint_id(eCapture, eCommunications) == cable.mic_id;
    }
    r.check("voice_host_took_default_mic", taken, utf8(default_endpoint_id(eCapture, eConsole)),
            "Pitch Shift Mic became the default microphone");
    hv->kill();  // like "taskkill /F"
    bool mic_back = false;
    const auto t1 = std::chrono::steady_clock::now();
    for (int i = 0; i < 100 && !mic_back; ++i) {
        sleep_s(0.1);
        mic_back = !default_mic_taken() && default_endpoint_id(eCapture, eConsole) == before_console &&
                   default_endpoint_id(eCapture, eCommunications) == before_comms;
    }
    r.check("default_mic_given_back_after_crash", mic_back,
            std::chrono::duration<double>(std::chrono::steady_clock::now() - t1).count(),
            "the watchdog gave back the real microphone (seconds)");
    return r.finish("e2e_crash.json");
}

}  // namespace ps::tool
