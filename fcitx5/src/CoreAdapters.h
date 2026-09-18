#pragma once

#include <fcitx-utils/event.h>
#include <fcitx-utils/eventdispatcher.h>

#include <MacishType/HostEventLoop.h>
#include <MacishType/HostSeams.h>
#include <MacishType/Logger.h>

#include "FontCoverage.h"

namespace MacishType::Fcitx5 {

// HostEventLoop over the fcitx event loop; the EventDispatcher backs the
// one thread-safe entry (post), used by the core fetch worker.
class HostEventLoop : public ::MacishType::HostEventLoop {
public:
    HostEventLoop(fcitx::EventLoop *eventLoop,
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
class CoreServices {
public:
    CoreServices();
    CoreServices(const CoreServices &) = delete;
    CoreServices &operator=(const CoreServices &) = delete;

private:
    class Logger : public ::MacishType::Logger {
    public:
        bool enabled(Level level) const override;
        void write(Level level, std::string_view message,
                   const std::source_location &where) override;
    };
    class ResourceLocator : public ::MacishType::ResourceLocator {
    public:
        std::filesystem::path
        locateRuntimeScript(std::string_view fileName) override;
        std::filesystem::path
        locateDataTable(std::string_view fileBase,
                        std::string_view language) override;
    };
    class PlatformInfo : public ::MacishType::PlatformInfo {
    public:
        std::string userAgentPrefix() override;
        std::vector<std::string> preferredLanguages() override;
    };
    class Translator : public ::MacishType::Translator {
    public:
        std::string translate(const char *text) override;
    };

    Logger logger_;
    ResourceLocator resources_;
    PlatformInfo platform_;
    Translator translator_;
    FontconfigCoverageProvider fontCoverage_;
};

} // namespace MacishType::Fcitx5
