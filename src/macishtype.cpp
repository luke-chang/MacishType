#include "macishtype.h"

#include <algorithm>
#include <string>
#include <string_view>

#include <cstdlib>
#include <filesystem>

#include <fcitx-config/iniparser.h>
#include <fcitx-config/rawconfig.h>
#include <notifications_public.h>
#include <fcitx-utils/i18n.h>
#include <fcitx-utils/utf8.h>
#include <fcitx/action.h>
#include <fcitx/addonmanager.h>
#include <fcitx/statusarea.h>
#include <fcitx/userinterfacemanager.h>

#include "i18n.h"
#include "log.h"

namespace macishtype {

FCITX_DEFINE_LOG_CATEGORY(macishtype_logcategory, "macishtype");

namespace {

constexpr std::string_view kUniqueNamePrefix = "macishtype-";

std::string uniqueNameForEngine(const EngineInfo &engine) {
    return std::string(kUniqueNamePrefix) + engine.id;
}

std::string engineIdFromEntry(const fcitx::InputMethodEntry &entry) {
    return entry.uniqueName().substr(kUniqueNamePrefix.size());
}

std::string settingsConfigPath(const std::string &engineId) {
    return "macishtype/" + engineId + ".conf";
}

// Resolves the per-input-method orientation token to a concrete direction.
// "system" (and any absent/unknown token) follows the sole fcitx global that
// carries a candidate direction — classicui's "Vertical Candidate List" —
// falling back to horizontal when it is unreadable. Read fresh each activate
// so a changed global is picked up on the next session.
bool resolveLayoutVertical(const std::string &token) {
    if (token == "vertical") {
        return true;
    }
    if (token == "horizontal") {
        return false;
    }
    fcitx::RawConfig classicui;
    fcitx::readAsIni(classicui, fcitx::StandardPathsType::PkgConfig,
                     "conf/classicui.conf");
    const auto *value = classicui.valueByPath("Vertical Candidate List");
    return value != nullptr && *value == "True";
}

// Compact label shown in panels: the manifest label when declared, else
// the first character of the display name.
std::string labelForEngine(const EngineInfo &engine) {
    if (!engine.manifest.label.empty() &&
        fcitx::utf8::validate(engine.manifest.label)) {
        return engine.manifest.label;
    }
    // No explicit label: hand the full display name to the host UI and let it
    // shorten as it sees fit — fcitx5's status area shows one CJK glyph or two
    // Latin letters, while the input-method switch popup shows it in full.
    std::string displayName = engine.displayName();
    return fcitx::utf8::validate(displayName) ? displayName : engine.id;
}

// The display name reaches fcitx's D-Bus surface (the input-method entry and
// the reload notification), which requires valid UTF-8; a manifest may carry a
// lone surrogate, so fall back to the id when it is not valid UTF-8 (matching
// labelForEngine).
std::string safeDisplayName(const EngineInfo &engine) {
    std::string name = engine.displayName();
    return fcitx::utf8::validate(name) ? name : engine.id;
}

} // namespace

MacishTypeEngine::MacishTypeEngine(fcitx::Instance *instance)
    : instance_(instance), languages_(preferredLanguages()),
      engines_(discoverEngines(languages_)) {
    MACISHTYPE_INFO() << "Discovered " << engines_.size()
                      << " engine folder(s)";
    fcitx::readAsIni(config_, "conf/macishtype.conf");
    for (const auto &engine : engines_) {
        rebuildEngineSettings(engine);
    }
    watcher_ = std::make_unique<EngineWatcher>(
        &instance_->eventLoop(),
        [this](const std::string &engineId,
               const std::set<std::string> &changedPaths) {
            if (shouldReload(engineId, changedPaths)) {
                reloadEngine(engineId);
            }
        },
        [this](const std::string &engineId,
               const std::set<std::string> &changedPaths) {
            if (auto found = hosts_.find(engineId); found != hosts_.end()) {
                found->second->handleStorageChanges(changedPaths);
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
                                      safeDisplayName(engine),
                                      engine.manifest.languageCode,
                                      "macishtype");
        entry.setLabel(labelForEngine(engine));
        if (!engine.iconPath.empty()) {
            entry.setIcon(engine.iconPath);
        }
        auto settings = engineSettings_.find(engine.id);
        entry.setConfigurable(settings != engineSettings_.end() &&
                              settings->second->hasOptions());
        entries.push_back(std::move(entry));
    }
    return entries;
}

void MacishTypeEngine::setConfig(const fcitx::RawConfig &raw) {
    config_.load(raw, true);
    fcitx::safeSaveAsIni(config_, "conf/macishtype.conf");
}

void MacishTypeEngine::rebuildEngineSettings(const EngineInfo &engine) {
    auto settings = std::make_unique<EngineSettings>(
        engine.manifest.settingsSections,
        associatedDictionaryAvailable(engine.manifest.intendedLanguage),
        engine.manifest.candidateWindowHasLayoutDirection);
    if (!settings->hasOptions()) {
        // Nothing configurable: no supported manifest settings, and the
        // manifest fixes the candidate orientation.
        engineSettings_.erase(engine.id);
        return;
    }
    // Manifest defaults live in the options themselves (the constructor
    // defaults, which is also what "reset to default" restores); the
    // persisted user values layer over them.
    fcitx::RawConfig raw;
    fcitx::readAsIni(raw, fcitx::StandardPathsType::PkgConfig,
                     settingsConfigPath(engine.id));
    settings->load(raw, true);
    engineSettings_[engine.id] = std::move(settings);
}

const fcitx::Configuration *MacishTypeEngine::getConfigForInputMethod(
    const fcitx::InputMethodEntry &entry) const {
    auto found = engineSettings_.find(engineIdFromEntry(entry));
    return found != engineSettings_.end() ? found->second.get() : nullptr;
}

void MacishTypeEngine::setConfigForInputMethod(
    const fcitx::InputMethodEntry &entry, const fcitx::RawConfig &raw) {
    std::string engineId = engineIdFromEntry(entry);
    auto found = engineSettings_.find(engineId);
    if (found == engineSettings_.end()) {
        return;
    }
    found->second->load(raw, true);
    fcitx::safeSaveAsIni(*found->second, fcitx::StandardPathsType::PkgConfig,
                         settingsConfigPath(engineId));
    // The new values are not pushed to a live engine here: the contract
    // refreshes manifest.settings only at session boundaries, never
    // mid-composition. They apply the next time the engine activates
    // (changing settings means focusing configtool, so returning to a
    // text field is itself an activate).
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
    // Settings apply at this session boundary (mirrors macOS re-reading on
    // activate): push the persisted values before the new instance is
    // constructed so it observes them, deduplicated so an unchanged
    // config is a no-op.
    if (auto settings = engineSettings_.find(engine->id);
        settings != engineSettings_.end()) {
        host->updateSettings(settings->second->valuesToJson());
        host->setAssociatedModeEnabled(
            settings->second->associatedModeEnabled());
        host->setLayoutVertical(
            resolveLayoutVertical(settings->second->layoutDirection()));
    }
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

    // Engines declaring the `fullwidthInput` capability get fcitx5's
    // full-width toggle in their status area — the portable stand-in for
    // macOS's Option+key full-width trigger. Linux/Windows leave that to a
    // mode toggle (Alt+key is a shortcut modifier there), so it is off by
    // default and the user flips it. No-op when the module is not installed.
    if (engine->manifest.fullwidthInput) {
        instance_->addonManager().addon("fullwidth", true);
        if (auto *action =
                instance_->userInterfaceManager().lookupAction("fullwidth")) {
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
        // Focus-out is the one deactivation where fcitx5 auto-commits the
        // committable client preedit before we run; every other (a by-hand
        // input-method switch) leaves the staged prefix for us to commit.
        bool preeditAlreadyCommitted =
            event.type() == fcitx::EventType::InputContextFocusOut;
        found->second->endFromDeactivate(preeditAlreadyCommitted);
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
    auto settings = engineSettings_.find(engine.id);
    auto host = JsEngineHost::load(
        engine.id, engine.root, engine.storageRoot,
        settings != engineSettings_.end() ? settings->second->valuesToJson()
                                          : std::string("{}"),
        engine.manifest, languages_, &instance_->eventLoop(),
        &instance_->eventDispatcher());
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

    // The host gates its associated-mode dictionary fallback on this, and
    // holds the resolved base orientation for manifests that leave it open.
    if (settings != engineSettings_.end()) {
        loadedHost->setAssociatedModeEnabled(
            settings->second->associatedModeEnabled());
        loadedHost->setLayoutVertical(
            resolveLayoutVertical(settings->second->layoutDirection()));
    }

    // Storage watches follow the engine's `storage` listener count; the
    // observer replays the state accumulated while the entry module
    // evaluated.
    loadedHost->setStorageListeningObserver(
        [this, engineId = engine.id,
         storageRoot = loadedHost->storageRoot()](bool active) {
            if (active) {
                watcher_->watchStorage(engineId, storageRoot);
            } else {
                watcher_->unwatchStorage(engineId);
            }
        });

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
        // No fcitx auto-commit here (not a focus-out), so the staged prefix
        // is committed rather than lost across the reload.
        sessions_[inputContext]->endFromDeactivate(false);
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
    // The settings schema may have changed shape; recompose it (persisted
    // values re-layer over the fresh defaults).
    rebuildEngineSettings(*engine);

    auto *host = hostForEngine(*engine);
    notifyReload(engineId, safeDisplayName(*engine), host != nullptr);
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

void MacishTypeEngine::notifyReload(const std::string &engineId,
                                    const std::string &displayName,
                                    bool succeeded) {
    auto *notifications = instance_->addonManager().addon("notifications",
                                                          true);
    if (notifications == nullptr) {
        return;
    }
    if (!*config_.notifyOnReload) {
        return;
    }
    // Per-engine tip id: repeated reloads of one engine replace in place, but
    // different engines each get their own notification so none is silently
    // overwritten (they queue in the notification center rather than merge).
    notifications->call<fcitx::INotifications::showTip>(
        "macishtype-reload-" + engineId, "MacishType", "input-keyboard",
        succeeded ? translated("Engine reloaded")
                  : translated("Engine failed to load"),
        succeeded ? displayName
                  : displayName + " · " +
                        translated("See the fcitx5 log for details"),
        3000);
}

fcitx::AddonInstance *
MacishTypeAddonFactory::create(fcitx::AddonManager *manager) {
    // Before construction: option descriptions translate during member
    // initialization.
    registerTextDomain();
    return new MacishTypeEngine(manager->instance());
}

} // namespace macishtype

FCITX_ADDON_FACTORY_V2(macishtype, macishtype::MacishTypeAddonFactory)
