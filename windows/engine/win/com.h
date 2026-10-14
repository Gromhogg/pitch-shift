// Small helpers for talking to Windows' sound system (which uses COM objects).
#pragma once
#include <windows.h>
#include <objbase.h>
#include <wrl/client.h>

#include <stdexcept>
#include <string>

namespace ps {

using Microsoft::WRL::ComPtr;

// Starts COM on this thread for as long as the object lives.
class ComScope {
public:
    explicit ComScope(DWORD mode = COINIT_MULTITHREADED) : hr_(CoInitializeEx(nullptr, mode)) {}
    ~ComScope() {
        if (SUCCEEDED(hr_)) CoUninitialize();
    }
    ComScope(const ComScope&) = delete;
    ComScope& operator=(const ComScope&) = delete;

private:
    HRESULT hr_;
};

// A Windows error with its code, like "Initialize: 0x88890008 (AUDCLNT_E_UNSUPPORTED_FORMAT)".
struct WinError : std::runtime_error {
    HRESULT hr;
    WinError(const std::string& what, HRESULT code);
};

std::string hr_text(HRESULT hr);

inline void check(HRESULT hr, const char* what) {
    if (FAILED(hr)) throw WinError(what, hr);
}

std::string utf8(const std::wstring& text);
std::wstring wide(const std::string& text);
std::wstring lower(std::wstring text);

// Memory that Windows hands back and expects us to free with CoTaskMemFree.
template <typename T>
class CoMem {
public:
    CoMem() = default;
    ~CoMem() {
        if (p_) CoTaskMemFree(p_);
    }
    CoMem(const CoMem&) = delete;
    CoMem& operator=(const CoMem&) = delete;
    T** put() { return &p_; }
    T* get() const { return p_; }

private:
    T* p_ = nullptr;
};

}  // namespace ps
