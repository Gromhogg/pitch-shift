#include "win/session_watch.h"

#include "win/devices.h"

#include <algorithm>

namespace ps {

namespace {
class Notifier final : public IAudioSessionNotification {
public:
    explicit Notifier(HANDLE wake) : wake_(wake) {}
    STDMETHODIMP QueryInterface(REFIID riid, void** out) override {
        if (!out) return E_POINTER;
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IAudioSessionNotification)) {
            *out = static_cast<IAudioSessionNotification*>(this);
            AddRef();
            return S_OK;
        }
        *out = nullptr;
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return ULONG(InterlockedIncrement(&refs_)); }
    STDMETHODIMP_(ULONG) Release() override {
        const LONG left = InterlockedDecrement(&refs_);
        if (left == 0) delete this;
        return ULONG(left);
    }
    STDMETHODIMP OnSessionCreated(IAudioSessionControl*) override {
        SetEvent(wake_);  // the manager thread does the work (no sound calls from in here)
        return S_OK;
    }

private:
    LONG refs_ = 1;
    HANDLE wake_;
};
}  // namespace

SessionWatcher::SessionWatcher(HANDLE wake) : wake_(wake), notifier_(new Notifier(wake)) {}

SessionWatcher::~SessionWatcher() {
    clear();
    notifier_->Release();
}

void SessionWatcher::clear() {
    for (auto& w : watched_) w.manager->UnregisterSessionNotification(notifier_);
    watched_.clear();
}

void SessionWatcher::refresh() {
    std::vector<std::wstring> ids;
    try {
        for (const auto& e : list_endpoints(eRender, DEVICE_STATE_ACTIVE)) ids.push_back(e.id);
    } catch (const std::exception&) {
        return;
    }
    // Stop watching devices that are gone.
    for (auto it = watched_.begin(); it != watched_.end();) {
        if (std::find(ids.begin(), ids.end(), it->id) == ids.end()) {
            it->manager->UnregisterSessionNotification(notifier_);
            it = watched_.erase(it);
        } else {
            ++it;
        }
    }
    // Start watching new ones.
    for (const auto& id : ids) {
        if (std::any_of(watched_.begin(), watched_.end(), [&](const Watched& w) { return w.id == id; })) continue;
        try {
            auto device = device_by_id(id);
            ComPtr<IAudioSessionManager2> manager;
            if (FAILED(device->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL, nullptr,
                                        reinterpret_cast<void**>(manager.GetAddressOf()))))
                continue;
            if (FAILED(manager->RegisterSessionNotification(notifier_))) continue;
            // Windows only starts sending news after the session list has been asked for once.
            ComPtr<IAudioSessionEnumerator> sessions;
            manager->GetSessionEnumerator(&sessions);
            watched_.push_back({id, manager});
        } catch (const std::exception&) {
        }
    }
}

}  // namespace ps
