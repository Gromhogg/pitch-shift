// "What you hear": records the chosen apps (each with its helper processes) or all sound,
// changes the pitch, and plays it to the default speakers. The apps' own sound is made very quiet
// (see quiet.h) and the recording is boosted back up, so only the shifted copy is heard.
// Several apps can be chosen: each is recorded on its own and the recordings are mixed.
#pragma once
#include "dsp/booster.h"
#include "dsp/cushion.h"
#include "dsp/music_shifter.h"
#include "dsp/ring.h"
#include "win/capture.h"
#include "win/quiet.h"
#include "win/render.h"

#include <atomic>
#include <chrono>
#include <map>
#include <memory>
#include <mutex>
#include <nlohmann/json.hpp>
#include <string>
#include <thread>
#include <vector>

namespace ps {

class MusicPath {
public:
    MusicPath(std::wstring restore_list, std::wstring restore_command);
    ~MusicPath();
    MusicPath(const MusicPath&) = delete;
    MusicPath& operator=(const MusicPath&) = delete;

    void start_all();                                     // everything except Pitch Shift itself
    void start_apps(const std::vector<std::wstring>& exe_paths);  // apps by program file; each joins when it opens
    void start_pids(const std::vector<DWORD>& pids);      // processes and everything they started
    void start_pid(DWORD pid) { start_pids({pid}); }
    void stop();
    void set_semitones(double value) { semitones_ = value; }
    double semitones() const { return semitones_; }

    nlohmann::json status() const;
    void reset_counts();

    // Cushion sizes (same as the Mac app): start at 50 ms, never more than 150 ms.
    static constexpr double kStartMs = 50;
    static constexpr double kMaxMs = 150;

private:
    enum class Mode { off, all, pids, apps };

    // One recording (one app with its helpers, or "everything except us").
    struct Stream {
        explicit Stream(DWORD root) : root(root), ring(size_t(kRate) * kChannels) {}
        DWORD root;
        std::unique_ptr<Capture> capture;
        SampleRing ring;  // filled by the stream's recording thread, emptied by mix()
    };

    void run();
    void tick();
    void add_stream(DWORD root, bool include_tree);
    void remove_stream(DWORD root);
    void remove_all_streams();
    void mix();
    void process_mixed(float* data, size_t frames);

    // Settings (set by the caller, read by the manager thread).
    mutable std::mutex settings_lock_;
    Mode mode_ = Mode::off;
    std::vector<DWORD> target_pids_;
    std::vector<std::wstring> target_exes_;
    std::atomic<double> semitones_{0.0};

    // Manager thread.
    HANDLE wake_;
    std::thread thread_;
    std::atomic<bool> quit_{false};
    QuietKeeper keeper_;
    std::map<DWORD, std::chrono::steady_clock::time_point> retry_after_;

    // The sound chain. mix_lock_ guards streams_ and everything mix() uses.
    std::mutex mix_lock_;
    std::map<DWORD, std::shared_ptr<Stream>> streams_;
    bool include_tree_ = true;
    std::unique_ptr<Renderer> renderer_;
    std::unique_ptr<MusicShifter> shifter_;
    Booster booster_;
    Cushion cushion_;
    std::vector<float> mixed_, piece_, shifted_;

    // Status (read from any thread).
    mutable std::mutex status_lock_;
    std::string state_ = "off", error_;
    nlohmann::json apps_ = nlohmann::json::array();
    int quieted_ = 0;
    std::atomic<uint64_t> clipped_{0}, gaps_{0};
    double output_ms_ = 0;
    uint64_t current_gaps_ = 0;
    std::wstring speaker_;
    std::chrono::steady_clock::time_point speaker_checked_{};
};

}  // namespace ps
