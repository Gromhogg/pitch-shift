#include "win/quiet.h"

#include <filesystem>
#include <fstream>
#include <iterator>

namespace ps {

namespace fs = std::filesystem;

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
            e.pid = item.value("pid", 0u);
            e.instance_id = wide(item.value("instance_id", ""));
            e.original = item.value("original", std::vector<float>{});
            e.quiet_level = item.value("quiet_level", 0.001f);
            out.push_back(std::move(e));
        }
    } catch (const std::exception&) {
        // A damaged list: treat it as empty (restore_all still sets anything left quiet back to full).
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
        e.pid = session.pid;
        e.instance_id = session.instance_id;
        e.original = channel_volumes(volume.Get());
        e.quiet_level = level;
        if (e.original.empty()) return E_FAIL;
        entries.push_back(e);
        if (!save_restore_list(path, entries)) return HRESULT_FROM_WIN32(ERROR_WRITE_FAULT);
    }
    return set_all_channels(volume.Get(), level);
}

RestoreResult restore_all(const std::wstring& path) {
    RestoreResult result;
    const auto entries = load_restore_list(path);
    if (entries.empty()) {
        std::error_code ec;
        fs::remove(fs::path(path), ec);
        return result;
    }
    std::vector<bool> seen(entries.size(), false);
    const auto sessions = list_sessions();
    for (const auto& s : sessions) {
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
        if (!match) continue;
        auto volume = s.channel_volume();
        const auto now = channel_volumes(volume.Get());
        if (now.empty()) continue;
        bool still_quiet = true;
        for (float v : now) still_quiet = still_quiet && v <= match->quiet_level * 1.01f + 1e-6f;
        if (!still_quiet) continue;  // already back to normal (or the user changed it)
        std::vector<float> back = match->original;
        if (back.size() != now.size()) back.assign(now.size(), 1.0f);
        const HRESULT hr = set_channel_volumes(volume.Get(), back);
        result.log.push_back({{"pid", s.pid}, {"exe", utf8(s.exe)}, {"result", hr_text(hr)}});
        if (SUCCEEDED(hr)) ++result.restored;
        else ++result.failed;
    }
    // Apps that aren't playing right now stay on the list, in case Windows brings back the quiet
    // volume the next time they play.
    std::vector<QuietEntry> pending;
    for (size_t i = 0; i < entries.size(); ++i)
        if (!seen[i]) pending.push_back(entries[i]);
    result.pending = int(pending.size());
    if (result.failed == 0 && pending.empty()) {
        std::error_code ec;
        fs::remove(fs::path(path), ec);
    } else if (result.failed == 0) {
        save_restore_list(path, pending);
    }
    return result;
}

}  // namespace ps
