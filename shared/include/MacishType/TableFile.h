#pragma once

#include <filesystem>
#include <functional>
#include <optional>
#include <string>
#include <string_view>

namespace MacishType {

// Whole file into memory; nullopt when it cannot be opened or read.
std::optional<std::string> readFileBytes(const std::filesystem::path &path);

// One definition of the prepared-data-table format every C++ host reads
// (macOS parses its own copy in Swift): blank lines and lines starting with
// '#' are skipped, every other line is split on its first TAB, a trailing CR
// is dropped so a CRLF table reads like an LF one, and a line with no TAB is
// dropped.
//
// The views handed to `visit` point into a buffer this call owns and stay
// valid only for the duration of the call.
//
// Returns false when the file cannot be read, so each caller reports the
// miss in its own vocabulary. Which split lines are worth keeping is likewise
// the caller's question — `visit` sees all of them.
bool forEachTableLine(
    const std::filesystem::path &path,
    const std::function<void(std::string_view key, std::string_view value)>
        &visit);

} // namespace MacishType
