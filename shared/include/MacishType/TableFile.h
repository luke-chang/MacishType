#pragma once

#include <filesystem>
#include <functional>
#include <string>

namespace MacishType {

// One definition of the prepared-data-table format every host reads: blank
// lines and lines starting with '#' are skipped, every other line is split on
// its first TAB, and a line with no TAB is dropped.
//
// Returns false when the file cannot be opened, so each caller reports the
// miss in its own vocabulary. Which split lines are worth keeping is likewise
// the caller's question — `visit` sees all of them.
bool forEachTableLine(
    const std::filesystem::path &path,
    const std::function<void(const std::string &key,
                             const std::string &value)> &visit);

} // namespace MacishType
