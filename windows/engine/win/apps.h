// Running programs: which process started which, and which "app" a sound session belongs to.
// Browsers and many apps play sound from a helper process (Chrome's audio service, Spotify's
// helpers...). Those are grouped under the app's main process, like the Mac app does.
#pragma once
#include "win/com.h"

#include <map>
#include <set>
#include <string>
#include <vector>

namespace ps {

struct ProcessInfo {
    DWORD pid = 0;
    DWORD parent = 0;
    std::wstring exe_name;  // like "chrome.exe"
};

class ProcessSnapshot {
public:
    ProcessSnapshot();  // takes a snapshot of all running processes now
    const ProcessInfo* find(DWORD pid) const;
    std::set<DWORD> tree(DWORD root) const;  // root and everything it started (and they started)
    bool in_tree(DWORD pid, DWORD root) const;
    std::vector<DWORD> with_exe_name(const std::wstring& exe_name) const;
    // The app's main process: walks up through parents that run from the same program folder.
    DWORD app_root(DWORD pid) const;

private:
    std::map<DWORD, ProcessInfo> by_pid_;
};

std::wstring native_process_path(DWORD pid);  // like \Device\HarddiskVolume3\Program Files\...
std::wstring native_path_of(const std::wstring& win32_path);
std::wstring app_display_name(const std::wstring& exe_path);  // the program's own description, or its file name
std::wstring folder_of(const std::wstring& path);
std::wstring file_name_of(const std::wstring& path);

}  // namespace ps
