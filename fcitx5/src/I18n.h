#pragma once

// translated() lives in the core seams (installed by FcitxCoreServices);
// included here so the addon's call sites keep their original shape.
#include <MacishType/HostSeams.h>

namespace macishtype {

// gettext domain of this addon; bound by registerTextDomain, consumed by
// the Translator seam adapter.
inline constexpr char kTextDomain[] = "fcitx5-macishtype";

// Binds the gettext domain to whichever locale dir actually carries it:
// the dev install puts .mo files under ~/.local/share/locale, the
// production install under the system locale dir. gettext binds one
// directory per domain, so pick whichever applies.
void registerTextDomain();

} // namespace macishtype
