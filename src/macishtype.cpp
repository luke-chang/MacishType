#include "macishtype.h"

#include <string>
#include <string_view>

#include <fcitx-utils/utf8.h>
#include <fcitx/addonmanager.h>

#include "log.h"

namespace macishtype {

FCITX_DEFINE_LOG_CATEGORY(macishtype_logcategory, "macishtype");

namespace {

constexpr std::string_view kUniqueNamePrefix = "macishtype-";

std::string uniqueNameForEngine(const EngineInfo &engine) {
    return std::string(kUniqueNamePrefix) + engine.id;
}

// Compact label shown in panels: the first character of the display name.
std::string labelForEngine(const EngineInfo &engine) {
    std::string displayName = engine.displayName();
    if (!fcitx::utf8::validate(displayName)) {
        return engine.id.substr(0, 1);
    }
    auto firstCharBytes = fcitx::utf8::ncharByteLength(displayName.begin(), 1);
    return displayName.substr(0, firstCharBytes);
}

} // namespace

MacishTypeEngine::MacishTypeEngine(fcitx::Instance *instance)
    : instance_(instance), languages_(preferredLanguages()),
      engines_(discoverEngines(languages_)) {
    MACISHTYPE_INFO() << "Discovered " << engines_.size()
                      << " engine folder(s)";
}

std::vector<fcitx::InputMethodEntry> MacishTypeEngine::listInputMethods() {
    std::vector<fcitx::InputMethodEntry> entries;
    for (const auto &engine : engines_) {
        fcitx::InputMethodEntry entry(uniqueNameForEngine(engine),
                                      engine.displayName(),
                                      engine.manifest.languageCode,
                                      "macishtype");
        entry.setLabel(labelForEngine(engine));
        entry.setConfigurable(false);
        entries.push_back(std::move(entry));
    }
    return entries;
}

void MacishTypeEngine::keyEvent(const fcitx::InputMethodEntry &entry,
                                fcitx::KeyEvent &keyEvent) {
    FCITX_UNUSED(entry);
    auto found = sessions_.find(keyEvent.inputContext());
    if (found == sessions_.end()) {
        return;
    }
    found->second->handleKey(keyEvent);
}

void MacishTypeEngine::activate(const fcitx::InputMethodEntry &entry,
                                fcitx::InputContextEvent &event) {
    const auto *engine = engineForEntry(entry);
    if (engine == nullptr) {
        return;
    }
    auto *host = hostForEngine(*engine);
    if (host == nullptr) {
        return;
    }
    auto *inputContext = event.inputContext();
    endSession(inputContext);
    auto session = std::make_unique<EngineSession>(host, inputContext);
    if (!session->valid()) {
        return;
    }
    session->invokeActivateHook();
    sessions_[inputContext] = std::move(session);
}

void MacishTypeEngine::deactivate(const fcitx::InputMethodEntry &entry,
                                  fcitx::InputContextEvent &event) {
    FCITX_UNUSED(entry);
    auto found = sessions_.find(event.inputContext());
    if (found != sessions_.end()) {
        found->second->endFromDeactivate();
    }
    endSession(event.inputContext());
}

void MacishTypeEngine::reset(const fcitx::InputMethodEntry &entry,
                             fcitx::InputContextEvent &event) {
    FCITX_UNUSED(entry);
    auto found = sessions_.find(event.inputContext());
    if (found != sessions_.end()) {
        found->second->resetFromClient();
    }
}

const EngineInfo *
MacishTypeEngine::engineForEntry(const fcitx::InputMethodEntry &entry) {
    std::string_view uniqueName = entry.uniqueName();
    if (uniqueName.size() <= kUniqueNamePrefix.size() ||
        uniqueName.substr(0, kUniqueNamePrefix.size()) != kUniqueNamePrefix) {
        return nullptr;
    }
    std::string_view engineId = uniqueName.substr(kUniqueNamePrefix.size());
    for (const auto &engine : engines_) {
        if (engine.id == engineId) {
            return &engine;
        }
    }
    return nullptr;
}

JsEngineHost *MacishTypeEngine::hostForEngine(const EngineInfo &engine) {
    if (auto found = hosts_.find(engine.id); found != hosts_.end()) {
        return found->second.get();
    }
    if (failedHosts_.count(engine.id) != 0) {
        return nullptr;
    }
    auto host = JsEngineHost::load(engine.id, engine.root, engine.manifest,
                                   languages_);
    if (!host) {
        MACISHTYPE_ERROR() << "Engine failed to load, disabling until "
                              "restart: "
                           << engine.id;
        failedHosts_[engine.id] = true;
        return nullptr;
    }
    auto [inserted, unused] = hosts_.emplace(engine.id, std::move(host));
    FCITX_UNUSED(unused);
    return inserted->second.get();
}

void MacishTypeEngine::endSession(fcitx::InputContext *inputContext) {
    sessions_.erase(inputContext);
}

fcitx::AddonInstance *
MacishTypeAddonFactory::create(fcitx::AddonManager *manager) {
    return new MacishTypeEngine(manager->instance());
}

} // namespace macishtype

FCITX_ADDON_FACTORY_V2(macishtype, macishtype::MacishTypeAddonFactory)
