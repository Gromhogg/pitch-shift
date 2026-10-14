// Tells us right away when an app starts a new sound session on any speaker device, so it can be
// quieted before much of its sound gets through.
#pragma once
#include "win/com.h"

#include <audiopolicy.h>

#include <string>
#include <vector>

namespace ps {

class SessionWatcher {
public:
    explicit SessionWatcher(HANDLE wake);  // `wake` is signaled for every new session
    ~SessionWatcher();
    SessionWatcher(const SessionWatcher&) = delete;
    SessionWatcher& operator=(const SessionWatcher&) = delete;

    // Starts watching any speaker devices that appeared (and stops watching gone ones).
    // Call from a COM multithreaded thread, not from inside a sound callback.
    void refresh();

private:
    void clear();

    HANDLE wake_;
    IAudioSessionNotification* notifier_;
    struct Watched {
        std::wstring id;
        ComPtr<IAudioSessionManager2> manager;
    };
    std::vector<Watched> watched_;
};

}  // namespace ps
