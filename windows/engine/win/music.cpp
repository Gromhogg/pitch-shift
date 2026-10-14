#include "win/music.h"

#include "win/apps.h"
#include "win/devices.h"
#include "win/session_watch.h"

#include <algorithm>
#include <iterator>
#include <set>

namespace ps {

namespace {
size_t ms_to_frames(double ms) { return size_t(kRate * ms / 1000); }

// When one recording has nothing new, wait this long for it before mixing without it.
constexpr size_t kLagFrames = kRate * 30 / 1000;
// A recording that got this far ahead of the others is started over.
constexpr size_t kAheadFrames = kRate * 200 / 1000;
}  // namespace

MusicPath::MusicPath(std::wstring restore_list, std::wstring restore_command)
    : keeper_(std::move(restore_list), std::move(restore_command)),
      booster_(kChannels, 1.0f / kQuietLevel),
      cushion_(kChannels, ms_to_frames(kStartMs), ms_to_frames(kMaxMs)) {
    wake_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    thread_ = std::thread([this] { run(); });
}

MusicPath::~MusicPath() {
    quit_ = true;
    SetEvent(wake_);
    if (thread_.joinable()) thread_.join();
    CloseHandle(wake_);
}

void MusicPath::start_all() {
    {
        std::lock_guard<std::mutex> lock(settings_lock_);
        mode_ = Mode::all;
    }
    SetEvent(wake_);
}

void MusicPath::start_apps(const std::vector<std::wstring>& exe_paths) {
    // Compare full paths (C:\Users\RUNNER~1 and C:\Users\runneradmin are the same folder).
    std::vector<std::wstring> full;
    for (const auto& p : exe_paths) {
        wchar_t buf[MAX_PATH * 2];
        const DWORD n = GetLongPathNameW(p.c_str(), buf, DWORD(std::size(buf)));
        full.push_back(n > 0 && n < std::size(buf) ? std::wstring(buf, n) : p);
    }
    {
        std::lock_guard<std::mutex> lock(settings_lock_);
        mode_ = Mode::apps;
        target_exes_ = full;
    }
    SetEvent(wake_);
}

void MusicPath::start_pids(const std::vector<DWORD>& pids) {
    {
        std::lock_guard<std::mutex> lock(settings_lock_);
        mode_ = Mode::pids;
        target_pids_ = pids;
    }
    SetEvent(wake_);
}

void MusicPath::stop() {
    {
        std::lock_guard<std::mutex> lock(settings_lock_);
        mode_ = Mode::off;
    }
    SetEvent(wake_);
}

void MusicPath::run() {
    ComScope com;
    {
        SessionWatcher watcher(wake_);
        auto last_refresh = std::chrono::steady_clock::time_point{};
        while (!quit_) {
            const auto now = std::chrono::steady_clock::now();
            if (now - last_refresh > std::chrono::seconds(2)) {
                watcher.refresh();
                last_refresh = now;
            }
            try {
                tick();
            } catch (const std::exception& e) {
                remove_all_streams();
                std::lock_guard<std::mutex> lock(status_lock_);
                error_ = e.what();
                state_ = "error";
            }
            WaitForSingleObject(wake_, 250);
        }
        remove_all_streams();
    }
    keeper_.restore_everything();
}

void MusicPath::tick() {
    Mode mode;
    std::vector<DWORD> pids;
    std::vector<std::wstring> exes;
    {
        std::lock_guard<std::mutex> lock(settings_lock_);
        mode = mode_;
        pids = target_pids_;
        exes = target_exes_;
    }
    if (mode == Mode::off) {
        remove_all_streams();
        if (keeper_.quieted() > 0) keeper_.restore_everything();
        std::lock_guard<std::mutex> lock(status_lock_);
        state_ = "off";
        error_.clear();
        apps_ = nlohmann::json::array();
        quieted_ = 0;
        return;
    }

    const ProcessSnapshot snap;
    const DWORD self = GetCurrentProcessId();
    // Which recordings we want: one per app (its main process), or one for "everything except us".
    std::vector<DWORD> roots;
    bool include = true;
    nlohmann::json apps = nlohmann::json::array();
    if (mode == Mode::all) {
        roots.push_back(self);
        include = false;
    } else if (mode == Mode::pids) {
        for (DWORD pid : pids)
            if (snap.find(pid)) roots.push_back(pid);
    } else {
        for (const auto& exe : exes) {
            DWORD found = 0;
            for (DWORD candidate : snap.with_exe_name(file_name_of(exe))) {
                if (lower(process_path(candidate)) != lower(exe)) continue;
                const DWORD root = snap.app_root(candidate);
                // Keep the one we're already recording (if the app has several main processes).
                if (!found || streams_.count(root)) found = root;
            }
            if (found && std::find(roots.begin(), roots.end(), found) == roots.end()) roots.push_back(found);
            apps.push_back({{"exe", utf8(exe)}, {"running", found != 0}, {"pid", found}});
        }
    }

    // Switching between "all" and apps: start over.
    if (include != include_tree_) remove_all_streams();
    include_tree_ = include;
    std::vector<DWORD> existing;
    {
        std::lock_guard<std::mutex> lock(mix_lock_);
        for (const auto& [root, s] : streams_) existing.push_back(root);
    }
    for (DWORD root : existing)
        if (std::find(roots.begin(), roots.end(), root) == roots.end()) remove_stream(root);

    // Quiet the apps' sessions first, then record (so nothing loud gets boosted).
    const auto own = snap.tree(self);
    const auto sessions = list_sessions();
    keeper_.update(sessions, [&](const Session& s) {
        if (s.pid != 0 && own.count(s.pid)) return false;  // our own sound (the shifted copy, the voice test)
        if (mode == Mode::all) return s.pid != 0 || s.system_sounds;
        if (s.pid == 0) return false;
        for (DWORD root : roots)
            if (snap.in_tree(s.pid, root)) return true;
        return false;
    });

    const auto now = std::chrono::steady_clock::now();
    std::string error;
    for (DWORD root : roots) {
        bool have;
        {
            std::lock_guard<std::mutex> lock(mix_lock_);
            have = streams_.count(root) > 0;
        }
        if (have || now < retry_after_[root]) continue;
        try {
            add_stream(root, include);
        } catch (const std::exception& e) {
            error = e.what();
            retry_after_[root] = now + std::chrono::seconds(1);
        }
    }

    // Restart pieces Windows stopped (for example a device was unplugged).
    std::vector<DWORD> broken;
    uint64_t live_gaps = gaps_;
    {
        std::lock_guard<std::mutex> lock(mix_lock_);
        for (const auto& [root, s] : streams_) {
            const auto st = s->capture->stats();
            live_gaps += st.gaps;
            if (FAILED(st.error)) {
                broken.push_back(root);
                error = "recording stopped: " + hr_text(st.error);
            }
        }
        if (renderer_ && FAILED(renderer_->error())) {
            error = "playing stopped: " + hr_text(renderer_->error());
            for (const auto& [root, s] : streams_) broken.push_back(root);
        }
    }
    for (DWORD root : broken) {
        remove_stream(root);
        retry_after_[root] = now + std::chrono::milliseconds(500);
    }

    // Which speakers it plays to (the default; the stream follows it). Looked up every 2 s.
    if (now - speaker_checked_ > std::chrono::seconds(2)) {
        speaker_checked_ = now;
        std::wstring name;
        try {
            const std::wstring id = default_endpoint_id(eRender, eConsole);
            for (const auto& e : list_endpoints(eRender, DEVICE_STATE_ACTIVE))
                if (e.id == id) name = e.name;
        } catch (const std::exception&) {
        }
        std::lock_guard<std::mutex> lock(status_lock_);
        speaker_ = name;
    }

    bool running;
    double output_ms = 0;
    {
        std::lock_guard<std::mutex> lock(mix_lock_);
        running = !streams_.empty();
        if (renderer_) output_ms = renderer_->latency_ms() + renderer_->buffer_ms();
    }
    std::lock_guard<std::mutex> lock(status_lock_);
    current_gaps_ = live_gaps;
    state_ = running ? "running" : "waiting";
    error_ = error;
    apps_ = apps;
    quieted_ = keeper_.quieted();
    output_ms_ = output_ms;
}

void MusicPath::add_stream(DWORD root, bool include_tree) {
    {
        std::lock_guard<std::mutex> lock(mix_lock_);
        if (!renderer_) {
            shifter_ = std::make_unique<MusicShifter>(kRate, kChannels, semitones_.load());
            booster_.set_boost(1.0f / kQuietLevel);
            cushion_.flush();
            renderer_ = Renderer::to_default([this](float* out, size_t frames) { cushion_.pull(out, frames); });
        }
    }
    auto stream = std::make_shared<Stream>(root);
    std::weak_ptr<Stream> weak = stream;
    try {
        stream->capture = Capture::from_process(root, include_tree, [this, weak](const float* data, size_t frames) {
            if (auto s = weak.lock()) {
                if (s->ring.queued() + frames * kChannels < s->ring.capacity()) s->ring.write(data, frames * kChannels);
            }
            mix();
        });
    } catch (...) {
        std::unique_ptr<Renderer> player;
        {
            std::lock_guard<std::mutex> lock(mix_lock_);
            if (streams_.empty()) {
                player = std::move(renderer_);
                shifter_.reset();
            }
        }
        throw;
    }
    std::lock_guard<std::mutex> lock(mix_lock_);
    streams_[root] = stream;
}

void MusicPath::remove_stream(DWORD root) {
    std::shared_ptr<Stream> gone;
    {
        std::lock_guard<std::mutex> lock(mix_lock_);
        auto it = streams_.find(root);
        if (it == streams_.end()) return;
        gone = it->second;
        streams_.erase(it);
    }
    gaps_ += gone->capture->stats().gaps;
    gone->capture.reset();  // stops its recording thread (outside the lock: that thread may be mixing)
    std::unique_ptr<Renderer> player;
    {
        std::lock_guard<std::mutex> lock(mix_lock_);
        if (streams_.empty()) {
            player = std::move(renderer_);
            shifter_.reset();
        }
    }
    player.reset();
}

void MusicPath::remove_all_streams() {
    std::vector<DWORD> roots;
    {
        std::lock_guard<std::mutex> lock(mix_lock_);
        for (const auto& [root, s] : streams_) roots.push_back(root);
    }
    for (DWORD root : roots) remove_stream(root);
}

// Called from the recording threads after new sound arrived. Mixes what all recordings have,
// then boosts, shifts and queues it for the speakers.
void MusicPath::mix() {
    std::unique_lock<std::mutex> lock(mix_lock_, std::try_to_lock);
    if (!lock.owns_lock()) return;  // another recording thread is mixing; it will take our sound too
    if (streams_.empty() || !shifter_) return;
    for (;;) {
        size_t lowest = SIZE_MAX, highest = 0;
        for (const auto& [root, s] : streams_) {
            const size_t q = s->ring.queued() / kChannels;
            lowest = std::min(lowest, q);
            highest = std::max(highest, q);
        }
        size_t n = lowest;
        if (n == 0) {
            // One recording has nothing yet. Wait a little for it; after that, mix without it.
            if (highest < kLagFrames) return;
            n = highest - kLagFrames / 2;
        }
        n = std::min<size_t>(n, 2048);
        mixed_.assign(n * kChannels, 0.0f);
        for (const auto& [root, s] : streams_) {
            const size_t have = std::min(n, s->ring.queued() / kChannels);
            piece_.resize(have * kChannels);
            s->ring.read(piece_.data(), piece_.size());
            for (size_t i = 0; i < piece_.size(); ++i) mixed_[i] += piece_[i];
            // A recording far ahead of the others (it started late or another one stalled): start it over.
            if (s->ring.queued() / kChannels > kAheadFrames) s->ring.clear();
        }
        process_mixed(mixed_.data(), n);
    }
}

void MusicPath::process_mixed(float* data, size_t frames) {
    booster_.process(data, frames);
    const double want = semitones_.load();
    if (want != shifter_->half_steps()) shifter_->set_half_steps(want);
    shifted_.clear();
    shifter_->process(data, frames, shifted_);
    clipped_ += limit(shifted_.data(), shifted_.size());
    cushion_.push(shifted_.data(), shifted_.size() / kChannels);
}

void MusicPath::reset_counts() {
    cushion_.reset_counts();
    clipped_ = 0;
    gaps_ = 0;
    std::lock_guard<std::mutex> lock(status_lock_);
    current_gaps_ = 0;
}

nlohmann::json MusicPath::status() const {
    std::lock_guard<std::mutex> lock(status_lock_);
    std::string mode;
    {
        std::lock_guard<std::mutex> settings(settings_lock_);
        mode = mode_ == Mode::off ? "off" : mode_ == Mode::all ? "all" : mode_ == Mode::pids ? "pids" : "apps";
    }
    const double queued_ms = cushion_.queued_frames() * 1000.0 / kRate;
    return {{"state", state_},
            {"error", error_},
            {"mode", mode},
            {"apps", apps_},
            {"speaker", utf8(speaker_)},
            {"semitones", semitones_.load()},
            {"quieted", quieted_},
            {"dropouts", cushion_.dropouts()},
            {"skips", cushion_.skips()},
            {"skipped_ms", cushion_.skipped_frames() * 1000.0 / kRate},
            {"gaps", current_gaps_},
            {"guarded", booster_.guarded()},
            {"clipped", clipped_.load()},
            {"queued_ms", queued_ms},
            {"output_ms", output_ms_},
            // Rubber Band (about 115 ms) + the cushion + Windows' output buffer.
            {"delay_estimate_ms", state_ == "running" ? 115 + queued_ms + output_ms_ : 0}};
}

}  // namespace ps
