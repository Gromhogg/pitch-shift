// Starting and stopping helper processes, and facts about this PC.
#pragma once
#include "win/com.h"

#include <memory>
#include <string>

namespace ps {

class ChildProcess {
public:
    ChildProcess(HANDLE process, DWORD pid) : process_(process), pid_(pid) {}
    ~ChildProcess();
    ChildProcess(const ChildProcess&) = delete;
    ChildProcess& operator=(const ChildProcess&) = delete;

    DWORD pid() const { return pid_; }
    bool running() const;
    bool wait(DWORD ms) const;     // true if it ended in time
    DWORD exit_code() const;
    void kill();                   // ends it at once, like a crash

private:
    HANDLE process_;
    DWORD pid_;
};

std::wstring self_path();  // this program's own .exe

// Runs `exe` with `args` (no window). Throws if it can't start.
std::unique_ptr<ChildProcess> start_process(const std::wstring& exe, const std::wstring& args);

std::string os_text();         // like "Windows 10.0.26100"
DWORD os_build();
std::string machine_arch();    // the PC's real processor: "x64" or "arm64"
std::string process_arch();    // what this program was built for

}  // namespace ps
