// The virtual microphone: VB-CABLE by VB-Audio (donationware, vb-cable.com).
// Whatever plays into its playback side ("Pitch Shift Mic Feed", originally "CABLE Input")
// comes out of its recording side ("Pitch Shift Mic", originally "CABLE Output"), which people
// pick as their microphone in Discord or Zoom.
#pragma once
#include "win/com.h"

#include <nlohmann/json.hpp>
#include <string>
#include <vector>

namespace ps {

constexpr const wchar_t* kFeedName = L"Pitch Shift Mic Feed";
constexpr const wchar_t* kMicName = L"Pitch Shift Mic";
constexpr const wchar_t* kSettingsKey = L"SOFTWARE\\Pitch Shift";  // in HKLM, written by setup

struct CableInfo {
    bool present = false;
    std::wstring feed_id, mic_id;      // playback side we write to, recording side people pick
    std::wstring feed_name, mic_name;
    std::wstring extra_id;             // the extra "CABLE In 16ch" playback side (if any)
};

CableInfo find_cable();
bool cable_restart_needed();  // setup installed it but Windows needs a restart first

// ---- Setup (needs administrator rights) ----

struct SetupOptions {
    bool silent = false;      // install without VB-Audio's window (CI, or once VB-Audio allows bundling)
    std::wstring pack_zip;    // use this VB-CABLE pack instead of downloading it
    std::wstring work_dir;    // where to download and unpack
};

// Installs VB-CABLE if needed, keeps the user's default devices, names the cable "Pitch Shift Mic".
// Returns 0 when ready, 3010 when a restart is needed, other numbers on failure. Writes progress to `log`.
int setup_mic(const SetupOptions& options, nlohmann::json& log);
// Gives the cable back its own names (when Pitch Shift is uninstalled but VB-CABLE stays).
int restore_cable_names(nlohmann::json& log);
// Removes VB-CABLE completely.
int remove_cable(nlohmann::json& log);

// Renames one sound device (its short name, as shown in Sound settings). Needs administrator rights.
HRESULT rename_endpoint(const std::wstring& id, const std::wstring& name);
// Shows or hides a sound device (like "Disable" in Sound settings).
HRESULT set_endpoint_visible(const std::wstring& id, bool visible);

std::string sha256_file(const std::wstring& path);

}  // namespace ps
