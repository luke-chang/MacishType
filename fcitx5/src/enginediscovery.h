#pragma once

#include <filesystem>
#include <optional>
#include <string>
#include <vector>

#include "jshost/manifest.h"

namespace macishtype {

// Which icon candidate a manifest icon base name resolved to. The kind is
// reported rather than re-derived from the resolved path: a plain `icon.svg`
// may itself be a symlink to some `…-symbolic.svg`, so the file name alone
// cannot say whether the engine asked for a recolorable variant.
enum class IconKind { None, SymbolicSvg, Svg, Png };

struct ResolvedIcon {
    // Absolute path inside the engine root; empty when nothing matched.
    std::string path;
    IconKind kind = IconKind::None;
};

struct EngineInfo {
    // Folder name under the engines directory; [A-Za-z0-9_-] only.
    // Doubles as the stable identity: the input method unique name is
    // "macishtype-<id>" and per-engine data is keyed by it.
    std::string id;
    // Engine folder as discovered (may be a symlink; resolved lazily by the
    // JS host, which needs realpath containment anyway).
    std::filesystem::path root;
    ManifestData manifest;
    // Manifest icon resolved against the engine folder. Discovery only reads
    // from disk; installing it into the icon theme (and thus deciding what
    // panels are handed) belongs to the addon.
    ResolvedIcon icon;
    // What panels are served for this engine: an icon-theme name once the
    // addon has installed one, else `icon.path`. Empty when there is no icon.
    std::string iconName;
    // Engine-private persistence (localStorage). User-layer engines keep
    // the macOS convention of `_storage/` inside the engine folder, so the
    // folder stays self-contained; system-layer engines live in read-only,
    // machine-shared /usr, so their storage goes to the per-user XDG state
    // directory instead.
    std::filesystem::path storageRoot;

    std::string displayName() const {
        return manifest.displayName.empty() ? id : manifest.displayName;
    }
};

// Whether a folder name qualifies as an engine id. Also the character set any
// name derived from an id must accept, so derived-name parsers cannot drift
// from discovery.
bool isValidEngineId(const std::string &name);

// Candidate absolute paths an icon base name (empty = the default base
// "icon") may resolve to, in priority order — also the files whose changes
// should refresh the icon. Empty when the engine root cannot be resolved.
std::vector<std::string> iconCandidatePaths(const std::filesystem::path &root,
                                            const std::string &icon);

// Resolves the icon base name to the first existing candidate, reporting
// which one matched, and enforcing the same containment discipline as the
// engine:/// module loader: the file must resolve inside the engine folder.
// kind is None when nothing matches.
ResolvedIcon resolveIcon(const std::filesystem::path &root,
                         const std::string &icon);

// Scans <pkgdata>/macishtype/engines/* across XDG layers (user shadows
// system). A folder qualifies if its name is valid and it carries a
// parsable manifest.json. Returns engines sorted by id for stable listing
// order. When `sawUnparsableManifest` is given, it is set to whether any
// validly-named folder was skipped for a manifest that did not parse (a
// new engine still being authored).
std::vector<EngineInfo>
discoverEngines(const std::vector<std::string> &languages,
                bool *sawUnparsableManifest = nullptr);

// Resolves one engine id to its winning XDG layer (same first-layer-wins
// order as discoverEngines) and rebuilds its EngineInfo from disk. nullopt
// when no layer holds a directory with a parsable manifest.
std::optional<EngineInfo>
discoverEngine(const std::string &id,
               const std::vector<std::string> &languages);

} // namespace macishtype
