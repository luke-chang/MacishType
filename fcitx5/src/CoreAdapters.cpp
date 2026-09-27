#include "CoreAdapters.h"

#include <cstring>

#include <sys/utsname.h>

#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string_view>
#include <utility>

#include <fcitx/instance.h>

#include <fcitx-utils/i18n.h>
#include <fcitx-utils/standardpaths.h>

#include "I18n.h"
#include "Log.h"
#include "OneShotTimer.h"

namespace MacishType::Fcitx5 {

// HostEventLoop -----------------------------------------------------------

namespace {

// Wraps a fcitx event source so destroying the seam handle cancels it.
template <typename Source>
class SourceHandle : public ::MacishType::HostEventLoop::Cancelable {
public:
    explicit SourceHandle(std::unique_ptr<Source> source)
        : source_(std::move(source)) {}

private:
    std::unique_ptr<Source> source_;
};

} // namespace

::MacishType::HostEventLoop::Handle
HostEventLoop::postDelayed(std::chrono::microseconds delay,
                           std::function<void()> callback) {
    return std::make_unique<SourceHandle<fcitx::EventSourceTime>>(
        scheduleOneShot(*eventLoop_, static_cast<uint64_t>(delay.count()),
                        std::move(callback)));
}

::MacishType::HostEventLoop::Handle
HostEventLoop::postDeferred(std::function<void()> callback) {
    auto source = eventLoop_->addDeferEvent(
        [callback = std::move(callback)](fcitx::EventSource *) mutable {
            auto localCallback = std::move(callback);
            localCallback();
            return true;
        });
    return std::make_unique<SourceHandle<fcitx::EventSource>>(
        std::move(source));
}

void HostEventLoop::post(std::function<void()> callback) {
    dispatcher_->schedule(std::move(callback));
}

// CoreServices ------------------------------------------------------------

namespace {

// The shared vocabulary has no warn level and nothing above error; fcitx5
// has no notice and stops at error. Both directions of that squeeze live
// here so enabled() and write() cannot disagree.
fcitx::LogLevel toFcitxLevel(::MacishType::Logger::Level level) {
    switch (level) {
    case ::MacishType::Logger::Level::Debug:
        return fcitx::LogLevel::Debug;
    case ::MacishType::Logger::Level::Info:
        return fcitx::LogLevel::Info;
    case ::MacishType::Logger::Level::Notice:
        return fcitx::LogLevel::Warn;
    case ::MacishType::Logger::Level::Error:
    case ::MacishType::Logger::Level::Fault:
        return fcitx::LogLevel::Error;
    }
    return fcitx::LogLevel::Info;
}

} // namespace

CoreServices::CoreServices() {
    HostServices services;
    services.resources = &resources_;
    services.platform = &platform_;
    services.translator = &translator_;
    services.fontCoverage = &fontCoverage_;
    setLogger(&logger_);
    setHostServices(services);
}

bool CoreServices::Logger::enabled(Level level) const {
    return macishtype_logcategory().checkLogLevel(toFcitxLevel(level));
}

void CoreServices::Logger::write(Level level,
                                 std::string_view message,
                                 const std::source_location &where) {
    // Built by hand rather than through FCITX_LOGC: that macro bakes its own
    // __FILE__/__LINE__ in as template arguments, which would name this
    // adapter instead of the call site. fcitx5 prints base names only, so
    // trim to match what its own lines look like.
    const char *file = where.file_name();
    if (const char *slash = std::strrchr(file, '/')) {
        file = slash + 1;
    }
    fcitx::LogMessageBuilder(fcitx::Log::logStream(), toFcitxLevel(level), file,
                             static_cast<int>(where.line()))
        << message;
}

std::filesystem::path CoreServices::ResourceLocator::
    locateRuntimeScript(std::string_view fileName) {
    return fcitx::StandardPaths::global().locate(
        fcitx::StandardPathsType::PkgData,
        "macishtype/" + std::string(fileName));
}

std::filesystem::path CoreServices::ResourceLocator::locateDataTable(
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

struct ModifierSubtags {
    std::string_view modifier;
    std::string_view script;
    std::string_view variant;
};

// glibc and gettext spell a script, and sometimes a variant, as a modifier
// (sr_RS@latin, sr@ijekavianlatin).
constexpr ModifierSubtags kModifiers[] = {
    {"cyrillic", "Cyrl", ""},
    {"devanagari", "Deva", ""},
    {"ijekavian", "", "ijekavsk"},
    {"ijekavianlatin", "Latn", "ijekavsk"},
    {"iqtelif", "Latn", ""},
    {"latin", "Latn", ""},
    {"valencia", "", "valencia"},
};

// glibc locales written in a script other than the one CLDR's likely
// subtags give their language and region.
constexpr std::pair<std::string_view, std::string_view> kLocaleScripts[] = {
    {"bhb_IN", "Latn"}, {"crh_UA", "Latn"}, {"hif_FJ", "Latn"},
    {"sat_IN", "Deva"}, {"sd_IN", "Arab"},  {"sr_ME", "Cyrl"},
};

// A POSIX locale name, language[_territory][.codeset][@modifier], as BCP 47:
// "sr_RS.UTF-8@latin" → "sr-Latn-RS"; empty or "C"/"POSIX" → empty. A script
// stays even where it is redundant; core drops it there.
std::string bcp47FromLocale(const std::string &locale) {
    std::string_view name = locale;
    ModifierSubtags subtags{};
    if (size_t at = name.find('@'); at != std::string_view::npos) {
        for (const auto &entry : kModifiers) {
            if (entry.modifier == name.substr(at + 1)) {
                subtags = entry;
            }
        }
        name = name.substr(0, at);
    }
    name = name.substr(0, name.find('.'));
    if (name.empty() || name == "C" || name == "POSIX") {
        return {};
    }
    std::string_view script = subtags.script;
    for (const auto &[localeName, localeScript] : kLocaleScripts) {
        if (script.empty() && localeName == name) {
            script = localeScript;
        }
    }
    size_t split = std::min(name.find('_'), name.size());
    std::string tag(name.substr(0, split));
    if (!script.empty()) {
        tag.append("-").append(script);
    }
    tag.append(name.substr(split));
    if (!subtags.variant.empty()) {
        tag.append("-").append(subtags.variant);
    }
    std::replace(tag.begin(), tag.end(), '_', '-');
    return tag;
}

} // namespace

std::string CoreServices::PlatformInfo::userAgentPrefix() {
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
CoreServices::PlatformInfo::preferredLanguages() {
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

std::string CoreServices::Translator::translate(const char *text) {
    return fcitx::translateDomain(kTextDomain, text);
}

} // namespace MacishType::Fcitx5
