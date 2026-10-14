// diag: everything about this PC's sound setup, as JSON (for bug reports and the GitHub checks).
#include "tool/tool.h"

#include "win/devices.h"
#include "win/process.h"
#include "win/quiet.h"
#include "win/sessions.h"

namespace ps::tool {

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
    j["restore_file"] = utf8(restore_file_path());
    j["restore_pending"] = load_restore_list(restore_file_path()).size();
    say(j.dump(2));
    return 0;
}

}  // namespace ps::tool
