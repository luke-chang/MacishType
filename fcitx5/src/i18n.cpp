#include "i18n.h"

#include <cstdlib>
#include <filesystem>

#include <fcitx-utils/i18n.h>

namespace macishtype {

namespace {
constexpr char kTextDomain[] = "fcitx5-macishtype";
} // namespace

void registerTextDomain() {
    const char *home = std::getenv("HOME");
    if (home != nullptr) {
        std::filesystem::path userLocale =
            std::filesystem::path(home) / ".local/share/locale";
        std::error_code errorCode;
        std::filesystem::directory_iterator languages(userLocale, errorCode);
        if (!errorCode) {
            for (const auto &language : languages) {
                if (std::filesystem::is_regular_file(
                        language.path() / "LC_MESSAGES" /
                            "fcitx5-macishtype.mo",
                        errorCode)) {
                    fcitx::registerDomain(kTextDomain, userLocale.c_str());
                    return;
                }
            }
        }
    }
    fcitx::registerDomain(kTextDomain, FCITX_INSTALL_LOCALEDIR);
}

std::string translated(const char *text) {
    return fcitx::translateDomain(kTextDomain, text);
}

} // namespace macishtype
