#include "MacishType/TableFile.h"

#include <fstream>

namespace MacishType {

bool forEachTableLine(
    const std::filesystem::path &path,
    const std::function<void(const std::string &key,
                             const std::string &value)> &visit) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) {
        return false;
    }
    std::string line;
    while (std::getline(stream, line)) {
        if (line.empty() || line[0] == '#') {
            continue;
        }
        auto tab = line.find('\t');
        if (tab == std::string::npos) {
            continue;
        }
        visit(line.substr(0, tab), line.substr(tab + 1));
    }
    return true;
}

} // namespace MacishType
