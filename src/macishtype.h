#pragma once

#include <cstdint>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include <fcitx/addonfactory.h>
#include <fcitx/addoninstance.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputmethodengine.h>
#include <fcitx/inputmethodentry.h>
#include <fcitx/instance.h>

#include "enginediscovery.h"
#include "enginewatcher.h"
#include "jshost/enginehost.h"
#include "session.h"

namespace macishtype {

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
    // Lazily loads the JS host for an engine; a load failure is remembered
    // so a broken engine does not re-load on every focus change.
    JsEngineHost *hostForEngine(const EngineInfo &engine);
    void endSession(fcitx::InputContext *inputContext);

    // chttrans enablement for one input method, via its addon config (the
    // same state its hotkey toggles and persists).
    bool chttransEnabled(const std::string &inputMethodName);
    void setChttransEnabled(const std::string &inputMethodName, bool enabled);

    // Scopes hot reloads to relevant changes, mirroring the macOS host's
    // tracked-file set: while an engine is live, only files it expressed
    // interest in (plus the icon candidates) count. Engines without a live
    // host accept any change, so a broken or not-yet-activated engine
    // still retries on a fix.
    bool shouldReload(const std::string &engineId,
                      const std::set<std::string> &changedPaths);
    // Hot reload: tears down the engine's JS host and rebuilds the active
    // sessions so on-disk edits apply immediately.
    void reloadEngine(const std::string &engineId);
    void notifyReload(const std::string &displayName, bool succeeded);

    fcitx::Instance *instance_;
    std::vector<std::string> languages_;
    std::vector<EngineInfo> engines_;
    std::map<std::string, std::unique_ptr<JsEngineHost>> hosts_;
    std::map<std::string, bool> failedHosts_;
    std::map<fcitx::InputContext *, std::unique_ptr<EngineSession>> sessions_;
    std::unique_ptr<EngineWatcher> watcher_;
};

class MacishTypeAddonFactory : public fcitx::AddonFactory {
public:
    fcitx::AddonInstance *create(fcitx::AddonManager *manager) override;
};

} // namespace macishtype
