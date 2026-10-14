#include "win/quiet.h"

#include "win/apps.h"
#include "win/mic_default.h"

#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <set>

namespace ps {

namespace fs = std::filesystem;

namespace {

const wchar_t* kStoreKey = L"Software\\Microsoft\\Internet Explorer\\LowRegistry\\Audio\\PolicyConfig\\PropertyStore";
const wchar_t* kVolumeKey = L"{219ED5A0-9CBF-4F3A-B927-37C9E5C5F14F}";
const wchar_t* kRunOnceKey = L"Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce";
const wchar_t* kRunOnceName = L"!PitchShiftRestore";  // "!" = Windows removes it only after it ran

bool is_quiet(const std::vector<float>& levels, float quiet_level) {
    if (levels.empty()) return false;
    for (float v : levels)
        if (v > quiet_level * 1.01f + 1e-6f) return false;
    return true;
}

// Exactly our quiet level on every channel: nobody else sets that (the volume mixer can't).
bool exactly_ours(const std::vector<float>& levels) {
    if (levels.empty()) return false;
    for (float v : levels)
        if (v != kQuietLevel) return false;
    return true;
}

bool remove_from_list(const std::wstring& path, const std::wstring& instance_id) {
    auto entries = load_restore_list(path);
    const size_t before = entries.size();
    std::erase_if(entries, [&](const QuietEntry& e) { return e.instance_id == instance_id; });
    if (entries.size() == before) return false;
    if (entries.empty()) {
        std::error_code ec;
        fs::remove(fs::path(path), ec);
        return true;
    }
    return save_restore_list(path, entries);
}

std::vector<float> back_levels(const QuietEntry* entry, size_t channels) {
    std::vector<float> back;
    if (entry) back = entry->original;
    if (back.size() != channels || is_quiet(back, kQuietLevel)) back.assign(channels, 1.0f);
    return back;
}

}  // namespace

std::wstring restore_file_path() {
    wchar_t buf[MAX_PATH * 2];
    const DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", buf, DWORD(std::size(buf)));
    std::wstring base = (n > 0 && n < std::size(buf)) ? std::wstring(buf, n) : fs::temp_directory_path().wstring();
    return (fs::path(base) / L"Pitch Shift" / L"restore.json").wstring();
}

bool save_restore_list(const std::wstring& path, const std::vector<QuietEntry>& entries) {
    nlohmann::json list = nlohmann::json::array();
    for (const auto& e : entries) {
        list.push_back({{"exe", utf8(e.exe)},
                        {"native_exe", utf8(e.native_exe)},
                        {"pid", e.pid},
                        {"instance_id", utf8(e.instance_id)},
                        {"original", e.original},
                        {"quiet_level", e.quiet_level}});
    }
    std::error_code ec;
    fs::create_directories(fs::path(path).parent_path(), ec);
    // Write a new file next to the old one, then swap it in, so the list is never half-written.
    const std::wstring temp = path + L".new";
    {
        std::ofstream f(fs::path(temp), std::ios::binary | std::ios::trunc);
        if (!f) return false;
        f << nlohmann::json{{"version", 1}, {"apps", list}}.dump(2);
        f.flush();
        if (!f) return false;
    }
    return MoveFileExW(temp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
}

std::vector<QuietEntry> load_restore_list(const std::wstring& path) {
    std::vector<QuietEntry> out;
    std::ifstream f{fs::path(path), std::ios::binary};
    if (!f) return out;
    try {
        const auto j = nlohmann::json::parse(f);
        for (const auto& item : j.at("apps")) {
            QuietEntry e;
            e.exe = wide(item.value("exe", ""));
            e.native_exe = wide(item.value("native_exe", ""));
            e.pid = item.value("pid", 0u);
            e.instance_id = wide(item.value("instance_id", ""));
            e.original = item.value("original", std::vector<float>{});
            e.quiet_level = item.value("quiet_level", kQuietLevel);
            out.push_back(std::move(e));
        }
    } catch (const std::exception&) {
        // A damaged list: treat it as empty (restore_all still fixes anything left at our quiet level).
    }
    return out;
}

HRESULT quiet_session(const Session& session, float level, const std::wstring& path) {
    auto volume = session.channel_volume();
    if (!volume) return E_NOINTERFACE;
    auto entries = load_restore_list(path);
    bool known = false;
    for (const auto& e : entries) known = known || e.instance_id == session.instance_id;
    if (!known) {
        QuietEntry e;
        e.exe = session.exe;
        e.native_exe = session.pid ? native_process_path(session.pid) : L"";
        if (e.native_exe.empty()) e.native_exe = native_path_of(session.exe);
        e.pid = session.pid;
        e.instance_id = session.instance_id;
        e.original = channel_volumes(volume.Get());
        e.quiet_level = level;
        if (e.original.empty()) return E_FAIL;
        if (is_quiet(e.original, level)) e.original.assign(e.original.size(), 1.0f);  // already quiet: aim for full
        entries.push_back(e);
        if (!save_restore_list(path, entries)) return HRESULT_FROM_WIN32(ERROR_WRITE_FAULT);
    }
    return set_all_channels(volume.Get(), level);
}

int fix_remembered_volume(const QuietEntry& entry) {
    HKEY store = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kStoreKey, 0, KEY_READ, &store) != ERROR_SUCCESS) return 0;
    const std::wstring want = entry.native_exe.empty() ? L"" : L"|" + lower(entry.native_exe) + L"%b";
    int fixed = 0;
    for (DWORD i = 0;; ++i) {
        wchar_t name[256];
        DWORD name_len = DWORD(std::size(name));
        if (RegEnumKeyExW(store, i, name, &name_len, nullptr, nullptr, nullptr, nullptr) != ERROR_SUCCESS) break;
        // The key's default value says which device and program it's for.
        wchar_t text[2048];
        DWORD text_size = sizeof(text);
        if (RegGetValueW(store, name, nullptr, RRF_RT_REG_SZ, nullptr, text, &text_size) != ERROR_SUCCESS) continue;
        if (!want.empty() && lower(text).find(want) == std::wstring::npos) continue;
        HKEY volume_key = nullptr;
        const std::wstring sub = std::wstring(name) + L"\\" + kVolumeKey;
        if (RegOpenKeyExW(store, sub.c_str(), 0, KEY_QUERY_VALUE | KEY_SET_VALUE, &volume_key) != ERROR_SUCCESS) continue;
        // Value "4" holds the per-channel volumes: a 2-byte type (VT_ARRAY | VT_R4), padding,
        // then the floats from byte 24 on.
        BYTE data[256];
        DWORD size = sizeof(data), type = 0;
        if (RegQueryValueExW(volume_key, L"4", nullptr, &type, data, &size) == ERROR_SUCCESS && type == REG_BINARY &&
            size > 24 && (size - 24) % 4 == 0) {
            uint16_t vt = 0;
            std::memcpy(&vt, data, 2);
            const size_t count = (size - 24) / 4;
            std::vector<float> levels(count);
            std::memcpy(levels.data(), data + 24, count * 4);
            const bool match = want.empty() ? exactly_ours(levels) : is_quiet(levels, entry.quiet_level);
            if (vt == 0x2004 && match) {
                const auto back = back_levels(want.empty() ? nullptr : &entry, count);
                std::memcpy(data + 24, back.data(), count * 4);
                if (RegSetValueExW(volume_key, L"4", 0, REG_BINARY, data, size) == ERROR_SUCCESS) ++fixed;
            }
        }
        RegCloseKey(volume_key);
    }
    RegCloseKey(store);
    return fixed;
}

RestoreResult restore_all(const std::wstring& path) {
    RestoreResult result;
    const auto entries = load_restore_list(path);
    std::vector<bool> seen(entries.size(), false);
    for (const auto& s : list_sessions()) {
        if (s.state == AudioSessionStateExpired) continue;  // that app has already closed this session
        const QuietEntry* match = nullptr;
        for (size_t i = 0; i < entries.size(); ++i) {
            const auto& e = entries[i];
            if (e.instance_id == s.instance_id || (!e.exe.empty() && lower(e.exe) == lower(s.exe))) {
                match = &e;
                seen[i] = true;
                break;
            }
        }
        auto volume = s.channel_volume();
        const auto now = channel_volumes(volume.Get());
        // Fix listed apps that are still quiet, and any session left at exactly our quiet level.
        const bool fix = match ? is_quiet(now, match->quiet_level) : exactly_ours(now);
        if (!fix) continue;
        const HRESULT hr = set_channel_volumes(volume.Get(), back_levels(match, now.size()));
        result.log.push_back({{"pid", s.pid}, {"exe", utf8(s.exe)}, {"result", hr_text(hr)}});
        if (SUCCEEDED(hr)) ++result.restored;
        else ++result.failed;
    }
    // Apps that aren't playing now: put back the volume Windows remembered for them.
    std::vector<QuietEntry> pending;
    for (size_t i = 0; i < entries.size(); ++i) {
        if (seen[i]) continue;
        const int fixed = fix_remembered_volume(entries[i]);
        result.remembered += fixed;
        if (fixed > 0) result.log.push_back({{"exe", utf8(entries[i].exe)}, {"result", "remembered volume put back"}});
        // If the app is still running (just not playing), Windows may remember the quiet volume
        // when it quits later, so keep it on the list until it's seen again.
        bool running = false;
        if (entries[i].pid) {
            const std::wstring now_exe = process_path(entries[i].pid);
            running = !now_exe.empty() && lower(now_exe) == lower(entries[i].exe);
        }
        if (running) pending.push_back(entries[i]);
    }
    // Anything else Windows remembers at exactly our quiet level (for example from a lost list).
    result.remembered += fix_remembered_volume(QuietEntry{});
    result.pending = int(pending.size());
    std::error_code ec;
    if (result.failed == 0 && pending.empty()) fs::remove(fs::path(path), ec);
    else if (result.failed == 0) save_restore_list(path, pending);
    return result;
}

void set_restore_at_sign_in(const std::wstring& command) {
    HKEY key = nullptr;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, kRunOnceKey, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr) !=
        ERROR_SUCCESS)
        return;
    if (command.empty()) {
        RegDeleteValueW(key, kRunOnceName);
    } else {
        RegSetValueExW(key, kRunOnceName, 0, REG_SZ, reinterpret_cast<const BYTE*>(command.c_str()),
                       DWORD((command.size() + 1) * sizeof(wchar_t)));
    }
    RegCloseKey(key);
}

void update_sign_in_safety_net(const std::wstring& command, bool busy) {
    if (command.empty()) return;
    std::error_code ec;
    const bool needed = busy || fs::exists(fs::path(restore_file_path()), ec) || default_mic_taken();
    set_restore_at_sign_in(needed ? command : L"");
}

// ---------------- QuietKeeper ----------------

QuietKeeper::QuietKeeper(std::wstring list_path, std::wstring restore_command)
    : path_(std::move(list_path)), restore_command_(std::move(restore_command)) {}

QuietKeeper::~QuietKeeper() { restore_everything(); }

int QuietKeeper::quieted() const {
    std::lock_guard<std::mutex> lock(lock_);
    return int(ours_.size());
}

void QuietKeeper::update(const std::vector<Session>& sessions, const std::function<bool(const Session&)>& wanted) {
    std::lock_guard<std::mutex> lock(lock_);
    std::set<std::wstring> alive;
    const auto entries = load_restore_list(path_);
    for (const auto& s : sessions) {
        if (s.state == AudioSessionStateExpired) continue;
        alive.insert(s.instance_id);
        auto volume = s.channel_volume();
        if (!volume) continue;
        const auto levels = channel_volumes(volume.Get());
        const bool is_ours = ours_.count(s.instance_id) > 0;
        if (wanted(s)) {
            if (!is_ours || !is_quiet(levels, kQuietLevel)) {
                if (SUCCEEDED(quiet_session(s, kQuietLevel, path_))) ours_[s.instance_id] = s;
            }
            continue;
        }
        const QuietEntry* listed = nullptr;
        for (const auto& e : entries)
            if (e.instance_id == s.instance_id || (!e.exe.empty() && lower(e.exe) == lower(s.exe))) listed = &e;
        if (is_ours || (listed && is_quiet(levels, listed->quiet_level)) || exactly_ours(levels)) {
            // Not wanted any more (or left quiet by an earlier run): put it back.
            if (SUCCEEDED(set_channel_volumes(volume.Get(), back_levels(listed, levels.size())))) {
                ours_.erase(s.instance_id);
                if (listed) remove_from_list(path_, listed->instance_id);
            }
        }
    }
    // Sessions we quieted that are gone: their app quit while quiet. Windows remembers that
    // volume when the session ends, so a few seconds later put the remembered one back.
    const auto now = std::chrono::steady_clock::now();
    for (auto it = ours_.begin(); it != ours_.end();) {
        if (alive.count(it->first)) {
            ++it;
            continue;
        }
        gone_[it->first] = now;
        it = ours_.erase(it);
    }
    for (auto it = gone_.begin(); it != gone_.end();) {
        if (now - it->second < std::chrono::seconds(3)) {
            ++it;
            continue;
        }
        for (const auto& e : entries) {
            if (e.instance_id != it->first) continue;
            fix_remembered_volume(e);
            remove_from_list(path_, e.instance_id);
        }
        it = gone_.erase(it);
    }
    sync_sign_in_entry();
}

void QuietKeeper::restore_everything() {
    std::lock_guard<std::mutex> lock(lock_);
    const auto entries = load_restore_list(path_);
    for (auto& [id, s] : ours_) {
        const QuietEntry* listed = nullptr;
        for (const auto& e : entries)
            if (e.instance_id == id) listed = &e;
        auto volume = s.channel_volume();
        const auto levels = channel_volumes(volume.Get());
        if (!levels.empty() && is_quiet(levels, kQuietLevel)) set_channel_volumes(volume.Get(), back_levels(listed, levels.size()));
    }
    ours_.clear();
    gone_.clear();
    try {
        restore_all(path_);
    } catch (const std::exception&) {
    }
    sync_sign_in_entry();
}

void QuietKeeper::sync_sign_in_entry() {
    std::error_code ec;
    update_sign_in_safety_net(restore_command_, !ours_.empty() || !gone_.empty() || fs::exists(fs::path(path_), ec));
}

}  // namespace ps
