#include "win/process.h"

#include <cstdio>
#include <vector>

namespace ps {

ChildProcess::~ChildProcess() {
    if (process_) CloseHandle(process_);
}

bool ChildProcess::running() const { return WaitForSingleObject(process_, 0) == WAIT_TIMEOUT; }

bool ChildProcess::wait(DWORD ms) const { return WaitForSingleObject(process_, ms) == WAIT_OBJECT_0; }

DWORD ChildProcess::exit_code() const {
    DWORD code = 0;
    GetExitCodeProcess(process_, &code);
    return code;
}

void ChildProcess::kill() {
    if (running()) {
        TerminateProcess(process_, 9);
        WaitForSingleObject(process_, 5000);
    }
}

std::wstring self_path() {
    std::vector<wchar_t> buf(MAX_PATH);
    for (;;) {
        const DWORD n = GetModuleFileNameW(nullptr, buf.data(), DWORD(buf.size()));
        if (n < buf.size()) return std::wstring(buf.data(), n);
        buf.resize(buf.size() * 2);
    }
}

std::unique_ptr<ChildProcess> start_process(const std::wstring& exe, const std::wstring& args) {
    std::wstring command = L"\"" + exe + L"\" " + args;
    STARTUPINFOW si{};
    si.cb = sizeof si;
    PROCESS_INFORMATION pi{};
    if (!CreateProcessW(exe.c_str(), command.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si,
                        &pi))
        throw WinError("Could not start " + utf8(exe), HRESULT_FROM_WIN32(GetLastError()));
    CloseHandle(pi.hThread);
    return std::make_unique<ChildProcess>(pi.hProcess, pi.dwProcessId);
}

namespace {
using RtlGetVersionFn = LONG(WINAPI*)(OSVERSIONINFOW*);

OSVERSIONINFOW real_version() {
    OSVERSIONINFOW info{};
    info.dwOSVersionInfoSize = sizeof info;
    // GetVersionEx can lie to programs without a manifest; RtlGetVersion doesn't.
    if (HMODULE ntdll = GetModuleHandleW(L"ntdll.dll")) {
        if (auto fn = reinterpret_cast<RtlGetVersionFn>(reinterpret_cast<void*>(GetProcAddress(ntdll, "RtlGetVersion"))))
            fn(&info);
    }
    return info;
}

std::string arch_name(USHORT machine) {
    switch (machine) {
        case IMAGE_FILE_MACHINE_AMD64: return "x64";
        case IMAGE_FILE_MACHINE_ARM64: return "arm64";
        case IMAGE_FILE_MACHINE_I386: return "x86";
        default: return "unknown";
    }
}
}  // namespace

std::string os_text() {
    const auto v = real_version();
    char buf[64];
    std::snprintf(buf, sizeof buf, "Windows %lu.%lu.%lu", static_cast<unsigned long>(v.dwMajorVersion),
                  static_cast<unsigned long>(v.dwMinorVersion), static_cast<unsigned long>(v.dwBuildNumber));
    return buf;
}

DWORD os_build() { return real_version().dwBuildNumber; }

std::string machine_arch() {
    USHORT process = 0, native = 0;
    if (IsWow64Process2(GetCurrentProcess(), &process, &native)) return arch_name(native);
    return process_arch();
}

std::string process_arch() {
#if defined(_M_ARM64) || defined(__aarch64__)
    return "arm64";
#elif defined(_M_X64) || defined(__x86_64__)
    return "x64";
#else
    return "x86";
#endif
}

}  // namespace ps
