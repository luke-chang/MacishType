#include "EngineDiscovery.h"

#include <algorithm>
#include <cstdlib>
#include <system_error>

#include <fcitx-utils/standardpaths.h>

#include "Log.h"

namespace MacishType {

namespace {

constexpr char kEnginesSubdir[] = "macishtype/engines";

std::filesystem::path xdgStateHome() {
    if (const char *stateHome = std::getenv("XDG_STATE_HOME");
        stateHome != nullptr && stateHome[0] != '\0') {
        return stateHome;
    }
    const char *home = std::getenv("HOME");
    return std::filesystem::path(home != nullptr ? home : "") /
           ".local/state";
}

std::filesystem::path storageRootForEngine(const std::string &id,
                                           const std::filesystem::path &root,
                                           bool userLayer) {
    if (!userLayer) {
        return xdgStateHome() / "fcitx5/macishtype" / id;
    }
    // Match the canonical form the JS host uses for its own paths, so
    // watcher events and self-write records compare equal.
    std::error_code errorCode;
    auto canonicalRoot = std::filesystem::canonical(root, errorCode);
    return (errorCode ? root : canonicalRoot) / "_storage";
}

// The manifest declares an extensionless base name; each host appends its
// platform's suffixes. First match wins, so a recolorable symbolic variant
// beats plain ones when an engine ships several. Kind travels with the suffix
// so the two can never drift apart.
struct IconSuffix {
    const char *suffix;
    IconKind kind;
};
constexpr IconSuffix kIconSuffixes[] = {
    {"-symbolic.svg", IconKind::SymbolicSvg},
    {".svg", IconKind::Svg},
    {".png", IconKind::Png},
};

} // namespace

std::vector<std::string>
iconCandidatePaths(const std::filesystem::path &root,
                   const std::string &icon) {
    std::error_code errorCode;
    auto canonicalRoot = std::filesystem::canonical(root, errorCode);
    if (errorCode) {
        return {};
    }
    const std::string base = icon.empty() ? "icon" : icon;
    std::vector<std::string> candidates;
    for (const auto &candidate : kIconSuffixes) {
        candidates.push_back(
            (canonicalRoot / (base + candidate.suffix)).string());
    }
    return candidates;
}

ResolvedIcon resolveIcon(const std::filesystem::path &root,
                         const std::string &icon) {
    std::error_code errorCode;
    auto canonicalRoot = std::filesystem::canonical(root, errorCode);
    if (errorCode) {
        return {};
    }
    auto rootPrefix = canonicalRoot.string() + "/";
    const std::string base = icon.empty() ? "icon" : icon;
    for (const auto &candidate : kIconSuffixes) {
        auto path = std::filesystem::canonical(
            canonicalRoot / (base + candidate.suffix), errorCode);
        if (errorCode || !std::filesystem::is_regular_file(path, errorCode)) {
            continue;
        }
        // Candidates sit inside the root by construction, but a symlinked
        // file may still point elsewhere.
        if (path.string().rfind(rootPrefix, 0) != 0) {
            MACISHTYPE_NOTICE() << "Manifest icon escapes the engine folder: "
                                << path;
            continue;
        }
        return {path.string(), candidate.kind};
    }
    // Silence is correct for the probe of the implicit default; only a
    // base the manifest asked for deserves a warning.
    if (!icon.empty()) {
        MACISHTYPE_NOTICE() << "Manifest icon matches no file: " << root / icon
                            << "{-symbolic.svg,.svg,.png}";
    }
    return {};
}

namespace {

// Builds the EngineInfo for one already-located folder; nullopt when the
// manifest does not parse.
std::optional<EngineInfo>
buildEngineInfo(const std::string &id, const std::filesystem::path &fullPath,
                const std::vector<std::string> &languages) {
    auto manifest = parseManifest(fullPath / "manifest.json", languages);
    if (!manifest) {
        MACISHTYPE_NOTICE() << "Skipping engine folder without a valid "
                               "manifest.json: "
                            << fullPath;
        return std::nullopt;
    }
    // Assigned field by field: positional aggregate init would silently
    // misalign the moment EngineInfo gains or reorders a member.
    EngineInfo engine;
    engine.id = id;
    engine.root = fullPath;
    engine.manifest = std::move(*manifest);
    engine.icon = resolveIcon(engine.root, engine.manifest.icon);
    // Discovery serves the resolved path; the addon overwrites this with an
    // icon-theme name once it has installed one.
    engine.iconName = engine.icon.path;
    auto userEngines =
        fcitx::StandardPaths::global().userDirectory(
            fcitx::StandardPathsType::PkgData) /
        kEnginesSubdir;
    const bool userLayer =
        fullPath.string().rfind(userEngines.string() + "/", 0) == 0;
    engine.storageRoot = storageRootForEngine(id, fullPath, userLayer);
    return engine;
}

} // namespace

std::vector<EngineInfo>
discoverEngines(const std::vector<std::string> &languages,
                bool *sawUnparsableManifest) {
    if (sawUnparsableManifest != nullptr) {
        *sawUnparsableManifest = false;
    }
    const auto &paths = fcitx::StandardPaths::global();
    auto folders = paths.locate(
        fcitx::StandardPathsType::PkgData, kEnginesSubdir,
        [](const std::filesystem::path &path) {
            std::error_code errorCode;
            return std::filesystem::is_directory(path, errorCode);
        });

    std::vector<EngineInfo> engines;
    for (const auto &[name, fullPath] : folders) {
        const auto u8id = name.u8string();
        std::string id(u8id.begin(), u8id.end());
        if (!isValidEngineId(id)) {
            MACISHTYPE_NOTICE()
                << "Skipping engine folder with invalid name (want "
                   "[A-Za-z0-9_-]): "
                << fullPath;
            continue;
        }
        if (auto engine = buildEngineInfo(id, fullPath, languages)) {
            engines.push_back(std::move(*engine));
        } else if (sawUnparsableManifest != nullptr) {
            // A validly-named folder that failed to parse: a new engine
            // mid-authoring. The caller keeps its update affordance live so
            // the next pull re-scans once the manifest is fixed.
            *sawUnparsableManifest = true;
        }
    }

    std::sort(engines.begin(), engines.end(),
              [](const EngineInfo &lhs, const EngineInfo &rhs) {
                  return lhs.id < rhs.id;
              });
    return engines;
}

std::optional<EngineInfo>
discoverEngine(const std::string &id,
               const std::vector<std::string> &languages) {
    if (!isValidEngineId(id)) {
        return std::nullopt;
    }
    // First is_directory hit wins, matching discoverEngines' map locate
    // (both enumerate layers in StandardPaths priority order).
    auto candidates = fcitx::StandardPaths::global().locateAll(
        fcitx::StandardPathsType::PkgData,
        std::filesystem::path(kEnginesSubdir) / id);
    for (const auto &candidate : candidates) {
        std::error_code errorCode;
        if (!std::filesystem::is_directory(candidate, errorCode)) {
            continue;
        }
        return buildEngineInfo(id, candidate, languages);
    }
    return std::nullopt;
}

} // namespace MacishType
