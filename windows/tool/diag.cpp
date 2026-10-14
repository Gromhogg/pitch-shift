// diag: everything about this PC's sound setup, as JSON (for bug reports and the GitHub checks).
#include "tool/tool.h"

#include "win/cable.h"
#include "win/devices.h"
#include "win/process.h"
#include "win/quiet.h"
#include "win/sessions.h"

namespace ps::tool {

namespace {
std::string run_once_value() {
    wchar_t buf[1024];
    DWORD size = sizeof(buf);
    if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce", L"!PitchShiftRestore",
                     RRF_RT_REG_SZ, nullptr, buf, &size) != ERROR_SUCCESS)
        return "";
    return utf8(buf);
}
}  // namespace

int diag(const Args&) {
    ComScope com;
    nlohmann::json j;
    j["tool"] = "2.0.0-beta";
    j["os"] = os_text();
    j["machine"] = machine_arch();
    j["build"] = process_arch();
    j["endpoints"] = endpoints_json();
    auto sessions = nlohmann::json::array();
    for (const auto& s : list_sessions()) sessions.push_back(session_json(s));
    j["sessions"] = sessions;
    const auto cable = find_cable();
    j["cable"] = {{"present", cable.present},
                  {"mic", utf8(cable.mic_name)},
                  {"feed", utf8(cable.feed_name)},
                  {"restart_needed", cable_restart_needed()}};
    j["restore_file"] = utf8(restore_file_path());
    auto pending = nlohmann::json::array();
    for (const auto& e : load_restore_list(restore_file_path()))
        pending.push_back({{"exe", utf8(e.exe)}, {"original", e.original}});
    j["restore_pending"] = pending;
    j["restore_at_sign_in"] = run_once_value();
    say(j.dump(2));
    return 0;
}

}  // namespace ps::tool
