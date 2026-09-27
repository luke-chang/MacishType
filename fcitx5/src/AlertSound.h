#pragma once

#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>

namespace fcitx {
class EventDispatcher;
}

namespace MacishType::Fcitx5 {

// The desktop alert sound, over libcanberra, which is loaded at runtime
// rather than linked so the addon runs without it installed.
//
// Everything libcanberra touches runs on a private thread:
// ca_context_play_full is synchronous and the first call also connects to
// the sound server, so on the event loop it would stall the keystroke that
// triggered it for as long as the user's audio stack takes.
class AlertSound final {
public:
    // The dispatcher carries worker diagnostics back to the event loop.
    explicit AlertSound(fcitx::EventDispatcher *dispatcher)
        : dispatcher_(dispatcher) {}
    ~AlertSound();
    AlertSound(const AlertSound &) = delete;
    AlertSound &operator=(const AlertSound &) = delete;

    void setEnabled(bool enabled);
    // The desktop's XDG sound theme; empty leaves libcanberra on its own
    // default.
    void setThemeName(std::string name);

    // Returns immediately. Requests arriving while one is playing collapse
    // into a single follow-up.
    void play();

private:
    void workerMain();

    fcitx::EventDispatcher *dispatcher_;
    std::thread worker_;
    std::mutex mutex_;
    std::condition_variable wake_;
    // Guarded by mutex_.
    bool pending_ = false;
    bool stopping_ = false;
    bool enabled_ = false;
    std::string themeName_;
};

} // namespace MacishType::Fcitx5
