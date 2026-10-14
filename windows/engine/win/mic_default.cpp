#include "win/mic_default.h"

#include "win/cable.h"
#include "win/devices.h"
#include "win/quiet.h"

#include <filesystem>
#include <fstream>
#include <nlohmann/json.hpp>

namespace ps {

namespace fs = std::filesystem;

namespace {
const ERole kRoles[] = {eConsole, eMultimedia, eCommunications};
const char* role_name(ERole role) {
    return role == eConsole ? "console" : role == eMultimedia ? "multimedia" : "communications";
}

nlohmann::json load() {
    std::ifstream f{fs::path(mic_defaults_path()), std::ios::binary};
    if (!f) return nullptr;
    try {
        return nlohmann::json::parse(f);
    } catch (const std::exception&) {
        return nullptr;
    }
}

bool active_capture(const std::wstring& id) {
    if (id.empty()) return false;
    for (const auto& e : list_endpoints(eCapture, DEVICE_STATE_ACTIVE))
        if (e.id == id) return true;
    return false;
}

// Any real microphone (not the virtual cable).
std::wstring some_real_mic(const std::wstring& cable_mic) {
    for (const auto& e : list_endpoints(eCapture, DEVICE_STATE_ACTIVE))
        if (e.id != cable_mic && lower(e.adapter) != L"vb-audio virtual cable") return e.id;
    return {};
}
}  // namespace

std::wstring mic_defaults_path() {
    return (fs::path(restore_file_path()).parent_path() / L"mic-defaults.json").wstring();
}

bool default_mic_taken() {
    std::error_code ec;
    return fs::exists(fs::path(mic_defaults_path()), ec);
}

HRESULT take_default_mic(const std::wstring& cable_mic) {
    if (cable_mic.empty()) return E_INVALIDARG;
    if (!default_mic_taken()) {
        nlohmann::json j = {{"cable_mic", utf8(cable_mic)}};
        for (ERole role : kRoles) j[role_name(role)] = utf8(default_endpoint_id(eCapture, role));
        std::error_code ec;
        fs::create_directories(fs::path(mic_defaults_path()).parent_path(), ec);
        std::ofstream f{fs::path(mic_defaults_path()), std::ios::binary | std::ios::trunc};
        f << j.dump(2);
        f.flush();
        if (!f) return HRESULT_FROM_WIN32(ERROR_WRITE_FAULT);
    }
    HRESULT result = S_OK;
    for (ERole role : kRoles) {
        if (default_endpoint_id(eCapture, role) == cable_mic) continue;
        const HRESULT hr = set_default_endpoint(cable_mic, role);
        if (FAILED(hr)) result = hr;
    }
    return result;
}

int give_back_default_mic() {
    const auto j = load();
    if (j.is_null()) {
        std::error_code ec;
        fs::remove(fs::path(mic_defaults_path()), ec);
        return 0;
    }
    const std::wstring cable_mic = wide(j.value("cable_mic", ""));
    int changed = 0;
    bool all_ok = true;
    for (ERole role : kRoles) {
        if (default_endpoint_id(eCapture, role) != cable_mic) continue;  // the person changed it: leave it
        std::wstring back = wide(j.value(role_name(role), ""));
        if (back == cable_mic) continue;  // it was already the default before
        if (!active_capture(back)) back = some_real_mic(cable_mic);  // that mic is gone: use another real one
        if (back.empty()) continue;  // no other microphone at all
        if (SUCCEEDED(set_default_endpoint(back, role))) ++changed;
        else all_ok = false;
    }
    if (all_ok) {
        std::error_code ec;
        fs::remove(fs::path(mic_defaults_path()), ec);
    }
    return changed;
}

std::wstring remembered_mic() {
    const auto j = load();
    if (j.is_null()) return {};
    const std::wstring cable_mic = wide(j.value("cable_mic", ""));
    for (const char* role : {"communications", "console"}) {
        const std::wstring id = wide(j.value(role, ""));
        if (!id.empty() && id != cable_mic) return id;
    }
    return {};
}

}  // namespace ps
