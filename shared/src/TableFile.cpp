#include "MacishType/TableFile.h"

#include <fstream>
#include <ios>

namespace MacishType {

std::optional<std::string> readFileBytes(const std::filesystem::path &path) {
    std::ifstream stream(path, std::ios::binary | std::ios::ate);
    if (!stream) {
        return std::nullopt;
    }
    std::streamoff size = stream.tellg();
    if (size < 0) {
        return std::nullopt;
    }
    std::string contents(static_cast<size_t>(size), '\0');
    stream.seekg(0);
    if (size > 0 && !stream.read(contents.data(), size)) {
        return std::nullopt;
    }
    return contents;
}

bool forEachTableLine(
    const std::filesystem::path &path,
    const std::function<void(std::string_view key, std::string_view value)>
        &visit) {
    // Read whole and split in place; the stream extractors this replaces
    // dominated the cost of a load.
    auto contents = readFileBytes(path);
    if (!contents) {
        return false;
    }
    std::string_view rest(*contents);
    while (!rest.empty()) {
        size_t newline = rest.find('\n');
        std::string_view line = rest.substr(0, newline);
        rest.remove_prefix(newline == std::string_view::npos ? rest.size()
                                                             : newline + 1);
        if (!line.empty() && line.back() == '\r') {
            line.remove_suffix(1);
        }
        if (line.empty() || line.front() == '#') {
            continue;
        }
        auto tab = line.find('\t');
        if (tab == std::string_view::npos) {
            continue;
        }
        visit(line.substr(0, tab), line.substr(tab + 1));
    }
    return true;
}

} // namespace MacishType
