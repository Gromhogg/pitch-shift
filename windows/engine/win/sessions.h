// Finds the "sound sessions" of running apps (what the Windows volume mixer lists) and reads or
// changes their volume.
#pragma once
#include "win/com.h"

#include <audiopolicy.h>

#include <nlohmann/json.hpp>
#include <string>
#include <vector>

namespace ps {

// Tags our own volume changes, so we can tell them apart from changes the user makes.
extern const GUID kPitchShiftEventContext;

struct Session {
    DWORD pid = 0;
    std::wstring exe;           // full path of the program
    std::wstring instance_id;   // different for every session
    std::wstring session_id;    // the same for the same app (also after a restart)
    std::wstring endpoint_id;   // which speakers it plays to
    std::wstring endpoint_name;
    std::wstring display_name;
    AudioSessionState state = AudioSessionStateInactive;
    bool system_sounds = false;
    ComPtr<IAudioSessionControl2> control;

    ComPtr<ISimpleAudioVolume> simple_volume() const;    // the app's slider in the volume mixer
    ComPtr<IChannelAudioVolume> channel_volume() const;  // hidden per-channel volume under that slider
};

// Every sound session on every active speaker device.
std::vector<Session> list_sessions();
std::vector<Session> sessions_of(DWORD pid);

std::wstring process_path(DWORD pid);

std::vector<float> channel_volumes(IChannelAudioVolume* volume);  // empty if it can't be read
HRESULT set_channel_volumes(IChannelAudioVolume* volume, const std::vector<float>& levels);
HRESULT set_all_channels(IChannelAudioVolume* volume, float level);

nlohmann::json session_json(const Session& s);

}  // namespace ps
