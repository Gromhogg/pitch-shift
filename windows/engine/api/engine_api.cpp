// The engine DLL's C interface. For now (first stage) it only lists apps and microphones and
// restores volumes; the music and voice paths are added in the next stages.
#include "api/pitchshift_engine.h"

#include "win/devices.h"
#include "win/process.h"
#include "win/quiet.h"
#include "win/sessions.h"

#include <mutex>
#include <string>

using namespace ps;

namespace {
std::mutex g_lock;
bool g_started = false;

const char* hand_back(std::string text) {
    thread_local std::string kept;
    kept = std::move(text);
    return kept.c_str();
}

std::wstring file_name(const std::wstring& path) {
    const auto slash = path.find_last_of(L"\\/");
    std::wstring name = slash == std::wstring::npos ? path : path.substr(slash + 1);
    const auto dot = name.find_last_of(L'.');
    return dot == std::wstring::npos ? name : name.substr(0, dot);
}
}  // namespace

extern "C" {

PS_API const char* ps_version(void) { return "2.0.0-beta"; }

PS_API int ps_init(void) {
    std::lock_guard<std::mutex> lock(g_lock);
    if (g_started) return 0;
    ComScope com;
    try {
        restore_all(restore_file_path());
    } catch (const std::exception&) {
    }
    g_started = true;
    return 0;
}

PS_API void ps_shutdown(void) {
    std::lock_guard<std::mutex> lock(g_lock);
    ComScope com;
    try {
        restore_all(restore_file_path());
    } catch (const std::exception&) {
    }
    g_started = false;
}

PS_API int ps_restore_all(void) {
    ComScope com;
    try {
        return restore_all(restore_file_path()).restored;
    } catch (const std::exception&) {
        return -1;
    }
}

PS_API const char* ps_list_sources_json(void) {
    ComScope com;
    nlohmann::json list = nlohmann::json::array();
    try {
        const DWORD self = GetCurrentProcessId();
        for (const auto& s : list_sessions()) {
            if (s.pid == 0 || s.pid == self || s.system_sounds) continue;
            list.push_back({{"pid", s.pid}, {"exe", utf8(s.exe)}, {"name", utf8(file_name(s.exe))},
                            {"active", s.state == AudioSessionStateActive}});
        }
    } catch (const std::exception&) {
    }
    return hand_back(list.dump());
}

PS_API const char* ps_list_mics_json(void) {
    ComScope com;
    nlohmann::json list = nlohmann::json::array();
    try {
        for (const auto& e : list_endpoints(eCapture, DEVICE_STATE_ACTIVE)) {
            // The virtual cable is where our shifted voice goes, so it can't be a source.
            if (lower(e.adapter).find(L"vb-audio") != std::wstring::npos) continue;
            list.push_back({{"id", utf8(e.id)}, {"name", utf8(e.name)}, {"default", e.default_communications}});
        }
    } catch (const std::exception&) {
    }
    return hand_back(list.dump());
}

PS_API const char* ps_status_json(void) {
    nlohmann::json j = {{"version", ps_version()}, {"started", g_started}, {"arch", process_arch()}};
    return hand_back(j.dump());
}

}  // extern "C"
