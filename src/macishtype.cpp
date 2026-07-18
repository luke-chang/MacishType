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
    if (engine.displayName.empty()) {
        return engine.id.substr(0, 1);
    }
    auto range = fcitx::utf8::MakeUTF8CharRange(engine.displayName);
    auto first = std::begin(range);
    if (first == std::end(range)) {
        return engine.id.substr(0, 1);
    }
    return std::string(engine.displayName.begin(), first.charRange().second);
}

} // namespace

MacishTypeEngine::MacishTypeEngine(fcitx::Instance *instance)
    : instance_(instance), engines_(discoverEngines()) {
    MACISHTYPE_INFO() << "Discovered " << engines_.size()
                      << " engine folder(s)";
}

std::vector<fcitx::InputMethodEntry> MacishTypeEngine::listInputMethods() {
    std::vector<fcitx::InputMethodEntry> entries;
    for (const auto &engine : engines_) {
        // TODO: language code and display name from manifest.json once the
        // JS host lands; empty language groups the entry under "Unknown".
        fcitx::InputMethodEntry entry(uniqueNameForEngine(engine),
                                      engine.displayName, "", "macishtype");
        entry.setLabel(labelForEngine(engine));
        entry.setConfigurable(false);
        entries.push_back(std::move(entry));
    }
    return entries;
}

void MacishTypeEngine::keyEvent(const fcitx::InputMethodEntry &entry,
                                fcitx::KeyEvent &keyEvent) {
    FCITX_UNUSED(entry);
    // Skeleton: let every key through until the JS host handles them.
    FCITX_UNUSED(keyEvent);
}

void MacishTypeEngine::activate(const fcitx::InputMethodEntry &entry,
                                fcitx::InputContextEvent &event) {
    FCITX_UNUSED(entry);
    FCITX_UNUSED(event);
}

void MacishTypeEngine::deactivate(const fcitx::InputMethodEntry &entry,
                                  fcitx::InputContextEvent &event) {
    reset(entry, event);
}

void MacishTypeEngine::reset(const fcitx::InputMethodEntry &entry,
                             fcitx::InputContextEvent &event) {
    FCITX_UNUSED(entry);
    FCITX_UNUSED(event);
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

fcitx::AddonInstance *
MacishTypeAddonFactory::create(fcitx::AddonManager *manager) {
    return new MacishTypeEngine(manager->instance());
}

} // namespace macishtype

FCITX_ADDON_FACTORY_V2(macishtype, macishtype::MacishTypeAddonFactory)
