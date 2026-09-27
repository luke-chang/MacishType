#pragma once

#include <functional>
#include <memory>
#include <string>

#include <fcitx-utils/dbus/bus.h>
#include <fcitx-utils/dbus/servicewatcher.h>

namespace fcitx {
class Instance;
}

namespace MacishType::Fcitx5 {

// The desktop's XDG sound theme, read from xdg-desktop-portal and watched
// for changes. Everything happens on the event loop: the bus belongs to
// fcitx's dbus addon, which attaches it there. Desktops that do not answer
// for this namespace report an empty name.
class SoundTheme final {
public:
    using Callback = std::function<void(const std::string &)>;

    SoundTheme(fcitx::Instance *instance, Callback onChange);
    SoundTheme(const SoundTheme &) = delete;
    SoundTheme &operator=(const SoundTheme &) = delete;

private:
    void read(const char *method);
    void apply(const std::string &name);
    void useDefault(const char *reason);

    Callback onChange_;
    fcitx::dbus::Bus *bus_ = nullptr;
    // Each must outlive its call or subscription: destroying one cancels it,
    // which is also what keeps late replies from reaching a destroyed object.
    std::unique_ptr<fcitx::dbus::ServiceWatcher> watcher_;
    std::unique_ptr<fcitx::dbus::ServiceWatcherEntry> watchEntry_;
    std::unique_ptr<fcitx::dbus::Slot> readSlot_;
    std::unique_ptr<fcitx::dbus::Slot> changeSlot_;
};

} // namespace MacishType::Fcitx5
