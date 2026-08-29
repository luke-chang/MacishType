#pragma once

#include <chrono>
#include <functional>
#include <memory>

namespace MacishType {

// Scheduling seam for the host's main loop. Injected per engine host at
// load() time — unlike the ambient HostServices — so tests can pair each
// host with its own fake loop.
//
// Threading contract: postDelayed/postDeferred are called on the loop
// thread and fire on the loop thread. post() is the only thread-safe
// entry — it marshals a callback onto the loop thread from any thread.
class HostEventLoop {
public:
    // Destroying the handle cancels the callback if it has not fired yet.
    class Cancelable {
    public:
        virtual ~Cancelable() = default;
    };
    using Handle = std::unique_ptr<Cancelable>;

    virtual ~HostEventLoop() = default;

    // One-shot timer against a monotonic clock.
    virtual Handle postDelayed(std::chrono::microseconds delay,
                               std::function<void()> callback) = 0;

    // Runs on the next loop iteration; must never run synchronously from
    // within the posting call (staged-fetch settlement relies on that).
    virtual Handle postDeferred(std::function<void()> callback) = 0;

    // Thread-safe fire-and-forget marshal onto the loop thread. Not
    // cancelable; callers guard liveness with their own tokens.
    virtual void post(std::function<void()> callback) = 0;
};

} // namespace MacishType
