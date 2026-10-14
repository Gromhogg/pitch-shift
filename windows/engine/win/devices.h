// Finds speakers, headphones and microphones ("endpoints"), and reads or sets the default ones.
#pragma once
#include "win/com.h"

#include <mmdeviceapi.h>

#include <nlohmann/json.hpp>
#include <optional>
#include <string>
#include <vector>

namespace ps {

struct Endpoint {
    std::wstring id;
    std::wstring name;         // full name, like "CABLE Input (VB-Audio Virtual Cable)"
    std::wstring description;  // short name, like "CABLE Input"
    std::wstring adapter;      // like "VB-Audio Virtual Cable"
    bool render = true;        // true = plays sound, false = records sound
    DWORD state = 0;
    bool default_console = false;
    bool default_communications = false;
};

ComPtr<IMMDeviceEnumerator> device_enumerator();
ComPtr<IMMDevice> device_by_id(const std::wstring& id);

std::vector<Endpoint> list_endpoints(EDataFlow flow, DWORD state_mask = DEVICE_STATE_ACTIVE);

// First active endpoint whose name contains `name_part` (not case sensitive).
std::optional<Endpoint> find_endpoint(EDataFlow flow, const std::wstring& name_part);

// Empty if there is no default.
std::wstring default_endpoint_id(EDataFlow flow, ERole role);

// Makes `id` the default for one role, using the same Windows interface as the Sound control panel.
HRESULT set_default_endpoint(const std::wstring& id, ERole role);
// Makes `id` the default for all roles (console, multimedia, communications).
HRESULT set_default_endpoint_all(const std::wstring& id);

// The device's own mix format, as text like "48000 Hz, 2 ch, 32-bit float".
std::string mix_format_text(IMMDevice* device);

nlohmann::json endpoint_json(const Endpoint& e);
nlohmann::json endpoints_json();  // every endpoint, both directions, any state
std::string state_text(DWORD state);

}  // namespace ps
