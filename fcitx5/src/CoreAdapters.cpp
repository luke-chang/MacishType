#include "CoreAdapters.h"

#include <sys/utsname.h>

#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <sstream>

#include <fcitx/instance.h>

#include <fcitx-utils/i18n.h>
#include <fcitx-utils/standardpaths.h>

#include "I18n.h"
#include "Log.h"

namespace macishtype {

// FcitxHostEventLoop ------------------------------------------------------

namespace {

// Wraps a fcitx event source so destroying the seam handle cancels it.
template <typename Source>
class SourceHandle : public HostEventLoop::Cancelable {
public:
    explicit SourceHandle(std::unique_ptr<Source> source)
        : source_(std::move(source)) {}

private:
    std::unique_ptr<Source> source_;
};

} // namespace

HostEventLoop::Handle
FcitxHostEventLoop::postDelayed(std::chrono::microseconds delay,
                                std::function<void()> callback) {
    auto source = eventLoop_->addTimeEvent(
        CLOCK_MONOTONIC, fcitx::now(CLOCK_MONOTONIC) + delay.count(), 0,
        [callback = std::move(callback)](fcitx::EventSourceTime *,
                                         uint64_t) mutable {
            // The callback may reset its own handle, destroying this
            // closure; run a stack-local move so it survives its own
            // cancelation.
            auto localCallback = std::move(callback);
            localCallback();
            return true;
        });
    return std::make_unique<SourceHandle<fcitx::EventSourceTime>>(
        std::move(source));
}

HostEventLoop::Handle
FcitxHostEventLoop::postDeferred(std::function<void()> callback) {
    auto source = eventLoop_->addDeferEvent(
        [callback = std::move(callback)](fcitx::EventSource *) mutable {
            auto localCallback = std::move(callback);
            localCallback();
            return true;
        });
    return std::make_unique<SourceHandle<fcitx::EventSource>>(
        std::move(source));
}

void FcitxHostEventLoop::post(std::function<void()> callback) {
    dispatcher_->schedule(std::move(callback));
}

// FcitxCoreServices -------------------------------------------------------

FcitxCoreServices::FcitxCoreServices() {
    HostServices services;
    services.logger = &logger_;
    services.resources = &resources_;
    services.platform = &platform_;
    services.translator = &translator_;
    services.fontCoverage = &fontCoverage_;
    setHostServices(services);
}

void FcitxCoreServices::FcitxLogger::write(Level level,
                                           std::string_view message) {
    const std::string text(message);
    switch (level) {
    case Level::Debug:
        FCITX_LOGC(macishtype_logcategory, Debug) << text;
        break;
    case Level::Info:
        FCITX_LOGC(macishtype_logcategory, Info) << text;
        break;
    case Level::Notice:
        FCITX_LOGC(macishtype_logcategory, Warn) << text;
        break;
    case Level::Error:
    case Level::Fault:
        // fcitx has no level above Error; fold Fault into it.
        FCITX_LOGC(macishtype_logcategory, Error) << text;
        break;
    }
}

std::filesystem::path FcitxCoreServices::FcitxResourceLocator::
    locateRuntimeScript(std::string_view fileName) {
    return fcitx::StandardPaths::global().locate(
        fcitx::StandardPathsType::PkgData,
        "macishtype/" + std::string(fileName));
}

std::filesystem::path FcitxCoreServices::FcitxResourceLocator::locateDataTable(
    std::string_view fileBase, std::string_view language) {
    return fcitx::StandardPaths::global().locate(
        fcitx::StandardPathsType::PkgData,
        "macishtype/tables/" + std::string(fileBase) + "." +
            std::string(language) + ".txt");
}

// navigator.userAgent platform segment helpers. Each host info axis is
// resolved independently so a missing source drops only its own token.
namespace {

std::string displayServerName() {
    const char *sessionType = std::getenv("XDG_SESSION_TYPE");
    if (sessionType == nullptr) {
        return {};
    }
    const std::string_view type(sessionType);
    if (type == "wayland") {
        return "Wayland";
    }
    if (type == "x11") {
        return "X11";
    }
    return {};
}

std::string machineArchitecture() {
    struct utsname info;
    if (uname(&info) != 0) {
        return {};
    }
    return info.machine;
}

// Distro label like "Ubuntu 26.04" from /etc/os-release NAME + VERSION_ID.
std::string distroLabel() {
    std::ifstream file("/etc/os-release");
    if (!file) {
        return {};
    }
    std::string name;
    std::string versionId;
    std::string line;
    const auto readField = [&line](std::string_view key, std::string &out) {
        if (line.rfind(key, 0) != 0) {
            return;
        }
        std::string value = line.substr(key.size());
        if (value.size() >= 2 && value.front() == '"' && value.back() == '"') {
            value = value.substr(1, value.size() - 2);
        }
        out = std::move(value);
    };
    while (std::getline(file, line)) {
        readField("NAME=", name);
        readField("VERSION_ID=", versionId);
    }
    if (name.empty()) {
        return {};
    }
    if (versionId.empty()) {
        return name;
    }
    return name + " " + versionId;
}

// "zh_TW.UTF-8" → "zh-TW"; empty or "C"/"POSIX" → empty.
std::string bcp47FromLocale(const std::string &locale) {
    std::string tag = locale.substr(0, locale.find('.'));
    tag = tag.substr(0, tag.find('@'));
    if (tag.empty() || tag == "C" || tag == "POSIX") {
        return {};
    }
    std::replace(tag.begin(), tag.end(), '_', '-');
    return tag;
}

} // namespace

std::string FcitxCoreServices::FcitxPlatformInfo::userAgentPrefix() {
    // Product token stays "MacishType/" across host ports; platform tokens
    // and the fcitx5 segment identify this Linux host.
    std::vector<std::string> platformTokens;
    if (std::string displayServer = displayServerName();
        !displayServer.empty()) {
        platformTokens.push_back(std::move(displayServer));
    }
    if (std::string arch = machineArchitecture(); !arch.empty()) {
        platformTokens.push_back("Linux " + arch);
    } else {
        platformTokens.emplace_back("Linux");
    }
    if (std::string distro = distroLabel(); !distro.empty()) {
        platformTokens.push_back(std::move(distro));
    }
    std::string platform;
    for (size_t i = 0; i < platformTokens.size(); ++i) {
        if (i != 0) {
            platform += "; ";
        }
        platform += platformTokens[i];
    }
    return std::string("MacishType/") + MACISHTYPE_VERSION + " (" + platform +
           ") fcitx5/" + fcitx::Instance::version();
}

std::vector<std::string>
FcitxCoreServices::FcitxPlatformInfo::preferredLanguages() {
    std::vector<std::string> languages;
    auto push = [&](const std::string &tag) {
        if (!tag.empty() &&
            std::find(languages.begin(), languages.end(), tag) ==
                languages.end()) {
            languages.push_back(tag);
        }
    };
    if (const char *languageList = std::getenv("LANGUAGE")) {
        std::stringstream stream(languageList);
        std::string item;
        while (std::getline(stream, item, ':')) {
            push(bcp47FromLocale(item));
        }
    }
    for (const char *name : {"LC_ALL", "LC_MESSAGES", "LANG"}) {
        if (const char *value = std::getenv(name)) {
            push(bcp47FromLocale(value));
        }
    }
    return languages;
}

std::string FcitxCoreServices::FcitxTranslator::translate(const char *text) {
    return fcitx::translateDomain(kTextDomain, text);
}

} // namespace macishtype
