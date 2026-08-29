#pragma once

#include <source_location>
#include <string_view>

namespace MacishType {

// Log sink installed by the embedding process. Shared by every MacishType
// host: the JS engine host routes its seam-supplied logger here, a native
// host installs its own.
//
// This header deliberately carries no MACISHTYPE_* macros — a host that
// only implements the sink (fcitx5 does; it keeps its own facade over
// FCITX_LOGC) must be able to include it without inheriting a second
// definition of them. Include Log.h to get the facade.
//
// Threading: write() SHOULD be thread-safe as defense in depth. Callers log
// from their loop thread today, but this interface does not promise that
// forever.
class Logger {
public:
    // fault = should-never-happen errors (missing file, malformed data),
    // error = ordinary failures, notice/info = state changes and routine
    // events. Matches the level vocabulary of the JS contract.
    enum class Level { Debug, Info, Notice, Error, Fault };

    virtual ~Logger() = default;
    // `where` is the MACISHTYPE_* call site, not this seam. Sinks that carry
    // structured fields (ETW) should record it; ones writing a text line
    // should follow their platform's convention — fcitx5 prints the base
    // name only.
    virtual void write(Level level, std::string_view message,
                       const std::source_location &where) = 0;
};

// Borrowed; the installer keeps it alive for the process lifetime. A null
// logger degrades gracefully — lines are dropped.
void setLogger(Logger *logger);
Logger *logger();

} // namespace MacishType
