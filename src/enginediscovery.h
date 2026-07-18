#pragma once

#include <filesystem>
#include <string>
#include <vector>

namespace macishtype {

struct EngineInfo {
    // Folder name under the engines directory; lowercase [a-z0-9_-] only.
    // Doubles as the stable identity: the input method unique name is
    // "macishtype-<id>" and per-engine data is keyed by it.
    std::string id;
    // Engine folder as discovered (may be a symlink; resolved lazily by the
    // JS host, which needs realpath containment anyway).
    std::filesystem::path root;
    // Human-readable name; falls back to id until the manifest is parsed.
    std::string displayName;
};

// Scans <pkgdata>/macishtype/engines/* across XDG layers (user shadows
// system). A folder qualifies if its name is valid and it contains a
// manifest.json. Returns engines sorted by id for stable listing order.
std::vector<EngineInfo> discoverEngines();

} // namespace macishtype
