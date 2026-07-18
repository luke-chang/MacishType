#include "enginediscovery.h"

#include <algorithm>
#include <system_error>

#include <fcitx-utils/standardpaths.h>

#include "log.h"

namespace macishtype {

namespace {

constexpr char kEnginesSubdir[] = "macishtype/engines";

bool isValidEngineId(const std::string &name) {
    if (name.empty()) {
        return false;
    }
    return std::all_of(name.begin(), name.end(), [](char ch) {
        return (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') ||
               ch == '_' || ch == '-';
    });
}

} // namespace

std::vector<std::string>
iconCandidatePaths(const std::filesystem::path &root,
                   const std::string &icon) {
    // The manifest declares an extensionless base name; each host appends
    // its platform's suffixes. First match wins, so a recolorable symbolic
    // variant beats plain ones when an engine ships several.
    static constexpr const char *kSuffixes[] = {"-symbolic.svg", ".svg",
                                                ".png"};
    std::error_code errorCode;
    auto canonicalRoot = std::filesystem::canonical(root, errorCode);
    if (errorCode) {
        return {};
    }
    const std::string base = icon.empty() ? "icon" : icon;
    std::vector<std::string> candidates;
    for (const char *suffix : kSuffixes) {
        candidates.push_back((canonicalRoot / (base + suffix)).string());
    }
    return candidates;
}

std::string resolveIconPath(const std::filesystem::path &root,
                            const std::string &icon) {
    std::error_code errorCode;
    auto canonicalRoot = std::filesystem::canonical(root, errorCode);
    if (errorCode) {
        return {};
    }
    auto rootPrefix = canonicalRoot.string() + "/";
    for (const auto &candidate : iconCandidatePaths(root, icon)) {
        auto path = std::filesystem::canonical(candidate, errorCode);
        if (errorCode || !std::filesystem::is_regular_file(path, errorCode)) {
            continue;
        }
        // Candidates sit inside the root by construction, but a symlinked
        // file may still point elsewhere.
        if (path.string().rfind(rootPrefix, 0) != 0) {
            MACISHTYPE_WARN() << "Manifest icon escapes the engine folder: "
                              << path;
            continue;
        }
        return path.string();
    }
    // Silence is correct for the probe of the implicit default; only a
    // base the manifest asked for deserves a warning.
    if (!icon.empty()) {
        MACISHTYPE_WARN() << "Manifest icon matches no file: " << root / icon
                          << "{-symbolic.svg,.svg,.png}";
    }
    return {};
}

std::vector<EngineInfo>
discoverEngines(const std::vector<std::string> &languages) {
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
            MACISHTYPE_WARN()
                << "Skipping engine folder with invalid name (want lowercase "
                   "[a-z0-9_-]): "
                << fullPath;
            continue;
        }
        auto manifest = parseManifest(fullPath / "manifest.json", languages);
        if (!manifest) {
            MACISHTYPE_WARN() << "Skipping engine folder without a valid "
                                 "manifest.json: "
                              << fullPath;
            continue;
        }
        EngineInfo engine{id, fullPath, std::move(*manifest), {}};
        engine.iconPath = resolveIconPath(engine.root, engine.manifest.icon);
        engines.push_back(std::move(engine));
    }

    std::sort(engines.begin(), engines.end(),
              [](const EngineInfo &lhs, const EngineInfo &rhs) {
                  return lhs.id < rhs.id;
              });
    return engines;
}

} // namespace macishtype
