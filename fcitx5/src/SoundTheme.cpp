#include "SoundTheme.h"

#include <utility>

#include <dbus_public.h>
#include <fcitx-utils/dbus/matchrule.h>
#include <fcitx-utils/dbus/message.h>
#include <fcitx-utils/dbus/servicewatcher.h>
#include <fcitx-utils/dbus/variant.h>
#include <fcitx/addonmanager.h>
#include <fcitx/instance.h>

#include "Log.h"

namespace MacishType::Fcitx5 {

namespace {

constexpr const char *kPortalService = "org.freedesktop.portal.Desktop";
constexpr const char *kPortalPath = "/org/freedesktop/portal/desktop";
constexpr const char *kSettingsInterface = "org.freedesktop.portal.Settings";
// The key is GNOME's, but the portal is the cross-desktop way to reach it.
constexpr const char *kNamespace = "org.gnome.desktop.sound";
constexpr const char *kKey = "theme-name";
// ReadOne arrived with Settings version 2; Read is deprecated but is all an
// older portal offers, and it wraps the value one level deeper.
constexpr const char *kReadOne = "ReadOne";
constexpr const char *kRead = "Read";
constexpr uint64_t kTimeoutMicroseconds = 5 * 1000 * 1000;

// Read wraps the value one level deeper than ReadOne. Checking the signature
// first matters: dataAs asserts when it disagrees.
std::string themeFromVariant(const fcitx::dbus::Variant &value) {
    if (value.signature() == "v") {
        return themeFromVariant(value.dataAs<fcitx::dbus::Variant>());
    }
    return value.signature() == "s" ? value.dataAs<std::string>()
                                    : std::string();
}

} // namespace

SoundTheme::SoundTheme(fcitx::Instance *instance, Callback onChange)
    : onChange_(std::move(onChange)) {
    auto *dbusAddon = instance->addonManager().addon("dbus", true);
    if (dbusAddon == nullptr) {
        useDefault("no dbus addon");
        return;
    }
    bus_ = dbusAddon->call<fcitx::IDBusModule::bus>();
    if (bus_ == nullptr || !bus_->isOpen()) {
        useDefault("no session bus");
        return;
    }

    // The bus daemon filters on the two leading string arguments, so only
    // our own key wakes the process up.
    fcitx::dbus::MatchRule rule(kPortalService, kPortalPath,
                                kSettingsInterface, "SettingChanged",
                                {kNamespace, kKey});
    changeSlot_ = bus_->addMatch(rule, [this](fcitx::dbus::Message &message) {
        std::string changedNamespace;
        std::string changedKey;
        message >> changedNamespace >> changedKey;
        if (changedNamespace != kNamespace || changedKey != kKey) {
            return true;
        }
        fcitx::dbus::Variant value;
        message >> value;
        apply(themeFromVariant(value));
        return true;
    });

    // Watching rather than calling outright: a method call would auto-start
    // the portal, and this also covers the portal arriving after us or being
    // restarted, either of which a one-shot query would miss.
    watcher_ = std::make_unique<fcitx::dbus::ServiceWatcher>(*bus_);
    watchEntry_ = watcher_->watchService(
        kPortalService, [this](const std::string &, const std::string &,
                               const std::string &newOwner) {
            if (newOwner.empty()) {
                useDefault("no desktop portal");
                return;
            }
            read(kReadOne);
        });
}

void SoundTheme::read(const char *method) {
    auto call = bus_->createMethodCall(kPortalService, kPortalPath,
                                       kSettingsInterface, method);
    call << std::string(kNamespace) << std::string(kKey);
    readSlot_ = call.callAsync(
        kTimeoutMicroseconds, [this, method](fcitx::dbus::Message &reply) {
            if (!reply.isError()) {
                fcitx::dbus::Variant value;
                reply >> value;
                apply(themeFromVariant(value));
            } else if (method == kReadOne) {
                // Replacing readSlot_ from inside its own callback is safe:
                // this call is already finished.
                read(kRead);
            } else {
                useDefault("the desktop portal did not answer");
            }
            return true;
        });
}

void SoundTheme::apply(const std::string &name) {
    if (name.empty()) {
        useDefault("the desktop reported no theme");
        return;
    }
    MACISHTYPE_INFO() << "alert sound theme: " << name;
    onChange_(name);
}

void SoundTheme::useDefault(const char *reason) {
    MACISHTYPE_INFO() << "alert sound theme: " << reason
                      << ", using the sound library's default";
    onChange_(std::string());
}

} // namespace MacishType::Fcitx5
