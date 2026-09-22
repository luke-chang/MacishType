#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <utility>

#include <fcitx-utils/event.h>

namespace MacishType::Fcitx5 {

// Runs `callback` once, `delayMicroseconds` from now. The callback may reset
// the returned source — its own owner — while running: it executes from a
// stack copy, so the closure it came from can die underneath it.
inline std::unique_ptr<fcitx::EventSourceTime>
scheduleOneShot(fcitx::EventLoop &eventLoop, uint64_t delayMicroseconds,
                std::function<void()> callback) {
    return eventLoop.addTimeEvent(
        CLOCK_MONOTONIC, fcitx::now(CLOCK_MONOTONIC) + delayMicroseconds, 0,
        [callback = std::move(callback)](fcitx::EventSourceTime *,
                                         uint64_t) mutable {
            auto localCallback = std::move(callback);
            localCallback();
            return true;
        });
}

} // namespace MacishType::Fcitx5
