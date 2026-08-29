#pragma once

#include <fcitx-utils/event.h>
#include <fcitx-utils/eventdispatcher.h>

#include <MacishType/HostEventLoop.h>
#include <MacishType/HostSeams.h>

#include "FontCoverage.h"

namespace macishtype {

// HostEventLoop over the fcitx event loop; the EventDispatcher backs the
// one thread-safe entry (post), used by the core fetch worker.
class FcitxHostEventLoop : public HostEventLoop {
public:
    FcitxHostEventLoop(fcitx::EventLoop *eventLoop,
                       fcitx::EventDispatcher *dispatcher)
        : eventLoop_(eventLoop), dispatcher_(dispatcher) {}

    Handle postDelayed(std::chrono::microseconds delay,
                       std::function<void()> callback) override;
    Handle postDeferred(std::function<void()> callback) override;
    void post(std::function<void()> callback) override;

private:
    fcitx::EventLoop *eventLoop_;
    fcitx::EventDispatcher *dispatcher_;
};

// The ambient core seams implemented against fcitx5. Constructing an
// instance installs them process-wide (setHostServices); keep it alive for
// the whole addon lifetime — the installed pointers reference its members.
class FcitxCoreServices {
public:
    FcitxCoreServices();
    FcitxCoreServices(const FcitxCoreServices &) = delete;
    FcitxCoreServices &operator=(const FcitxCoreServices &) = delete;

private:
    class FcitxLogger : public Logger {
    public:
        void write(Level level, std::string_view message) override;
    };
    class FcitxResourceLocator : public ResourceLocator {
    public:
        std::filesystem::path
        locateRuntimeScript(std::string_view fileName) override;
        std::filesystem::path
        locateDataTable(std::string_view fileBase,
                        std::string_view language) override;
    };
    class FcitxPlatformInfo : public PlatformInfo {
    public:
        std::string userAgentPrefix() override;
        std::vector<std::string> preferredLanguages() override;
    };
    class FcitxTranslator : public Translator {
    public:
        std::string translate(const char *text) override;
    };

    FcitxLogger logger_;
    FcitxResourceLocator resources_;
    FcitxPlatformInfo platform_;
    FcitxTranslator translator_;
    FontconfigCoverageProvider fontCoverage_;
};

} // namespace macishtype
