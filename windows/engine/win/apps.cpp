#include "win/apps.h"

#include "win/sessions.h"

#include <tlhelp32.h>

#include <iterator>
#include <vector>

namespace ps {

ProcessSnapshot::ProcessSnapshot() {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return;
    PROCESSENTRY32W entry{};
    entry.dwSize = sizeof entry;
    if (Process32FirstW(snap, &entry)) {
        do {
            ProcessInfo p;
            p.pid = entry.th32ProcessID;
            p.parent = entry.th32ParentProcessID;
            p.exe_name = lower(entry.szExeFile);
            by_pid_[p.pid] = p;
        } while (Process32NextW(snap, &entry));
    }
    CloseHandle(snap);
}

const ProcessInfo* ProcessSnapshot::find(DWORD pid) const {
    auto it = by_pid_.find(pid);
    return it == by_pid_.end() ? nullptr : &it->second;
}

std::set<DWORD> ProcessSnapshot::tree(DWORD root) const {
    std::set<DWORD> out;
    if (!find(root)) return out;
    out.insert(root);
    bool grew = true;
    while (grew) {
        grew = false;
        for (const auto& [pid, p] : by_pid_) {
            if (!out.count(pid) && out.count(p.parent) && pid != p.parent) {
                out.insert(pid);
                grew = true;
            }
        }
    }
    return out;
}

bool ProcessSnapshot::in_tree(DWORD pid, DWORD root) const {
    // Walk up the parents (with a limit, in case of loops from reused process ids).
    for (int i = 0; i < 64 && pid != 0; ++i) {
        if (pid == root) return true;
        const auto* p = find(pid);
        if (!p) return false;
        pid = p->parent;
    }
    return false;
}

std::vector<DWORD> ProcessSnapshot::with_exe_name(const std::wstring& exe_name) const {
    std::vector<DWORD> out;
    const std::wstring want = lower(exe_name);
    for (const auto& [pid, p] : by_pid_)
        if (p.exe_name == want) out.push_back(pid);
    return out;
}

DWORD ProcessSnapshot::app_root(DWORD pid) const {
    std::wstring folder = lower(folder_of(process_path(pid)));
    if (folder.empty()) return pid;
    DWORD root = pid;
    for (int i = 0; i < 32; ++i) {
        const auto* p = find(root);
        if (!p || p->parent == 0 || p->parent == root) break;
        const auto* parent = find(p->parent);
        if (!parent) break;
        // Same program, or another program from the same folder (an app's helpers live next to it).
        const bool same_program = parent->exe_name == p->exe_name;
        const bool same_folder = lower(folder_of(process_path(p->parent))) == folder;
        if (!same_program && !same_folder) break;
        root = p->parent;
    }
    return root;
}

std::wstring native_process_path(DWORD pid) {
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process) return {};
    wchar_t buf[MAX_PATH * 4];
    DWORD size = DWORD(std::size(buf));
    std::wstring out;
    if (QueryFullProcessImageNameW(process, PROCESS_NAME_NATIVE, buf, &size)) out.assign(buf, size);
    CloseHandle(process);
    return out;
}

std::wstring native_path_of(const std::wstring& win32_path) {
    if (win32_path.size() < 3 || win32_path[1] != L':') return {};
    const std::wstring drive = win32_path.substr(0, 2);
    wchar_t device[MAX_PATH];
    if (!QueryDosDeviceW(drive.c_str(), device, MAX_PATH)) return {};
    return std::wstring(device) + win32_path.substr(2);
}

std::wstring folder_of(const std::wstring& path) {
    const auto slash = path.find_last_of(L"\\/");
    return slash == std::wstring::npos ? std::wstring() : path.substr(0, slash + 1);
}

std::wstring file_name_of(const std::wstring& path) {
    const auto slash = path.find_last_of(L"\\/");
    return slash == std::wstring::npos ? path : path.substr(slash + 1);
}

std::wstring app_display_name(const std::wstring& exe_path) {
    std::wstring fallback = file_name_of(exe_path);
    const auto dot = fallback.find_last_of(L'.');
    if (dot != std::wstring::npos) fallback = fallback.substr(0, dot);
    DWORD ignored = 0;
    const DWORD size = GetFileVersionInfoSizeW(exe_path.c_str(), &ignored);
    if (size == 0) return fallback;
    std::vector<BYTE> data(size);
    if (!GetFileVersionInfoW(exe_path.c_str(), 0, size, data.data())) return fallback;
    struct Translation {
        WORD language, codepage;
    }* translations = nullptr;
    UINT bytes = 0;
    if (!VerQueryValueW(data.data(), L"\\VarFileInfo\\Translation", reinterpret_cast<void**>(&translations), &bytes) ||
        bytes < sizeof(Translation))
        return fallback;
    for (const wchar_t* field : {L"FileDescription", L"ProductName"}) {
        wchar_t key[128];
        swprintf_s(key, L"\\StringFileInfo\\%04x%04x\\%s", translations[0].language, translations[0].codepage, field);
        wchar_t* value = nullptr;
        UINT len = 0;
        if (VerQueryValueW(data.data(), key, reinterpret_cast<void**>(&value), &len) && value && len > 1) {
            std::wstring text(value);
            while (!text.empty() && iswspace(text.back())) text.pop_back();
            if (!text.empty()) return text;
        }
    }
    return fallback;
}

}  // namespace ps
