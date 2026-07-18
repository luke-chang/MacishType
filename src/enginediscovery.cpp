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

std::vector<EngineInfo> discoverEngines() {
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
        std::error_code errorCode;
        if (!std::filesystem::is_regular_file(fullPath / "manifest.json",
                                              errorCode)) {
            MACISHTYPE_WARN() << "Skipping engine folder without "
                                 "manifest.json: "
                              << fullPath;
            continue;
        }
        engines.push_back(EngineInfo{id, fullPath, id});
    }

    std::sort(engines.begin(), engines.end(),
              [](const EngineInfo &lhs, const EngineInfo &rhs) {
                  return lhs.id < rhs.id;
              });
    return engines;
}

} // namespace macishtype
