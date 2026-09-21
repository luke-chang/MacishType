#include "MacishType.h"

#include <algorithm>
#include <string>
#include <string_view>

#include <cstdlib>
#include <dlfcn.h>
#include <filesystem>

#include <fcitx-config/iniparser.h>
#include <fcitx-config/rawconfig.h>
#include <notifications_public.h>
#include <fcitx-utils/i18n.h>
#include <fcitx-utils/key.h>
#include <fcitx-utils/standardpaths.h>
#include <fcitx-utils/utf8.h>
#include <fcitx/action.h>
#include <fcitx/addonmanager.h>
#include <fcitx/event.h>
#include <fcitx/inputpanel.h>
#include <fcitx/statusarea.h>
#include <fcitx/surroundingtext.h>
#include <fcitx/text.h>
#include <fcitx/userinterfacemanager.h>

#include "I18n.h"
#include "Log.h"
#include "VersionStamp.h"

namespace MacishType::Fcitx5 {

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

// Menu values get their own file: every config-dialog save rewrites the
// settings ini from the EngineSettings schema, dropping foreign keys. A
// subdirectory rather than "<id>-menu.conf", which an engine named
// "<id>-menu" would collide with (ids allow '-').
std::string menuConfigPath(const std::string &engineId) {
    return "macishtype/menu/" + engineId + ".conf";
}

// Menu keys are contract-free-form, but fcitx's ini writer escapes values
// only — a key holding '=', '#', '[', ']', '%', a control byte, or '/' (the
// RawConfig path separator) would corrupt the file or nest, and its reader
// trims each line, which would eat leading or trailing spaces. Percent-
// encode all of those into the option name.
std::string encodeMenuKey(const std::string &key) {
    static constexpr char hexDigits[] = "0123456789ABCDEF";
    std::string encoded;
    encoded.reserve(key.size());
    for (unsigned char byte : key) {
        if (byte <= 0x20 || byte == '%' || byte == '=' || byte == '#' ||
            byte == '[' || byte == ']' || byte == '/') {
            encoded += '%';
            encoded += hexDigits[byte >> 4];
            encoded += hexDigits[byte & 0xF];
        } else {
            encoded += static_cast<char>(byte);
        }
    }
    return encoded;
}

// Inverse of encodeMenuKey, so a stored entry can be matched against the
// declared keys. Needed to spot entries whose item is gone: handing those
// to the host (which drops unknown keys) is what makes its seeding notice
// the difference and rewrite the file without them.
std::string decodeMenuKey(const std::string &name) {
    auto hexDigit = [](char digit) -> int {
        if (digit >= '0' && digit <= '9') {
            return digit - '0';
        }
        if (digit >= 'A' && digit <= 'F') {
            return digit - 'A' + 10;
        }
        return -1;
    };
    std::string decoded;
    decoded.reserve(name.size());
    for (size_t i = 0; i < name.size(); i++) {
        if (name[i] == '%' && i + 2 < name.size()) {
            int high = hexDigit(name[i + 1]);
            int low = hexDigit(name[i + 2]);
            if (high >= 0 && low >= 0) {
                decoded += static_cast<char>((high << 4) | low);
                i += 2;
                continue;
            }
        }
        decoded += name[i];
    }
    return decoded;
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

AssociatedSelectionKeys
resolveAssociatedSelectionKeys(const std::string &token) {
    if (token == "numbers") {
        return AssociatedSelectionKeys::Numbers;
    }
    if (token == "shiftNumbers") {
        return AssociatedSelectionKeys::ShiftNumbers;
    }
    return AssociatedSelectionKeys::FollowEngine;
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

std::string MenuItemAction::icon(fcitx::InputContext *) const {
    // Both states carry an icon: kimpanel's rows are icon+label, so an
    // iconless one loses its label indent.
    return engine_->menuItemValue(engineId_, key_)
               ? "checkbox-checked-symbolic"
               : "checkbox-symbolic";
}

void MenuItemAction::activate(fcitx::InputContext *inputContext) {
    engine_->flipMenuItem(engineId_, key_);
    // A tray-menu click arrives after the text field lost focus, so there is
    // no session for the store observer to recompose — announce the flip on
    // this context ourselves.
    if (inputContext != nullptr) {
        update(inputContext);
    }
}

InputMethodEngine::InputMethodEngine(fcitx::Instance *instance)
    : instance_(instance),
      hostEventLoop_(&instance->eventLoop(), &instance->eventDispatcher()),
      alertSound_(&instance->eventDispatcher()),
      languages_(preferredLanguages()), engines_(discoverEngines(languages_)) {
    MACISHTYPE_INFO() << "MacishType " << versionStampFull() << " loaded";
    MACISHTYPE_INFO() << "Discovered " << engines_.size()
                      << " engine folder(s)";
    // The path this addon was loaded from; the destructor probes it to tell
    // an uninstall apart from a plain restart. The anchor has to be a
    // function this addon defines, not one it links in.
    Dl_info dlInfo;
    if (dladdr(reinterpret_cast<void *>(&discoverEngines), &dlInfo) != 0 &&
        dlInfo.dli_fname != nullptr) {
        libraryPath_ = dlInfo.dli_fname;
    }
    fcitx::readAsIni(config_, "conf/macishtype.conf");
    alertSound_.setEventId(config_.alertSound.value());
    // Registered once; attached per input context only for engines that
    // declare the reverseLookup capability (see composeStatusActions).
    findInputCodeAction_.setShortText(translated("Find Input Code"));
    findInputCodeAction_.setIcon("edit-find");
    findInputCodeAction_.setHotkey(config_.findInputCodeKey.value());
    findInputCodeAction_.registerAction("macishtype-find-input-code",
                                        &instance_->userInterfaceManager());
    findInputCodeConn_ =
        findInputCodeAction_.connect<fcitx::SimpleAction::Activated>(
            [this](fcitx::InputContext *ic) { triggerFindInputCode(ic); });
    // Before the watcher: its callbacks reach refreshEngineIcon, so IconLinks
    // has to exist for the whole lifetime in which any callback can run.
    iconLinks_ = std::make_unique<IconLinks>(&instance_->eventLoop());
    for (auto &engine : engines_) {
        rebuildEngineSettings(engine);
        rebuildEngineMenuActions(engine);
        refreshEngineIcon(engine);
    }
    // Only meaningful once every engine has claimed its entry, and only at
    // startup: engines that vanish later are parked with their entry intact
    // (see reconcileEngineFolder), so a runtime sweep would fight that.
    iconLinks_->sweepOrphans();
    watcher_ = std::make_unique<EngineWatcher>(
        &instance_->eventLoop(),
        [this](const std::string &engineId,
               const std::set<std::string> &changedPaths) {
            const auto *engine = engineById(engineId);
            if (engine == nullptr) {
                return;
            }
            // Folder-level transitions belong to the root reconcile:
            // rm -rf raises file deletions here first, and reloading a
            // vanished folder would emit an "Engine load failed" tip
            // that contradicts the removal tip that follows.
            std::error_code errorCode;
            if (!std::filesystem::is_directory(engine->root, errorCode)) {
                return;
            }
            // A parked engine (torn down when its folder vanished, or a
            // prior load failure) getting file changes is a recovery, not
            // an edit: reconcile re-resolves the winning layer (fixing a
            // stale storage root) and reloads unconditionally, never gated
            // on the edit option — the removal tip promised recovery.
            if (failedHosts_.count(engineId) != 0) {
                reconcileEngineFolder(engineId);
                return;
            }
            if (!shouldReload(engineId, changedPaths)) {
                return;
            }
            if (*config_.autoReloadEngines) {
                reloadEngine(engineId);
            } else {
                pendingReloads_.insert(engineId);
                MACISHTYPE_INFO() << "Engine changed on disk, reload "
                                     "deferred to the next update: "
                                  << engineId;
            }
        },
        [this](const std::string &engineId,
               const std::set<std::string> &changedPaths) {
            if (auto found = hosts_.find(engineId); found != hosts_.end()) {
                found->second->handleStorageChanges(changedPaths);
            }
        },
        [this](const std::string &name, const std::set<std::string> &) {
            reconcileEngineFolder(name);
        });
    // Watch every discovered engine from the start, so manifest edits apply
    // even for engines that have not been activated yet (and a failing one
    // retries as soon as it changes on disk).
    for (const auto &engine : engines_) {
        watcher_->watchEngine(engine.id, engine.root);
    }
    // Folder-level lifecycle: create the user layer so it is always
    // watchable, then watch every existing engines layer. This must
    // precede the CheckUpdate baseline below — a directory created after
    // the baseline would read as a permanent pending update.
    const auto &paths = fcitx::StandardPaths::global();
    auto userEngines =
        paths.userDirectory(fcitx::StandardPathsType::PkgData) /
        "macishtype/engines";
    std::error_code errorCode;
    std::filesystem::create_directories(userEngines, errorCode);
    if (errorCode) {
        MACISHTYPE_NOTICE() << "Cannot create user engines directory "
                            << userEngines << ": " << errorCode.message();
    }
    for (const auto &dataDir :
         paths.directories(fcitx::StandardPathsType::PkgData)) {
        auto enginesDir = dataDir / "macishtype/engines";
        if (std::filesystem::is_directory(enginesDir, errorCode)) {
            watcher_->watchEnginesRoot(enginesDir);
        }
    }
    enginesTimestamp_ = paths.timestamp(fcitx::StandardPathsType::PkgData,
                                        "macishtype/engines");
    // A panel handover changes what composeStatusActions attaches (only
    // kimpanel skips dividers), and the decision was made when the group
    // was last composed — so redo it for every live session.
    uiChangedWatcher_ = instance_->watchEvent(
        fcitx::EventType::UIChanged, fcitx::EventWatcherPhase::Default,
        [this](fcitx::Event &) {
            for (const auto &[inputContext, session] : sessions_) {
                if (const auto *engine = engineById(session->engineId())) {
                    composeStatusActions(*engine, inputContext);
                }
            }
        });
    // Runtime additions are pull-based, matching how any fcitx IM package
    // surfaces: this accept makes configtool show its native "Found
    // updates" banner, whose Update button refreshes the IM list and
    // re-enters listInputMethods.
    checkUpdateWatcher_ = instance_->watchEvent(
        fcitx::EventType::CheckUpdate, fcitx::EventWatcherPhase::Default,
        [this](fcitx::Event &event) {
            if (!pendingReloads_.empty() || enginesHaveUnparsableManifest_ ||
                fcitx::StandardPaths::global().timestamp(
                    fcitx::StandardPathsType::PkgData,
                    "macishtype/engines") > enginesTimestamp_) {
                event.accept();
            }
        });
}

InputMethodEngine::~InputMethodEngine() {
    // Package removal (apt, make uninstall) cannot reach per-user files, so
    // the icon links this addon made would outlive it. Detect removal here:
    // the library this process was loaded from is gone from disk. A normal
    // restart or logout keeps the file in place and the links stay.
    std::error_code errorCode;
    if (iconLinks_ && !libraryPath_.empty() &&
        !std::filesystem::exists(libraryPath_, errorCode)) {
        iconLinks_->removeAll();
    }
}

std::vector<fcitx::InputMethodEntry> InputMethodEngine::listInputMethods() {
    // fcitx re-invokes this on Instance::refresh (the configtool Update
    // button); rescanning here is what lets folders dropped in at runtime
    // join the list without a restart.
    rescanEngineFolders();
    std::vector<fcitx::InputMethodEntry> entries;
    for (const auto &engine : engines_) {
        fcitx::InputMethodEntry entry(uniqueNameForEngine(engine),
                                      safeDisplayName(engine),
                                      engine.manifest.languageCode,
                                      "macishtype");
        entry.setLabel(labelForEngine(engine));
        if (!engine.iconName.empty()) {
            entry.setIcon(engine.iconName);
        }
        auto settings = engineSettings_.find(engine.id);
        entry.setConfigurable(settings != engineSettings_.end() &&
                              settings->second->hasOptions());
        entries.push_back(std::move(entry));
    }
    return entries;
}

void InputMethodEngine::setConfig(const fcitx::RawConfig &raw) {
    config_.load(raw, true);
    fcitx::safeSaveAsIni(config_, "conf/macishtype.conf");
    // Refresh the action's displayed hotkey (matching is read live in
    // keyEvent, so functional matching already tracks the new value).
    findInputCodeAction_.setHotkey(config_.findInputCodeKey.value());
    alertSound_.setEventId(config_.alertSound.value());
}

void InputMethodEngine::refreshEngineIcon(EngineInfo &engine) {
    engine.icon = resolveIcon(engine.root, engine.manifest.icon);
    engine.iconName = iconLinks_->install(engine.id, engine.icon);
}

void InputMethodEngine::rebuildEngineSettings(const EngineInfo &engine) {
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

const fcitx::Configuration *InputMethodEngine::getConfigForInputMethod(
    const fcitx::InputMethodEntry &entry) const {
    auto found = engineSettings_.find(engineIdFromEntry(entry));
    return found != engineSettings_.end() ? found->second.get() : nullptr;
}

void InputMethodEngine::setConfigForInputMethod(
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
InputMethodEngine::subModeIconImpl(const fcitx::InputMethodEntry &entry,
                                   fcitx::InputContext &inputContext) {
    FCITX_UNUSED(inputContext);
    const auto *engine = engineForEntry(entry);
    return engine != nullptr ? engine->iconName : std::string();
}

std::string
InputMethodEngine::subModeLabelImpl(const fcitx::InputMethodEntry &entry,
                                    fcitx::InputContext &inputContext) {
    FCITX_UNUSED(inputContext);
    const auto *engine = engineForEntry(entry);
    return engine != nullptr ? labelForEngine(*engine) : std::string();
}

namespace {

// Sets (or clears, with an empty Text) the load-failure prompt, following
// the same capability dispatch the session uses for real preedit.
void applyPromptPreedit(fcitx::InputContext *inputContext,
                        fcitx::Text preedit) {
    auto &inputPanel = inputContext->inputPanel();
    if (inputContext->capabilityFlags().test(fcitx::CapabilityFlag::Preedit)) {
        inputPanel.setClientPreedit(preedit);
        inputContext->updatePreedit();
    } else {
        inputPanel.setPreedit(preedit);
        inputContext->updateUserInterface(
            fcitx::UserInterfaceComponent::InputPanel);
    }
}

} // namespace

void InputMethodEngine::keyEvent(const fcitx::InputMethodEntry &entry,
                                 fcitx::KeyEvent &keyEvent) {
    // Find Input Code hotkey (before session dispatch): only for a capability
    // engine with a live session; consumes the key and shows the reverse
    // lookup. Without a session (load failed / not yet built) the key falls
    // through so a modifier combo still reaches the client.
    if (!keyEvent.isRelease() &&
        !config_.findInputCodeKey.value().empty() &&
        keyEvent.key().checkKeyList(config_.findInputCodeKey.value())) {
        if (const auto *engine = engineForEntry(entry);
            engine != nullptr && engine->manifest.reverseLookup) {
            auto found = sessions_.find(keyEvent.inputContext());
            if (found != sessions_.end() && found->second->valid()) {
                triggerFindInputCode(keyEvent.inputContext());
                keyEvent.filterAndAccept();
                return;
            }
        }
    }
    auto found = sessions_.find(keyEvent.inputContext());
    if (found == sessions_.end()) {
        if (const auto *engine = engineForEntry(entry)) {
            handleSessionlessKey(*engine, keyEvent);
        }
        return;
    }
    found->second->handleKey(keyEvent);
}

void InputMethodEngine::handleSessionlessKey(const EngineInfo &engine,
                                             fcitx::KeyEvent &keyEvent) {
    auto *inputContext = keyEvent.inputContext();
    // Self-heal first: a restored folder reloads its host without any
    // re-activate on a context the user stayed on (fcitx only activates
    // on focus, IM-switch, and group changes), so the session is rebuilt
    // lazily here. failedHosts_ caches genuine failures, keeping this
    // check cheap on every key of a dead engine.
    if (auto *host = hostForEngine(engine)) {
        if (auto settings = engineSettings_.find(engine.id);
            settings != engineSettings_.end()) {
            host->updateSettings(settings->second->valuesToJson());
            host->setAssociatedModeEnabled(
                settings->second->associatedModeEnabled());
            host->setLayoutVertical(
                resolveLayoutVertical(settings->second->layoutDirection()));
        }
        reconcileChttransToggles();
        auto session = std::make_unique<EngineSession>(
            host, inputContext, intlCache_, alertSound_,
            associatedSelectionKeys());
        if (session->valid()) {
            clearFailurePrompt(inputContext);
            session->invokeActivateHook();
            auto *live =
                (sessions_[inputContext] = std::move(session)).get();
            // fcitx cleared the InputMethod status group when the engine
            // last deactivated; a recovery outside activate must re-attach.
            composeStatusActions(engine, inputContext);
            live->handleKey(keyEvent);
            return;
        }
    }

    // Genuinely dead engine: the macOS host's status-prompt semantics
    // (statusPromptResult) — printable keys are swallowed and show the
    // message in the composing area, Escape/Backspace clear it, modifier
    // combos and non-printing keys pass through while nothing is shown.
    const auto key = keyEvent.key();
    if (key.isModifier()) {
        return;
    }
    const bool shown = failurePromptShown_.count(inputContext) != 0;
    if (key.states() & fcitx::KeyStates{fcitx::KeyState::Ctrl,
                                        fcitx::KeyState::Alt,
                                        fcitx::KeyState::Super}) {
        if (shown) {
            keyEvent.filterAndAccept();
        }
        return;
    }
    if (key.sym() == FcitxKey_Escape || key.sym() == FcitxKey_BackSpace) {
        if (!shown) {
            return;
        }
        // Clear on the release so press and release are swallowed alike:
        // clearing on the press would drop `shown`, and the release would
        // then leak to the client as a key with no matching press.
        if (keyEvent.isRelease()) {
            clearFailurePrompt(inputContext);
        }
        keyEvent.filterAndAccept();
        return;
    }
    // Mirrors mac isPrintingCharacter: control range (< 0x21, so space
    // too) and DEL are non-printing; arrows/function keys map to zero.
    const uint32_t unicode = fcitx::Key::keySymToUnicode(key.sym());
    if (unicode >= 0x21 && unicode != 0x7F) {
        if (!keyEvent.isRelease()) {
            showFailurePrompt(inputContext);
        }
        keyEvent.filterAndAccept();
        return;
    }
    if (shown) {
        keyEvent.filterAndAccept();
    }
}

void InputMethodEngine::showFailurePrompt(fcitx::InputContext *inputContext) {
    failurePromptShown_.insert(inputContext);
    fcitx::Text preedit;
    // DontCommit is load-bearing: fcitx commits the client preedit on
    // focus-out before any engine cleanup runs, and the prompt must never
    // land in the user's document.
    preedit.append(translated("Engine load failed"),
                   fcitx::TextFormatFlags{fcitx::TextFormatFlag::Underline,
                                          fcitx::TextFormatFlag::DontCommit});
    applyPromptPreedit(inputContext, std::move(preedit));
}

void InputMethodEngine::clearFailurePrompt(fcitx::InputContext *inputContext) {
    if (failurePromptShown_.erase(inputContext) == 0) {
        return;
    }
    applyPromptPreedit(inputContext, fcitx::Text());
}

void InputMethodEngine::activate(const fcitx::InputMethodEntry &entry,
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
    // Config edits that bypass the toggle action (fcitx5-configtool writing
    // chttrans's EnabledIM) raise no Action::Update, so catch up here. Kept
    // out of composeStatusActions, which must never dispatch into JS.
    reconcileChttransToggles();
    auto session = std::make_unique<EngineSession>(
        host, inputContext, intlCache_, alertSound_,
        associatedSelectionKeys());
    if (!session->valid()) {
        return;
    }
    session->invokeActivateHook();
    sessions_[inputContext] = std::move(session);
    composeStatusActions(*engine, inputContext);
}

void InputMethodEngine::composeStatusActions(
    const EngineInfo &engine, fcitx::InputContext *inputContext) {
    // No JS re-entry allowed anywhere below: this runs inside the menu
    // store observer, which fires while engine JS is on the stack.
    auto &statusArea = inputContext->statusArea();
    // Redundant on the activate path (fcitx clears the group itself), but
    // it is what makes mid-session recomposition safe.
    statusArea.clearGroup(fcitx::StatusGroup::InputMethod);

    // The shared Traditional→Simplified conversion follows the resolved
    // outputToSimplified capability (chttrans is OnDemand and registers its
    // toggle action on load); the status-area action also arms its hotkey
    // and commit filter.
    if (outputToSimplifiedAvailable(engine)) {
        if (auto *action =
                instance_->userInterfaceManager().lookupAction("chttrans")) {
            statusArea.addAction(fcitx::StatusGroup::InputMethod, action);
        }
    }

    // Engines declaring the `fullwidthInput` capability get fcitx5's
    // full-width toggle in their status area — the portable stand-in for
    // macOS's Option+key full-width trigger. Linux/Windows leave that to a
    // mode toggle (Alt+key is a shortcut modifier there), so it is off by
    // default and the user flips it. No-op when the module is not installed.
    if (engine.manifest.fullwidthInput) {
        instance_->addonManager().addon("fullwidth", true);
        if (auto *action =
                instance_->userInterfaceManager().lookupAction("fullwidth")) {
            statusArea.addAction(fcitx::StatusGroup::InputMethod, action);
        }
    }

    if (engine.manifest.reverseLookup) {
        statusArea.addAction(fcitx::StatusGroup::InputMethod,
                             &findInputCodeAction_);
    }

    // Manifest menu items last. resolvedMenu() has dropped the hiddenWhen
    // ones; disabled joins them because fcitx has no enabled concept.
    // Dividers collapse (none leading, trailing, or doubled) and are
    // skipped under kimpanel, which would draw them as blank clickable
    // rows.
    auto host = hosts_.find(engine.id);
    auto menuActions = engineMenuActions_.find(engine.id);
    if (host == hosts_.end() || menuActions == engineMenuActions_.end()) {
        return;
    }
    const bool kimpanel = currentUIIsKimpanel();
    fcitx::Action *pendingDivider = nullptr;
    bool haveMenuItems = false;
    for (const auto &item : host->second->resolvedMenu()) {
        if (item.index >= menuActions->second.size()) {
            continue;
        }
        fcitx::Action *action = menuActions->second[item.index].get();
        if (item.divider) {
            if (!kimpanel && haveMenuItems) {
                pendingDivider = action;
            }
            continue;
        }
        if (item.disabled) {
            continue;
        }
        if (pendingDivider != nullptr) {
            statusArea.addAction(fcitx::StatusGroup::InputMethod,
                                 pendingDivider);
            pendingDivider = nullptr;
        }
        statusArea.addAction(fcitx::StatusGroup::InputMethod, action);
        haveMenuItems = true;
    }
}

void InputMethodEngine::rebuildEngineMenuActions(const EngineInfo &engine) {
    // Destroy first, never build the new set alongside the old one:
    // registerAction refuses a duplicate name, leaving that action
    // unaddressable from every panel. ~Action detaches itself from any
    // status area still showing it.
    engineMenuActions_.erase(engine.id);
    if (engine.manifest.menuItems.empty()) {
        return;
    }
    auto &actions = engineMenuActions_[engine.id];
    for (size_t index = 0; index < engine.manifest.menuItems.size(); index++) {
        const auto &item = engine.manifest.menuItems[index];
        std::unique_ptr<fcitx::Action> action;
        if (item.divider) {
            auto divider = std::make_unique<fcitx::SimpleAction>();
            divider->setSeparator(true);
            action = std::move(divider);
        } else {
            action = std::make_unique<MenuItemAction>(this, engine.id,
                                                      item.key, item.label);
        }
        // Indexed, not keyed: menu keys are free-form and kimpanel's
        // property format is colon-separated.
        std::string name =
            "macishtype-menu-" + engine.id + "-" + std::to_string(index);
        if (!action->registerAction(name,
                                    &instance_->userInterfaceManager())) {
            MACISHTYPE_NOTICE() << "Menu action registration failed: " << name;
        }
        actions.push_back(std::move(action));
    }
}

JsEngineHost::MenuStore
InputMethodEngine::menuStoreForEngine(const EngineInfo &engine) {
    JsEngineHost::MenuStore store;
    fcitx::RawConfig raw;
    fcitx::readAsIni(raw, fcitx::StandardPathsType::PkgConfig,
                     menuConfigPath(engine.id));
    // The whole file, not just the declared keys: the host drops what the
    // manifest no longer declares, and that difference is what makes its
    // seeding rewrite the file without the stale entries.
    for (const auto &name : raw.subItems()) {
        const auto *value = raw.valueByPath(name);
        if (value != nullptr && (*value == "True" || *value == "False")) {
            store.initial[decodeMenuKey(name)] = *value == "True";
        }
    }
    store.onChange = [this, engineId = engine.id](
                         const std::vector<std::pair<std::string, bool>>
                             &values) {
        handleMenuValuesChanged(engineId, values);
    };
    return store;
}

void InputMethodEngine::handleMenuValuesChanged(
    const std::string &engineId,
    const std::vector<std::pair<std::string, bool>> &values) {
    // Persist from the callback payload: the first notification fires inside
    // JsEngineHost::load(), before hosts_ holds the entry.
    fcitx::RawConfig raw;
    for (const auto &[key, value] : values) {
        raw.setValueByPath(encodeMenuKey(key), value ? "True" : "False");
    }
    fcitx::safeSaveAsIni(raw, fcitx::StandardPathsType::PkgConfig,
                         menuConfigPath(engineId));
    // A value change can alter the attach set through hiddenWhen, so
    // recompose. hosts_.find, never hostForEngine — its miss path loads,
    // and the first notification arrives from inside load() itself; that
    // window has no session for this engine either.
    if (hosts_.find(engineId) == hosts_.end()) {
        return;
    }
    const auto *engine = engineById(engineId);
    if (engine == nullptr) {
        return;
    }
    for (const auto &[inputContext, session] : sessions_) {
        if (session->engineId() == engineId) {
            composeStatusActions(*engine, inputContext);
        }
    }
}

bool InputMethodEngine::menuItemValue(const std::string &engineId,
                                      const std::string &key) {
    auto host = hosts_.find(engineId);
    if (host == hosts_.end()) {
        return false;
    }
    return host->second->menuValue(key).value_or(false);
}

void InputMethodEngine::flipMenuItem(const std::string &engineId,
                                     const std::string &key) {
    auto host = hosts_.find(engineId);
    if (host == hosts_.end()) {
        // A parked engine's actions can stay attached (and clickable) until
        // the next activate; the click degrades to a no-op.
        return;
    }
    host->second->flipMenuValue(key);
}

bool InputMethodEngine::currentUIIsKimpanel() const {
    return instance_->userInterfaceManager().currentUI() == "kimpanel";
}

void InputMethodEngine::triggerFindInputCode(
    fcitx::InputContext *inputContext) {
    auto found = sessions_.find(inputContext);
    if (found == sessions_.end() || !found->second->valid()) {
        return;
    }
    found->second->showReverseLookup(resolveLookupQuery(inputContext));
}

std::string
InputMethodEngine::resolveLookupQuery(fcitx::InputContext *inputContext) {
    std::string query;
    // The client's current selection, and only that: reading it does not steal
    // focus, so no pre-read dance is needed. Deliberately no PRIMARY-selection
    // fallback — PRIMARY holds whatever was last selected anywhere (which is
    // also whatever was last copied, since copying requires selecting), so it
    // would silently look up stale text when nothing is selected here.
    if (inputContext->capabilityFlags().test(
            fcitx::CapabilityFlag::SurroundingText)) {
        const auto &surrounding = inputContext->surroundingText();
        if (surrounding.isValid()) {
            query = surrounding.selectedText();
        }
    }
    // Bound the session's segmentation cost on a pathological selection (it
    // caps again at 200 unique characters). Trim back to a code point
    // boundary: a mid-sequence cut would turn a valid selection invalid,
    // which renders as the select-text hint instead of its rows.
    constexpr size_t kMaxQueryBytes = 16 * 1024;
    if (query.size() > kMaxQueryBytes) {
        size_t end = kMaxQueryBytes;
        while (end > 0 &&
               (static_cast<unsigned char>(query[end]) & 0xC0) == 0x80) {
            end--;
        }
        query.resize(end);
    }
    return query;
}

void InputMethodEngine::deactivate(const fcitx::InputMethodEntry &entry,
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
    clearFailurePrompt(event.inputContext());
}

void InputMethodEngine::reset(const fcitx::InputMethodEntry &entry,
                              fcitx::InputContextEvent &event) {
    FCITX_UNUSED(entry);
    auto found = sessions_.find(event.inputContext());
    if (found != sessions_.end()) {
        found->second->resetFromClient();
    }
    clearFailurePrompt(event.inputContext());
}

EngineInfo *InputMethodEngine::engineById(const std::string &engineId) {
    for (auto &engine : engines_) {
        if (engine.id == engineId) {
            return &engine;
        }
    }
    return nullptr;
}

void InputMethodEngine::rescanEngineFolders() {
    // Snapshot before scanning: mtimes have whole-second granularity, so
    // reading the timestamp afterwards could hide a folder that appeared
    // within the recording second forever; an occasional redundant
    // CheckUpdate accept is the cheaper failure.
    int64_t snapshot = fcitx::StandardPaths::global().timestamp(
        fcitx::StandardPathsType::PkgData, "macishtype/engines");
    auto discovered = discoverEngines(languages_,
                                      &enginesHaveUnparsableManifest_);
    for (auto &engine : discovered) {
        auto position = std::lower_bound(
            engines_.begin(), engines_.end(), engine,
            [](const EngineInfo &lhs, const EngineInfo &rhs) {
                return lhs.id < rhs.id;
            });
        if (position != engines_.end() && position->id == engine.id) {
            // Known engines are the per-engine watcher's concern; leaving
            // them untouched keeps live hosts undisturbed.
            continue;
        }
        MACISHTYPE_INFO() << "Engine discovered: " << engine.id;
        auto inserted = engines_.insert(position, std::move(engine));
        rebuildEngineSettings(*inserted);
        rebuildEngineMenuActions(*inserted);
        refreshEngineIcon(*inserted);
        watcher_->watchEngine(inserted->id, inserted->root);
    }
    // The Update button applies everything at once: deferred reloads too.
    // Vanished folders are skipped — their teardown belongs to the root
    // reconcile, which may still be inside its debounce window.
    auto pending = std::move(pendingReloads_);
    pendingReloads_.clear();
    for (const auto &engineId : pending) {
        const auto *engine = engineById(engineId);
        std::error_code errorCode;
        if (engine == nullptr ||
            !std::filesystem::is_directory(engine->root, errorCode)) {
            continue;
        }
        reloadEngine(engineId);
    }
    enginesTimestamp_ = snapshot;
}

void InputMethodEngine::reconcileEngineFolder(const std::string &name) {
    EngineInfo *engine = engineById(name);
    if (engine == nullptr) {
        // Not discovered yet: onboarding stays pull-based (the configtool
        // Update flow); the root watch only serves known engines.
        return;
    }
    auto resolved = discoverEngine(name, languages_);
    if (!resolved) {
        // No layer holds a parsable manifest, but a directory may still
        // exist (a restore-in-progress copy whose manifest.json lands after
        // the folder event, or a higher-layer shadow mid-creation).
        std::error_code errorCode;
        std::filesystem::path existingDir;
        for (const auto &candidate :
             fcitx::StandardPaths::global().locateAll(
                 fcitx::StandardPathsType::PkgData,
                 std::filesystem::path("macishtype/engines") / name)) {
            if (std::filesystem::is_directory(candidate, errorCode)) {
                existingDir = candidate;
                break;
            }
        }
        if (!existingDir.empty()) {
            // Only re-root a PARKED engine (torn down when its folder
            // vanished): re-arm its content watch on the directory so the
            // manifest landing drives recovery. A live or never-activated
            // engine is left untouched — the directory is an incomplete
            // shadow, and repointing root onto it would break a working
            // engine over an unrelated mkdir; its own layer still serves it.
            if (failedHosts_.count(name) != 0) {
                engine->root = existingDir;
                watcher_->watchEngine(engine->id, engine->root);
            }
            return;
        }
        // Folder gone from every layer: tear down like a reload would,
        // then park the engine until the folder returns or fcitx5
        // restarts — its entry cannot leave fcitx's list at runtime.
        std::vector<fcitx::InputContext *> affected;
        for (const auto &[inputContext, session] : sessions_) {
            if (session->engineId() == name) {
                affected.push_back(inputContext);
            }
        }
        for (auto *inputContext : affected) {
            // Not a focus-out, so the staged prefix is committed rather
            // than lost.
            sessions_[inputContext]->endFromDeactivate(false);
            endSession(inputContext);
        }
        hosts_.erase(name);
        // The engine's icon theme entry deliberately stays. The entry cannot
        // leave fcitx's list, so removing the icon would only turn a stale
        // icon into a missing one; and keeping the file name lets a restored
        // folder just re-point the link, which no panel has to rescan to
        // notice. A folder that never comes back is cleaned up by the sweep
        // on the next start.
        // Disarm the storage watch now: the folder (and its _storage) is
        // gone, and reloadEngine's re-resolve does not run on this path, so
        // nothing else clears the bookkeeping.
        watcher_->unwatchStorage(name);
        chttransToggleStates_.erase(name);
        failedHosts_[name] = true;
        pendingReloads_.erase(name);
        MACISHTYPE_INFO() << "Engine folder removed: " << name;
        notifyEngine(name, translated("Engine removed from disk"),
                     safeDisplayName(*engine) + " · " +
                         translated("Restore the folder to recover, or "
                                    "restart fcitx5"));
        return;
    }
    // Folder back (or the winning layer changed): refresh the cached
    // location before reloading — the old root may be a deleted user-layer
    // path shadowing a still-present system copy — and re-arm the content
    // watch, which died with the old directory. Recovery is deliberately
    // not gated on AutoReloadEngines: reviving a dead engine disturbs
    // nobody's typing, and the removal tip promises it.
    engine->root = resolved->root;
    engine->storageRoot = resolved->storageRoot;
    // The icon is deliberately not copied here: reloadEngine below re-resolves
    // it against the new root, which is also where the icon-theme entry is
    // refreshed.
    watcher_->watchEngine(engine->id, engine->root);
    reloadEngine(engine->id);
}

AssociatedSelectionKeys InputMethodEngine::associatedSelectionKeys() const {
    return resolveAssociatedSelectionKeys(
        config_.associatedSelectionKeys.value());
}

const EngineInfo *
InputMethodEngine::engineForEntry(const fcitx::InputMethodEntry &entry) {
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

JsEngineHost *InputMethodEngine::hostForEngine(const EngineInfo &engine) {
    if (auto found = hosts_.find(engine.id); found != hosts_.end()) {
        return found->second.get();
    }
    if (failedHosts_.count(engine.id) != 0) {
        return nullptr;
    }
    auto settings = engineSettings_.find(engine.id);
    // `manifest.toggle.outputToSimplified` proxies chttrans while the
    // capability resolves available, so the engine's writes and the
    // chttrans hotkey flip one switch. Installed before load because
    // engines may read the toggle while their entry module evaluates.
    // Manifest `menu` keys are a separate namespace and never alias it.
    std::map<std::string, JsEngineHost::ToggleDelegate> toggleDelegates;
    if (outputToSimplifiedAvailable(engine)) {
        std::string inputMethodName = uniqueNameForEngine(engine);
        chttransToggleStates_[engine.id] = ChttransToggleState{
            inputMethodName, chttransEnabled(inputMethodName)};
        toggleDelegates.emplace(
            "outputToSimplified",
            JsEngineHost::ToggleDelegate{
                [this, inputMethodName]() {
                    return chttransEnabled(inputMethodName);
                },
                [this, engineId = engine.id, inputMethodName](bool enabled) {
                    // Record before writing so the action-update echo is
                    // not re-dispatched as togglechange (no self-echo).
                    if (auto state = chttransToggleStates_.find(engineId);
                        state != chttransToggleStates_.end()) {
                        state->second.enabled = enabled;
                    }
                    setChttransEnabled(inputMethodName, enabled);
                },
            });
        watchChttransToggle();
    }
    auto host = JsEngineHost::load({
        .engineId = engine.id,
        .engineRoot = engine.root,
        .storageRoot = engine.storageRoot,
        .settingsValuesJson = settings != engineSettings_.end()
                                  ? settings->second->valuesToJson()
                                  : std::string("{}"),
        .manifest = engine.manifest,
        .languages = languages_,
        .toggleDelegates = std::move(toggleDelegates),
        .menuStore = menuStoreForEngine(engine),
        .eventLoop = &hostEventLoop_,
        .intl = intlCache_,
    });
    if (!host) {
        MACISHTYPE_ERROR() << "Engine failed to load, disabled until it "
                              "changes on disk: "
                           << engine.id;
        failedHosts_[engine.id] = true;
        chttransToggleStates_.erase(engine.id);
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

    return loadedHost;
}

bool InputMethodEngine::outputToSimplifiedAvailable(const EngineInfo &engine) {
    if (engine.manifest.outputToSimplified.has_value() &&
        !*engine.manifest.outputToSimplified) {
        return false;
    }
    // chttrans classifies IMs by fcitx language code; only the Traditional
    // Chinese codes get the Traditional→Simplified direction this toggle
    // promises, so the spec's "true lifts the language gate" arm cannot
    // widen availability on this host.
    const auto &language = engine.manifest.languageCode;
    if (language != "zh_TW" && language != "zh_HK") {
        return false;
    }
    return instance_->addonManager().addon("chttrans", true) != nullptr;
}

void InputMethodEngine::watchChttransToggle() {
    if (chttransUpdateConnection_.connected()) {
        return;
    }
    auto *action = instance_->userInterfaceManager().lookupAction("chttrans");
    if (action == nullptr) {
        return;
    }
    // Both user paths (hotkey and menu entry) funnel through chttrans's
    // toggle(), which always fires Action::Update on its action.
    chttransUpdateConnection_ = action->connect<fcitx::Action::Update>(
        [this](fcitx::InputContext *) { scheduleChttransReconcile(); });
}

void InputMethodEngine::scheduleChttransReconcile() {
    if (chttransReconcileDefer_) {
        return;
    }
    chttransReconcileDefer_ =
        instance_->eventLoop().addDeferEvent([this](fcitx::EventSource *) {
            auto *self = this;
            self->chttransReconcileDefer_.reset();
            self->reconcileChttransToggles();
            return true;
        });
}

void InputMethodEngine::reconcileChttransToggles() {
    for (auto &[engineId, state] : chttransToggleStates_) {
        bool enabled = chttransEnabled(state.inputMethodName);
        if (enabled == state.enabled) {
            continue;
        }
        state.enabled = enabled;
        if (auto host = hosts_.find(engineId); host != hosts_.end()) {
            host->second->dispatchToggleChange("outputToSimplified");
        }
    }
}

bool InputMethodEngine::chttransEnabled(const std::string &inputMethodName) {
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

void InputMethodEngine::setChttransEnabled(const std::string &inputMethodName,
                                           bool enabled) {
    auto *chttrans = instance_->addonManager().addon("chttrans", true);
    if (chttrans == nullptr) {
        MACISHTYPE_NOTICE() << "outputToSimplified: chttrans is unavailable";
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

void InputMethodEngine::endSession(fcitx::InputContext *inputContext) {
    sessions_.erase(inputContext);
}

bool InputMethodEngine::shouldReload(
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

void InputMethodEngine::reloadEngine(const std::string &engineId) {
    MACISHTYPE_INFO() << "Engine changed on disk, reloading: " << engineId;
    failedHosts_.erase(engineId);
    // A reload applies all on-disk state, so any deferred entry is served;
    // leaving it would pin CheckUpdate true and force a redundant reload.
    pendingReloads_.erase(engineId);

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
    // hostForEngine re-seeds this when the reloaded manifest still
    // resolves the toggle available.
    chttransToggleStates_.erase(engineId);

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
    refreshEngineIcon(*engine);
    // The settings schema may have changed shape; recompose it (persisted
    // values re-layer over the fresh defaults). The menu action set follows
    // the same lifecycle.
    rebuildEngineSettings(*engine);
    rebuildEngineMenuActions(*engine);

    auto *host = hostForEngine(*engine);
    notifyReload(engineId, safeDisplayName(*engine), host != nullptr);
    if (host == nullptr) {
        return;
    }
    for (auto *inputContext : affected) {
        auto session = std::make_unique<EngineSession>(
            host, inputContext, intlCache_, alertSound_,
            associatedSelectionKeys());
        if (!session->valid()) {
            continue;
        }
        session->invokeActivateHook();
        sessions_[inputContext] = std::move(session);
        // A reload rebuilds this session outside any activate, so nothing
        // else re-attaches the status actions (the old per-engine ones died
        // with rebuildEngineMenuActions above).
        composeStatusActions(*engine, inputContext);
    }
}

void InputMethodEngine::notifyEngine(const std::string &engineId,
                                     const std::string &summary,
                                     const std::string &body) {
    auto *notifications = instance_->addonManager().addon("notifications",
                                                          true);
    if (notifications == nullptr) {
        return;
    }
    if (!*config_.notifyOnReload) {
        return;
    }
    // Per-engine tip id: repeated tips for one engine replace in place, but
    // different engines each get their own notification so none is silently
    // overwritten (they queue in the notification center rather than merge).
    notifications->call<fcitx::INotifications::showTip>(
        "macishtype-reload-" + engineId, "MacishType", "input-keyboard",
        summary, body, 3000);
}

void InputMethodEngine::notifyReload(const std::string &engineId,
                                     const std::string &displayName,
                                     bool succeeded) {
    notifyEngine(engineId,
                 succeeded ? translated("Engine reloaded")
                           : translated("Engine load failed"),
                 succeeded ? displayName
                           : displayName + " · " +
                                 translated("See the fcitx5 log for details"));
}

fcitx::AddonInstance *
AddonFactory::create(fcitx::AddonManager *manager) {
    // Before construction: option descriptions translate during member
    // initialization.
    registerTextDomain();
    return new InputMethodEngine(manager->instance());
}

} // namespace MacishType::Fcitx5

FCITX_ADDON_FACTORY_V2(macishtype, MacishType::Fcitx5::AddonFactory)
