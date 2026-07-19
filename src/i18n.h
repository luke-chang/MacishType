#pragma once

#include <string>

namespace macishtype {

// Binds the fcitx5-macishtype gettext domain to whichever locale dir
// actually carries it: the dev install puts .mo files under
// ~/.local/share/locale, the production install under the system locale
// dir. gettext binds one directory per domain, so pick whichever applies.
void registerTextDomain();

// Translation in the addon's own domain.
std::string translated(const char *text);

} // namespace macishtype
