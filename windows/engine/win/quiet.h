// Makes an app's own sound very quiet (so only the shifted copy is heard) and, above all,
// always puts it back. Before any change, the original volumes are written to a restore list
// (%LOCALAPPDATA%\Pitch Shift\restore.json), so even after a crash the next start can fix them.
#pragma once
#include "win/sessions.h"

#include <nlohmann/json.hpp>
#include <string>
#include <vector>

namespace ps {

struct QuietEntry {
    std::wstring exe;              // program path; new sessions of the same program are fixed too
    DWORD pid = 0;
    std::wstring instance_id;
    std::vector<float> original;   // channel volumes before we changed them
    float quiet_level = 0.001f;
};

std::wstring restore_file_path();  // %LOCALAPPDATA%\Pitch Shift\restore.json

bool save_restore_list(const std::wstring& path, const std::vector<QuietEntry>& entries);
std::vector<QuietEntry> load_restore_list(const std::wstring& path);

// Writes the session's current volumes to the restore list, then lowers every channel to `level`.
HRESULT quiet_session(const Session& session, float level, const std::wstring& path);

struct RestoreResult {
    int restored = 0;
    int failed = 0;
    int pending = 0;  // listed apps that aren't playing right now (kept on the list)
    nlohmann::json log = nlohmann::json::array();
};

// Puts back every listed app that is still quiet, then deletes the list (if everything worked).
RestoreResult restore_all(const std::wstring& path);

}  // namespace ps
