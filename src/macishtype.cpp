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
    // Registered once; attached per input context only for engines that
    // declare the reverseLookup capability (see attachStatusActions).
    findInputCodeAction_.setShortText(translated("Find Input Code"));
    findInputCodeAction_.setIcon("edit-find");
    findInputCodeAction_.setHotkey(config_.findInputCodeKey.value());
    findInputCodeAction_.registerAction("macishtype-find-input-code",
                                        &instance_->userInterfaceManager());
    findInputCodeConn_ =
        findInputCodeAction_.connect<fcitx::SimpleAction::Activated>(
            [this](fcitx::InputContext *ic) { triggerFindInputCode(ic); });
    for (const auto &engine : engines_) {
        rebuildEngineSettings(engine);
    }
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
        MACISHTYPE_WARN() << "Cannot create user engines directory "
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

std::vector<fcitx::InputMethodEntry> MacishTypeEngine::listInputMethods() {
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
    // Refresh the action's displayed hotkey (matching is read live in
    // keyEvent, so functional matching already tracks the new value).
    findInputCodeAction_.setHotkey(config_.findInputCodeKey.value());
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

void MacishTypeEngine::keyEvent(const fcitx::InputMethodEntry &entry,
                                fcitx::KeyEvent &keyEvent) {
    // Find Input Code hotkey (before session dispatch): only for a capability
    // engine with a live session; consumes the key and shows the reverse
    // lookup. Without a session (load failed / not yet built) the key falls
    // through so a modifier combo still reaches the client, as before.
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

void MacishTypeEngine::handleSessionlessKey(const EngineInfo &engine,
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
        auto session = std::make_unique<EngineSession>(host, inputContext);
        if (session->valid()) {
            clearFailurePrompt(inputContext);
            session->invokeActivateHook();
            auto *live =
                (sessions_[inputContext] = std::move(session)).get();
            // fcitx cleared the InputMethod status group when the engine
            // last deactivated; a recovery outside activate must re-attach.
            attachStatusActions(engine, inputContext);
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

void MacishTypeEngine::showFailurePrompt(fcitx::InputContext *inputContext) {
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

void MacishTypeEngine::clearFailurePrompt(fcitx::InputContext *inputContext) {
    if (failurePromptShown_.erase(inputContext) == 0) {
        return;
    }
    applyPromptPreedit(inputContext, fcitx::Text());
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
    attachStatusActions(*engine, inputContext);
}

void MacishTypeEngine::attachStatusActions(const EngineInfo &engine,
                                           fcitx::InputContext *inputContext) {
    // The shared Traditional→Simplified conversion follows the resolved
    // outputToSimplified capability (chttrans is OnDemand and registers its
    // toggle action on load); the status-area action also arms its hotkey
    // and commit filter.
    if (outputToSimplifiedAvailable(engine)) {
        if (auto *action =
                instance_->userInterfaceManager().lookupAction("chttrans")) {
            inputContext->statusArea().addAction(
                fcitx::StatusGroup::InputMethod, action);
        }
        // Config edits that bypass the toggle action (e.g. fcitx5-configtool
        // writing chttrans's EnabledIM) raise no Action::Update; catch up at
        // the session boundary.
        reconcileChttransToggles();
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
            inputContext->statusArea().addAction(
                fcitx::StatusGroup::InputMethod, action);
        }
    }

    // Engines declaring reverseLookup get the Find Input Code action.
    if (engine.manifest.reverseLookup) {
        inputContext->statusArea().addAction(fcitx::StatusGroup::InputMethod,
                                             &findInputCodeAction_);
    }
}

void MacishTypeEngine::triggerFindInputCode(
    fcitx::InputContext *inputContext) {
    auto found = sessions_.find(inputContext);
    if (found == sessions_.end() || !found->second->valid()) {
        return;
    }
    found->second->showReverseLookup(resolveLookupQuery(inputContext));
}

std::string
MacishTypeEngine::resolveLookupQuery(fcitx::InputContext *inputContext) {
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
    // Keep only non-ASCII characters, bounded to 256 code points, before the
    // display iterates (it caps again at 200 unique characters). A single-byte
    // code point (U+0000–U+007F: letters, digits, punctuation, whitespace) is
    // ASCII — typed directly, with no input code to look up — so it is dropped;
    // an all-ASCII selection thus yields an empty query and the select-text
    // hint rather than a window full of dashes.
    std::string capped;
    size_t count = 0;
    auto range = fcitx::utf8::MakeUTF8CharRange(query);
    for (auto it = std::begin(range); it != std::end(range); ++it) {
        auto charRange = it.charRange();
        if (charRange.second - charRange.first == 1) {
            continue;
        }
        if (count++ >= 256) {
            break;
        }
        capped.append(charRange.first, charRange.second);
    }
    return capped;
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
    clearFailurePrompt(event.inputContext());
}

void MacishTypeEngine::reset(const fcitx::InputMethodEntry &entry,
                             fcitx::InputContextEvent &event) {
    FCITX_UNUSED(entry);
    auto found = sessions_.find(event.inputContext());
    if (found != sessions_.end()) {
        found->second->resetFromClient();
    }
    clearFailurePrompt(event.inputContext());
}

EngineInfo *MacishTypeEngine::engineById(const std::string &engineId) {
    for (auto &engine : engines_) {
        if (engine.id == engineId) {
            return &engine;
        }
    }
    return nullptr;
}

void MacishTypeEngine::rescanEngineFolders() {
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

void MacishTypeEngine::reconcileEngineFolder(const std::string &name) {
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
    engine->iconPath = resolved->iconPath;
    watcher_->watchEngine(engine->id, engine->root);
    reloadEngine(engine->id);
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
    auto host = JsEngineHost::load(
        engine.id, engine.root, engine.storageRoot,
        settings != engineSettings_.end() ? settings->second->valuesToJson()
                                          : std::string("{}"),
        engine.manifest, languages_, std::move(toggleDelegates),
        &instance_->eventLoop(), &instance_->eventDispatcher());
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

bool MacishTypeEngine::outputToSimplifiedAvailable(const EngineInfo &engine) {
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

void MacishTypeEngine::watchChttransToggle() {
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

void MacishTypeEngine::scheduleChttransReconcile() {
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

void MacishTypeEngine::reconcileChttransToggles() {
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

void MacishTypeEngine::notifyEngine(const std::string &engineId,
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

void MacishTypeEngine::notifyReload(const std::string &engineId,
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
MacishTypeAddonFactory::create(fcitx::AddonManager *manager) {
    // Before construction: option descriptions translate during member
    // initialization.
    registerTextDomain();
    return new MacishTypeEngine(manager->instance());
}

} // namespace macishtype

FCITX_ADDON_FACTORY_V2(macishtype, macishtype::MacishTypeAddonFactory)
