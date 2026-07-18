#include "macishtype.h"

#include <algorithm>
#include <string>
#include <string_view>

#include <cstdlib>
#include <filesystem>

#include <fcitx-config/rawconfig.h>
#include <notifications_public.h>
#include <fcitx-utils/i18n.h>
#include <fcitx-utils/utf8.h>
#include <fcitx/action.h>
#include <fcitx/addonmanager.h>
#include <fcitx/statusarea.h>
#include <fcitx/userinterfacemanager.h>

#include "log.h"

namespace macishtype {

FCITX_DEFINE_LOG_CATEGORY(macishtype_logcategory, "macishtype");

namespace {

constexpr std::string_view kUniqueNamePrefix = "macishtype-";
constexpr char kTextDomain[] = "fcitx5-macishtype";

// Translations follow the install flavor: the dev install puts .mo files
// under ~/.local/share/locale, the production install under the system
// locale dir. gettext binds one directory per domain, so pick whichever
// actually carries the domain.
void registerTextDomain() {
    const char *home = std::getenv("HOME");
    if (home != nullptr) {
        std::filesystem::path userLocale =
            std::filesystem::path(home) / ".local/share/locale";
        std::error_code errorCode;
        std::filesystem::directory_iterator languages(userLocale, errorCode);
        if (!errorCode) {
            for (const auto &language : languages) {
                if (std::filesystem::is_regular_file(
                        language.path() / "LC_MESSAGES" /
                            "fcitx5-macishtype.mo",
                        errorCode)) {
                    fcitx::registerDomain(kTextDomain,
                                          userLocale.c_str());
                    return;
                }
            }
        }
    }
    fcitx::registerDomain(kTextDomain, FCITX_INSTALL_LOCALEDIR);
}

std::string translated(const char *text) {
    return fcitx::translateDomain(kTextDomain, text);
}

std::string uniqueNameForEngine(const EngineInfo &engine) {
    return std::string(kUniqueNamePrefix) + engine.id;
}

// Compact label shown in panels: the manifest label when declared, else
// the first character of the display name.
std::string labelForEngine(const EngineInfo &engine) {
    if (!engine.manifest.label.empty() &&
        fcitx::utf8::validate(engine.manifest.label)) {
        return engine.manifest.label;
    }
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
    registerTextDomain();
    MACISHTYPE_INFO() << "Discovered " << engines_.size()
                      << " engine folder(s)";
    watcher_ = std::make_unique<EngineWatcher>(
        &instance_->eventLoop(),
        [this](const std::string &engineId,
               const std::set<std::string> &changedPaths) {
            if (shouldReload(engineId, changedPaths)) {
                reloadEngine(engineId);
            }
        });
    // Watch every discovered engine from the start, so manifest edits apply
    // even for engines that have not been activated yet (and a failing one
    // retries as soon as it changes on disk).
    for (const auto &engine : engines_) {
        watcher_->watchEngine(engine.id, engine.root);
    }
}

std::vector<fcitx::InputMethodEntry> MacishTypeEngine::listInputMethods() {
    std::vector<fcitx::InputMethodEntry> entries;
    for (const auto &engine : engines_) {
        fcitx::InputMethodEntry entry(uniqueNameForEngine(engine),
                                      engine.displayName(),
                                      engine.manifest.languageCode,
                                      "macishtype");
        entry.setLabel(labelForEngine(engine));
        if (!engine.iconPath.empty()) {
            entry.setIcon(engine.iconPath);
        }
        entry.setConfigurable(false);
        entries.push_back(std::move(entry));
    }
    return entries;
}

std::string
MacishTypeEngine::subModeIconImpl(const fcitx::InputMethodEntry &entry,
                                  fcitx::InputContext &inputContext) {
    FCITX_UNUSED(inputContext);
    const auto *engine = engineForEntry(entry);
    return engine != nullptr ? engine->iconPath : std::string();
}

std::string
MacishTypeEngine::subModeLabelImpl(const fcitx::InputMethodEntry &entry,
                                   fcitx::InputContext &inputContext) {
    FCITX_UNUSED(inputContext);
    const auto *engine = engineForEntry(entry);
    return engine != nullptr ? labelForEngine(*engine) : std::string();
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

    // Chinese engines opt into the shared Simplified/Traditional conversion
    // (chttrans is OnDemand and registers its toggle action on load); the
    // status-area action also arms its hotkey and commit filter.
    if (entry.languageCode().compare(0, 3, "zh_") == 0) {
        instance_->addonManager().addon("chttrans", true);
        if (auto *action =
                instance_->userInterfaceManager().lookupAction("chttrans")) {
            inputContext->statusArea().addAction(
                fcitx::StatusGroup::InputMethod, action);
        }
    }
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
        MACISHTYPE_ERROR() << "Engine failed to load, disabled until it "
                              "changes on disk: "
                           << engine.id;
        failedHosts_[engine.id] = true;
        return nullptr;
    }
    auto [inserted, unused] = hosts_.emplace(engine.id, std::move(host));
    FCITX_UNUSED(unused);
    auto *loadedHost = inserted->second.get();

    // The outputToSimplified system menu key proxies chttrans, so the
    // engine's own toggle command and the chttrans hotkey flip one switch.
    const auto &menuKeys = engine.manifest.menuKeys;
    if (std::find(menuKeys.begin(), menuKeys.end(), "outputToSimplified") !=
        menuKeys.end()) {
        std::string inputMethodName = uniqueNameForEngine(engine);
        loadedHost->setMenuDelegate(
            "outputToSimplified",
            JsEngineHost::MenuDelegate{
                [this, inputMethodName]() {
                    return chttransEnabled(inputMethodName);
                },
                [this, inputMethodName](bool enabled) {
                    setChttransEnabled(inputMethodName, enabled);
                },
            });
    }
    return loadedHost;
}

bool MacishTypeEngine::chttransEnabled(const std::string &inputMethodName) {
    auto *chttrans = instance_->addonManager().addon("chttrans", true);
    if (chttrans == nullptr) {
        return false;
    }
    const auto *config = chttrans->getConfig();
    if (config == nullptr) {
        return false;
    }
    fcitx::RawConfig raw;
    config->save(raw);
    auto enabledList = raw.get("EnabledIM");
    if (!enabledList) {
        return false;
    }
    for (const auto &index : enabledList->subItems()) {
        auto item = enabledList->get(index);
        if (item && item->value() == inputMethodName) {
            return true;
        }
    }
    return false;
}

void MacishTypeEngine::setChttransEnabled(const std::string &inputMethodName,
                                          bool enabled) {
    auto *chttrans = instance_->addonManager().addon("chttrans", true);
    if (chttrans == nullptr) {
        MACISHTYPE_WARN() << "outputToSimplified: chttrans is unavailable";
        return;
    }
    const auto *config = chttrans->getConfig();
    if (config == nullptr) {
        return;
    }
    fcitx::RawConfig raw;
    config->save(raw);
    std::vector<std::string> names;
    if (auto enabledList = raw.get("EnabledIM")) {
        for (const auto &index : enabledList->subItems()) {
            auto item = enabledList->get(index);
            if (item && !item->value().empty() &&
                item->value() != inputMethodName) {
                names.push_back(item->value());
            }
        }
    }
    if (enabled) {
        names.push_back(inputMethodName);
    }
    raw.remove("EnabledIM");
    // chttrans loads the config partially: an absent EnabledIM node means
    // "keep the old list", so the node must exist even when empty.
    raw.get("EnabledIM", true);
    for (size_t i = 0; i < names.size(); i++) {
        raw.setValueByPath("EnabledIM/" + std::to_string(i), names[i]);
    }
    chttrans->setConfig(raw);
    // chttrans's own hotkey path refreshes its status action after a
    // toggle; mirror that so menus show the new state on first open.
    if (auto *action =
            instance_->userInterfaceManager().lookupAction("chttrans")) {
        for (const auto &[inputContext, session] : sessions_) {
            FCITX_UNUSED(session);
            action->update(inputContext);
        }
    }
}

void MacishTypeEngine::endSession(fcitx::InputContext *inputContext) {
    sessions_.erase(inputContext);
}

bool MacishTypeEngine::shouldReload(
    const std::string &engineId, const std::set<std::string> &changedPaths) {
    auto found = hosts_.find(engineId);
    if (found == hosts_.end()) {
        return true;
    }
    const auto &tracked = found->second->loadedFilePaths();
    for (const auto &path : changedPaths) {
        if (tracked.count(path) != 0) {
            return true;
        }
    }
    for (const auto &engine : engines_) {
        if (engine.id != engineId) {
            continue;
        }
        for (const auto &candidate :
             iconCandidatePaths(engine.root, engine.manifest.icon)) {
            if (changedPaths.count(candidate) != 0) {
                return true;
            }
        }
        break;
    }
    MACISHTYPE_DEBUG() << "Ignoring untracked file change(s) in "
                       << engineId;
    return false;
}

void MacishTypeEngine::reloadEngine(const std::string &engineId) {
    MACISHTYPE_INFO() << "Engine changed on disk, reloading: " << engineId;
    failedHosts_.erase(engineId);

    std::vector<fcitx::InputContext *> affected;
    for (const auto &[inputContext, session] : sessions_) {
        if (session->engineId() == engineId) {
            affected.push_back(inputContext);
        }
    }
    for (auto *inputContext : affected) {
        sessions_[inputContext]->endFromDeactivate();
        endSession(inputContext);
    }
    hosts_.erase(engineId);

    EngineInfo *engine = nullptr;
    for (auto &candidate : engines_) {
        if (candidate.id == engineId) {
            engine = &candidate;
            break;
        }
    }
    if (engine == nullptr) {
        return;
    }
    // Manifest edits apply too (settings defaults, modules, candidate
    // window). Display names are the exception: fcitx5's input method list
    // only grows at runtime (loadDynamicEntries skips existing entries and
    // nothing can update or remove one), so a rename shows after the next
    // fcitx5 restart.
    if (auto manifest =
            parseManifest(engine->root / "manifest.json", languages_)) {
        engine->manifest = std::move(*manifest);
    }
    // Icon file changes count too, even when the manifest kept its old
    // parse result; the subMode overrides serve the new value live.
    engine->iconPath = resolveIconPath(engine->root, engine->manifest.icon);

    auto *host = hostForEngine(*engine);
    notifyReload(engine->displayName(), host != nullptr);
    if (host == nullptr) {
        return;
    }
    for (auto *inputContext : affected) {
        auto session = std::make_unique<EngineSession>(host, inputContext);
        if (!session->valid()) {
            continue;
        }
        session->invokeActivateHook();
        sessions_[inputContext] = std::move(session);
    }
}

void MacishTypeEngine::notifyReload(const std::string &displayName,
                                    bool succeeded) {
    auto *notifications = instance_->addonManager().addon("notifications",
                                                          true);
    if (notifications == nullptr) {
        return;
    }
    notifications->call<fcitx::INotifications::showTip>(
        "macishtype-reload", "MacishType", "input-keyboard",
        succeeded ? translated("Engine reloaded")
                  : translated("Engine failed to load"),
        succeeded ? displayName
                  : displayName + " · " +
                        translated("See the fcitx5 log for details"),
        3000);
}

fcitx::AddonInstance *
MacishTypeAddonFactory::create(fcitx::AddonManager *manager) {
    return new MacishTypeEngine(manager->instance());
}

} // namespace macishtype

FCITX_ADDON_FACTORY_V2(macishtype, macishtype::MacishTypeAddonFactory)
