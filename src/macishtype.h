#pragma once

#include <cstdint>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include <fcitx-config/configuration.h>
#include <fcitx-config/option.h>
#include <fcitx-utils/event.h>
#include <fcitx-utils/key.h>
#include <fcitx-utils/signals.h>
#include <fcitx/action.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addoninstance.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputmethodengine.h>
#include <fcitx/inputmethodentry.h>
#include <fcitx/instance.h>

#include "enginediscovery.h"
#include "enginesettings.h"
#include "enginewatcher.h"
#include "i18n.h"
#include "jshost/enginehost.h"
#include "session.h"

namespace macishtype {

FCITX_CONFIGURATION(
    MacishTypeConfig,
    // Declared first: configtool renders options in declaration order and
    // this one belongs above the notification toggle.
    fcitx::Option<bool> autoReloadEngines{
        this, "AutoReloadEngines",
        translated("Auto-reload an engine when its files change"), true};
    fcitx::Option<bool> notifyOnReload{
        this, "NotifyOnReload",
        translated("Notify on engine folder changes"), true};
    // Hotkey that opens Find Input Code (reverse lookup) for the selected
    // text. Empty clears it (status-area action still triggers). Default
    // Ctrl+Alt+L (GNOME's screen lock is Super+L, so no conflict there);
    // the modifier spells out as "Control" — fcitx drops the "Ctrl" alias.
    fcitx::KeyListOption findInputCodeKey{
        this, "FindInputCodeKey", translated("Find Input Code"),
        {fcitx::Key("Control+Alt+L")}, fcitx::KeyListConstrain()};);

class MacishTypeEngine final : public fcitx::InputMethodEngineV2 {
public:
    explicit MacishTypeEngine(fcitx::Instance *instance);

    std::vector<fcitx::InputMethodEntry> listInputMethods() override;
    // Panels consult these live, unlike the registration-time entry
    // fields, so manifest label and icon edits apply on hot reload.
    std::string subModeIconImpl(const fcitx::InputMethodEntry &entry,
                                fcitx::InputContext &inputContext) override;
    std::string subModeLabelImpl(const fcitx::InputMethodEntry &entry,
                                 fcitx::InputContext &inputContext) override;

    // Addon-wide options (the "Add-ons" page in configtool).
    const fcitx::Configuration *getConfig() const override {
        return &config_;
    }
    void setConfig(const fcitx::RawConfig &raw) override;

    // Per input method settings composed from the engine's manifest
    // schema (the gear next to a selected input method).
    const fcitx::Configuration *
    getConfigForInputMethod(const fcitx::InputMethodEntry &entry) const
        override;
    void setConfigForInputMethod(const fcitx::InputMethodEntry &entry,
                                 const fcitx::RawConfig &raw) override;
    void keyEvent(const fcitx::InputMethodEntry &entry,
                  fcitx::KeyEvent &keyEvent) override;
    void activate(const fcitx::InputMethodEntry &entry,
                  fcitx::InputContextEvent &event) override;
    void deactivate(const fcitx::InputMethodEntry &entry,
                    fcitx::InputContextEvent &event) override;
    void reset(const fcitx::InputMethodEntry &entry,
               fcitx::InputContextEvent &event) override;

private:
    const EngineInfo *engineForEntry(const fcitx::InputMethodEntry &entry);
    EngineInfo *engineById(const std::string &engineId);
    // Lazily loads the JS host for an engine; a load failure is remembered
    // so a broken engine does not re-load on every focus change.
    JsEngineHost *hostForEngine(const EngineInfo &engine);
    void endSession(fcitx::InputContext *inputContext);
    // Merges engine folders that appeared since the last scan into
    // engines_ and applies deferred reloads; runs at the head of
    // listInputMethods so fcitx's refresh (the configtool Update button)
    // picks up runtime additions — the pull-based onboarding path.
    void rescanEngineFolders();
    // Root-watch receiver: reconciles one engines/<name> folder against
    // disk state — vanished => defunct with feedback, present-and-known =>
    // re-resolve the winning layer and reload, present-and-unknown =>
    // left to the pull-based path.
    void reconcileEngineFolder(const std::string &name);
    // keyEvent path for a context without a session: rebuilds one lazily
    // when the host is healthy (the only recovery path for a context that
    // stayed on a restored engine), otherwise renders the load-failure
    // prompt, mirroring the macOS host's status prompt semantics.
    void handleSessionlessKey(const EngineInfo &engine,
                              fcitx::KeyEvent &keyEvent);
    void showFailurePrompt(fcitx::InputContext *inputContext);
    void clearFailurePrompt(fcitx::InputContext *inputContext);
    // Adds the engine's capability-driven status-area actions (the
    // Traditional→Simplified toggle, the full-width toggle) to a context.
    // fcitx clears the InputMethod status group before each activate, so
    // both activate and the lazy session rebuild must (re)attach them.
    void attachStatusActions(const EngineInfo &engine,
                             fcitx::InputContext *inputContext);
    // Find Input Code (reverse lookup): trigger reads the client's selection
    // and hands it to the focused session's read-only display.
    void triggerFindInputCode(fcitx::InputContext *inputContext);
    std::string resolveLookupQuery(fcitx::InputContext *inputContext);

    // chttrans enablement for one input method, via its addon config (the
    // same state its hotkey toggles and persists).
    bool chttransEnabled(const std::string &inputMethodName);
    void setChttransEnabled(const std::string &inputMethodName, bool enabled);
    // Whether the host can deliver `outputToSimplified` for this engine.
    // chttrans only converts Traditional→Simplified on IMs it classifies
    // as Traditional Chinese (zh_TW / zh_HK); on Simplified-Chinese IMs it
    // converts the other way and elsewhere it is inert, so both count as
    // unsupported regardless of the declared capability.
    bool outputToSimplifiedAvailable(const EngineInfo &engine);
    // Observes chttrans's toggle action so user flips (hotkey or menu
    // entry, which both end in Action::update) reach engines as
    // `togglechange`.
    void watchChttransToggle();
    // Defers the reconcile to the next loop iteration: the Update signal
    // can fire while another engine's JS is on the stack (a manifest.toggle
    // write ends in action->update), and a nested togglechange handler
    // would run inside that host's armed watchdog window.
    void scheduleChttransReconcile();
    // Compares every tracked engine's chttrans state against the last
    // known value and dispatches `togglechange` on real deltas. JS
    // self-writes record the new value first, so their action-update echo
    // produces none.
    void reconcileChttransToggles();

    // Scopes hot reloads to relevant changes, mirroring the macOS host's
    // tracked-file set: while an engine is live, only files it expressed
    // interest in (plus the icon candidates) count. Engines without a live
    // host accept any change, so a broken or not-yet-activated engine
    // still retries on a fix.
    bool shouldReload(const std::string &engineId,
                      const std::set<std::string> &changedPaths);
    // (Re)composes the engine's fcitx configuration from its manifest
    // settings schema and layers the persisted user values over the
    // manifest defaults.
    void rebuildEngineSettings(const EngineInfo &engine);
    // Hot reload: tears down the engine's JS host and rebuilds the active
    // sessions so on-disk edits apply immediately.
    void reloadEngine(const std::string &engineId);
    void notifyEngine(const std::string &engineId, const std::string &summary,
                      const std::string &body);
    void notifyReload(const std::string &engineId,
                      const std::string &displayName, bool succeeded);

    fcitx::Instance *instance_;
    MacishTypeConfig config_;
    std::vector<std::string> languages_;
    std::vector<EngineInfo> engines_;
    // Present for every engine that declares settings sections (it also
    // produces the values pushed to the JS side); hasOptions() decides
    // whether the entry is configurable.
    std::map<std::string, std::unique_ptr<EngineSettings>> engineSettings_;
    std::map<std::string, std::unique_ptr<JsEngineHost>> hosts_;
    std::map<std::string, bool> failedHosts_;
    std::map<fcitx::InputContext *, std::unique_ptr<EngineSession>> sessions_;
    std::unique_ptr<EngineWatcher> watcher_;
    // Last chttrans enablement pushed to / observed for each engine with an
    // available outputToSimplified toggle, keyed by engine id; the delta
    // detector behind reconcileChttransToggles().
    struct ChttransToggleState {
        std::string inputMethodName;
        bool enabled = false;
    };
    std::map<std::string, ChttransToggleState> chttransToggleStates_;
    std::unique_ptr<fcitx::EventSource> chttransReconcileDefer_;
    fcitx::ScopedConnection chttransUpdateConnection_;
    // Find Input Code status-area action (present only on capability engines)
    // and its Activated connection.
    fcitx::SimpleAction findInputCodeAction_;
    fcitx::ScopedConnection findInputCodeConn_;
    // Engines whose on-disk edits await the user's pull (AutoReloadEngines
    // off); applied and cleared by rescanEngineFolders.
    std::set<std::string> pendingReloads_;
    // CheckUpdate baseline: max mtime across the engines layers at the
    // last scan. Recorded only after the user layer is created and the
    // root watches are armed (a directory created afterwards would read
    // as a permanent pending update).
    int64_t enginesTimestamp_ = 0;
    // Whether the last scan skipped a validly-named folder whose manifest
    // did not parse (a new engine mid-authoring). Keeps CheckUpdate live —
    // engines/ mtime does not change when the manifest is fixed in place,
    // so without this the update affordance would vanish after the first
    // scan and the fixed engine would never surface until a restart.
    bool enginesHaveUnparsableManifest_ = false;
    std::unique_ptr<fcitx::HandlerTableEntry<fcitx::EventHandler>>
        checkUpdateWatcher_;
    // Contexts currently showing the load-failure prompt, so Escape/
    // Backspace know whether there is anything to clear.
    std::set<fcitx::InputContext *> failurePromptShown_;
};

class MacishTypeAddonFactory : public fcitx::AddonFactory {
public:
    fcitx::AddonInstance *create(fcitx::AddonManager *manager) override;
};

} // namespace macishtype
