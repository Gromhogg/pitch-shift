#include "win/devices.h"

#include "win/policy_config.h"

#include <audioclient.h>
#include <ksmedia.h>
#include <mmreg.h>

#include <cstdio>

namespace ps {

namespace {

std::wstring read_string(IPropertyStore* store, const PROPERTYKEY& key) {
    PROPVARIANT value;
    PropVariantInit(&value);
    std::wstring out;
    if (SUCCEEDED(store->GetValue(key, &value)) && value.vt == VT_LPWSTR && value.pwszVal) out = value.pwszVal;
    PropVariantClear(&value);
    return out;
}

Endpoint describe(IMMDevice* device, EDataFlow flow) {
    Endpoint e;
    e.render = flow == eRender;
    CoMem<wchar_t> id;
    if (SUCCEEDED(device->GetId(id.put())) && id.get()) e.id = id.get();
    device->GetState(&e.state);
    ComPtr<IPropertyStore> store;
    if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, &store))) {
        e.name = read_string(store.Get(), kDeviceFriendlyName);
        e.description = read_string(store.Get(), kDeviceDesc);
        e.adapter = read_string(store.Get(), kAdapterName);
    }
    return e;
}

}  // namespace

ComPtr<IMMDeviceEnumerator> device_enumerator() {
    ComPtr<IMMDeviceEnumerator> enumerator;
    check(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator)),
          "Could not open the list of sound devices");
    return enumerator;
}

ComPtr<IMMDevice> device_by_id(const std::wstring& id) {
    ComPtr<IMMDevice> device;
    check(device_enumerator()->GetDevice(id.c_str(), &device), "Could not find the sound device");
    return device;
}

std::wstring default_endpoint_id(EDataFlow flow, ERole role) {
    ComPtr<IMMDevice> device;
    if (FAILED(device_enumerator()->GetDefaultAudioEndpoint(flow, role, &device))) return {};
    CoMem<wchar_t> id;
    if (FAILED(device->GetId(id.put())) || !id.get()) return {};
    return id.get();
}

std::vector<Endpoint> list_endpoints(EDataFlow flow, DWORD state_mask) {
    std::vector<Endpoint> out;
    auto enumerator = device_enumerator();
    ComPtr<IMMDeviceCollection> devices;
    if (FAILED(enumerator->EnumAudioEndpoints(flow, state_mask, &devices))) return out;
    UINT count = 0;
    devices->GetCount(&count);
    const std::wstring console = default_endpoint_id(flow, eConsole);
    const std::wstring comms = default_endpoint_id(flow, eCommunications);
    for (UINT i = 0; i < count; ++i) {
        ComPtr<IMMDevice> device;
        if (FAILED(devices->Item(i, &device))) continue;
        Endpoint e = describe(device.Get(), flow);
        e.default_console = !e.id.empty() && e.id == console;
        e.default_communications = !e.id.empty() && e.id == comms;
        out.push_back(std::move(e));
    }
    return out;
}

std::optional<Endpoint> find_endpoint(EDataFlow flow, const std::wstring& name_part) {
    const std::wstring want = lower(name_part);
    for (auto& e : list_endpoints(flow, DEVICE_STATE_ACTIVE)) {
        if (lower(e.name).find(want) != std::wstring::npos || lower(e.description).find(want) != std::wstring::npos)
            return e;
    }
    return std::nullopt;
}

HRESULT set_default_endpoint(const std::wstring& id, ERole role) {
    ComPtr<IPolicyConfig> policy;
    const HRESULT hr = open_policy_config(policy);
    if (FAILED(hr)) return hr;
    return policy->SetDefaultEndpoint(id.c_str(), role);
}

HRESULT set_default_endpoint_all(const std::wstring& id) {
    HRESULT result = S_OK;
    for (ERole role : {eConsole, eMultimedia, eCommunications}) {
        const HRESULT hr = set_default_endpoint(id, role);
        if (FAILED(hr)) result = hr;
    }
    return result;
}

std::string mix_format_text(IMMDevice* device) {
    ComPtr<IAudioClient> client;
    if (FAILED(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                reinterpret_cast<void**>(client.GetAddressOf()))))
        return "unknown";
    CoMem<WAVEFORMATEX> format;
    if (FAILED(client->GetMixFormat(format.put())) || !format.get()) return "unknown";
    const WAVEFORMATEX* f = format.get();
    bool is_float = f->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
    if (f->wFormatTag == WAVE_FORMAT_EXTENSIBLE && f->cbSize >= 22) {
        const auto* x = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(f);
        is_float = x->SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
    }
    char buf[96];
    std::snprintf(buf, sizeof buf, "%lu Hz, %u ch, %u-bit %s", static_cast<unsigned long>(f->nSamplesPerSec),
                  unsigned(f->nChannels), unsigned(f->wBitsPerSample), is_float ? "float" : "integer");
    return buf;
}

std::string state_text(DWORD state) {
    switch (state) {
        case DEVICE_STATE_ACTIVE: return "active";
        case DEVICE_STATE_DISABLED: return "disabled";
        case DEVICE_STATE_NOTPRESENT: return "not present";
        case DEVICE_STATE_UNPLUGGED: return "unplugged";
        default: return "unknown";
    }
}

nlohmann::json endpoint_json(const Endpoint& e) {
    return {{"name", utf8(e.name)},
            {"description", utf8(e.description)},
            {"adapter", utf8(e.adapter)},
            {"id", utf8(e.id)},
            {"direction", e.render ? "playback" : "recording"},
            {"state", state_text(e.state)},
            {"default", e.default_console},
            {"default_communications", e.default_communications}};
}

nlohmann::json endpoints_json() {
    nlohmann::json list = nlohmann::json::array();
    for (EDataFlow flow : {eRender, eCapture}) {
        for (const auto& e : list_endpoints(flow, DEVICE_STATEMASK_ALL)) {
            auto j = endpoint_json(e);
            if (e.state == DEVICE_STATE_ACTIVE) {
                try {
                    j["mix_format"] = mix_format_text(device_by_id(e.id).Get());
                } catch (const std::exception&) {
                }
            }
            list.push_back(j);
        }
    }
    return list;
}

}  // namespace ps
