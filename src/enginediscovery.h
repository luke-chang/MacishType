#pragma once

#include <filesystem>
#include <string>
#include <vector>

#include "jshost/manifest.h"

namespace macishtype {

struct EngineInfo {
    // Folder name under the engines directory; lowercase [a-z0-9_-] only.
    // Doubles as the stable identity: the input method unique name is
    // "macishtype-<id>" and per-engine data is keyed by it.
    std::string id;
    // Engine folder as discovered (may be a symlink; resolved lazily by the
    // JS host, which needs realpath containment anyway).
    std::filesystem::path root;
    ManifestData manifest;
    // Manifest icon resolved to an absolute path inside root; panels load
    // the file directly (no icon-theme install). Empty when the manifest
    // declares no icon or the path is invalid.
    std::string iconPath;

    std::string displayName() const {
        return manifest.displayName.empty() ? id : manifest.displayName;
    }
};

// Resolves a manifest icon base name (empty = the default base "icon") to
// an absolute path by probing `<base>-symbolic.svg`, `<base>.svg`, then
// `<base>.png`, enforcing the same containment discipline as the
// engine:/// module loader: the file must resolve inside the engine
// folder. Returns empty when nothing matches.
std::string resolveIconPath(const std::filesystem::path &root,
                            const std::string &icon);

// Scans <pkgdata>/macishtype/engines/* across XDG layers (user shadows
// system). A folder qualifies if its name is valid and it carries a
// parsable manifest.json. Returns engines sorted by id for stable listing
// order.
std::vector<EngineInfo>
discoverEngines(const std::vector<std::string> &languages);

} // namespace macishtype
