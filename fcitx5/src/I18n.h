#pragma once

// translated() lives in the core seams, installed by CoreServices.
#include <MacishType/HostSeams.h>

namespace MacishType::Fcitx5 {

// gettext domain of this addon; bound by registerTextDomain, consumed by
// the Translator seam adapter.
inline constexpr char kTextDomain[] = "fcitx5-macishtype";

// Binds the gettext domain to whichever locale dir actually carries it:
// the dev install puts .mo files under ~/.local/share/locale, the
// production install under the system locale dir. gettext binds one
// directory per domain, so pick whichever applies.
void registerTextDomain();

} // namespace MacishType::Fcitx5
