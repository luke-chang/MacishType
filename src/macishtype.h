#pragma once

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include <fcitx/addonfactory.h>
#include <fcitx/addoninstance.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputmethodengine.h>
#include <fcitx/inputmethodentry.h>
#include <fcitx/instance.h>

#include "enginediscovery.h"
#include "jshost/enginehost.h"

namespace macishtype {

class MacishTypeEngine final : public fcitx::InputMethodEngineV2 {
public:
    explicit MacishTypeEngine(fcitx::Instance *instance);

    std::vector<fcitx::InputMethodEntry> listInputMethods() override;
    void keyEvent(const fcitx::InputMethodEntry &entry,
                  fcitx::KeyEvent &keyEvent) override;
    void activate(const fcitx::InputMethodEntry &entry,
                  fcitx::InputContextEvent &event) override;
    void deactivate(const fcitx::InputMethodEntry &entry,
                    fcitx::InputContextEvent &event) override;
    void reset(const fcitx::InputMethodEntry &entry,
               fcitx::InputContextEvent &event) override;

private:
    struct Session {
        JsEngineHost *host = nullptr;
        uint64_t instanceId = 0;
    };

    const EngineInfo *engineForEntry(const fcitx::InputMethodEntry &entry);
    // Lazily loads the JS host for an engine; a load failure is remembered
    // so a broken engine does not re-load on every focus change.
    JsEngineHost *hostForEngine(const EngineInfo &engine);
    void endSession(fcitx::InputContext *inputContext);

    fcitx::Instance *instance_;
    std::vector<std::string> languages_;
    std::vector<EngineInfo> engines_;
    std::map<std::string, std::unique_ptr<JsEngineHost>> hosts_;
    std::map<std::string, bool> failedHosts_;
    std::map<fcitx::InputContext *, Session> sessions_;
};

class MacishTypeAddonFactory : public fcitx::AddonFactory {
public:
    fcitx::AddonInstance *create(fcitx::AddonManager *manager) override;
};

} // namespace macishtype
