#include "win/sessions.h"

#include "win/devices.h"

#include <iterator>

namespace ps {

// {5C7A4E1B-8F2D-4B6A-9E3C-1D2F7A8B9C01}
const GUID kPitchShiftEventContext = {0x5c7a4e1b, 0x8f2d, 0x4b6a, {0x9e, 0x3c, 0x1d, 0x2f, 0x7a, 0x8b, 0x9c, 0x01}};

ComPtr<ISimpleAudioVolume> Session::simple_volume() const {
    ComPtr<ISimpleAudioVolume> v;
    if (control) control.As(&v);
    return v;
}

ComPtr<IChannelAudioVolume> Session::channel_volume() const {
    ComPtr<IChannelAudioVolume> v;
    if (control) control.As(&v);
    return v;
}

std::wstring process_path(DWORD pid) {
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process) return {};
    wchar_t buf[MAX_PATH * 4];
    DWORD size = DWORD(std::size(buf));
    std::wstring out;
    if (QueryFullProcessImageNameW(process, 0, buf, &size)) out.assign(buf, size);
    CloseHandle(process);
    return out;
}

std::vector<Session> list_sessions() {
    std::vector<Session> out;
    for (const auto& endpoint : list_endpoints(eRender, DEVICE_STATE_ACTIVE)) {
        ComPtr<IMMDevice> device;
        try {
            device = device_by_id(endpoint.id);
        } catch (const std::exception&) {
            continue;
        }
        // A new session manager each time: an old one may not list sessions that started later.
        ComPtr<IAudioSessionManager2> manager;
        if (FAILED(device->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL, nullptr,
                                    reinterpret_cast<void**>(manager.GetAddressOf()))))
            continue;
        ComPtr<IAudioSessionEnumerator> sessions;
        if (FAILED(manager->GetSessionEnumerator(&sessions))) continue;
        int count = 0;
        sessions->GetCount(&count);
        for (int i = 0; i < count; ++i) {
            ComPtr<IAudioSessionControl> control;
            if (FAILED(sessions->GetSession(i, &control))) continue;
            Session s;
            if (FAILED(control.As(&s.control))) continue;
            s.control->GetProcessId(&s.pid);
            s.system_sounds = s.control->IsSystemSoundsSession() == S_OK;
            s.control->GetState(&s.state);
            CoMem<wchar_t> text;
            if (SUCCEEDED(s.control->GetSessionInstanceIdentifier(text.put())) && text.get()) s.instance_id = text.get();
            CoMem<wchar_t> sid;
            if (SUCCEEDED(s.control->GetSessionIdentifier(sid.put())) && sid.get()) s.session_id = sid.get();
            CoMem<wchar_t> name;
            if (SUCCEEDED(s.control->GetDisplayName(name.put())) && name.get()) s.display_name = name.get();
            s.endpoint_id = endpoint.id;
            s.endpoint_name = endpoint.name;
            if (s.pid != 0) s.exe = process_path(s.pid);
            out.push_back(std::move(s));
        }
    }
    return out;
}

std::vector<Session> sessions_of(DWORD pid) {
    std::vector<Session> out;
    for (auto& s : list_sessions())
        if (s.pid == pid) out.push_back(std::move(s));
    return out;
}

std::vector<float> channel_volumes(IChannelAudioVolume* volume) {
    if (!volume) return {};
    UINT32 count = 0;
    if (FAILED(volume->GetChannelCount(&count)) || count == 0) return {};
    std::vector<float> levels(count);
    if (FAILED(volume->GetAllVolumes(count, levels.data()))) return {};
    return levels;
}

HRESULT set_channel_volumes(IChannelAudioVolume* volume, const std::vector<float>& levels) {
    if (!volume || levels.empty()) return E_POINTER;
    return volume->SetAllVolumes(UINT32(levels.size()), levels.data(), &kPitchShiftEventContext);
}

HRESULT set_all_channels(IChannelAudioVolume* volume, float level) {
    if (!volume) return E_POINTER;
    UINT32 count = 0;
    HRESULT hr = volume->GetChannelCount(&count);
    if (FAILED(hr)) return hr;
    if (count == 0) return E_FAIL;
    std::vector<float> levels(count, level);
    return volume->SetAllVolumes(count, levels.data(), &kPitchShiftEventContext);
}

nlohmann::json session_json(const Session& s) {
    nlohmann::json j = {{"pid", s.pid},
                        {"exe", utf8(s.exe)},
                        {"display_name", utf8(s.display_name)},
                        {"state", s.state == AudioSessionStateActive     ? "active"
                                  : s.state == AudioSessionStateInactive ? "inactive"
                                                                         : "expired"},
                        {"system_sounds", s.system_sounds},
                        {"endpoint", utf8(s.endpoint_name)},
                        {"session_id", utf8(s.session_id)},
                        {"instance_id", utf8(s.instance_id)}};
    if (auto simple = s.simple_volume()) {
        float level = -1;
        BOOL mute = FALSE;
        simple->GetMasterVolume(&level);
        simple->GetMute(&mute);
        j["volume"] = level;
        j["mute"] = bool(mute);
    }
    j["channel_volumes"] = channel_volumes(s.channel_volume().Get());
    return j;
}

}  // namespace ps
