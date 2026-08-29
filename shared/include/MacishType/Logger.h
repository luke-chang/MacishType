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

    // Answered live at every logging call site, so a sink whose backend has
    // its own verbosity control (fcitx5's log category, an ETW provider's
    // enable state) stays authoritative without anything having to mirror
    // it. Lines that fail this never build their LogLine. Default admits
    // everything, so a sink that does not filter need not override.
    virtual bool enabled(Level level) const {
        (void)level;
        return true;
    }

    // `where` is the MACISHTYPE_* call site, not this seam. Sinks that carry
    // structured fields (ETW) should record it; ones writing a text line
    // should follow their platform's convention — fcitx5 prints the base
    // name only.
    virtual void write(Level level, std::string_view message,
                       const std::source_location &where) = 0;
};

// Borrowed; the installer keeps it alive for the process lifetime. With no
// logger installed nothing is emitted, and logEnabled() reports everything
// off so callers do not format lines that have nowhere to go.
void setLogger(Logger *logger);
Logger *logger();

inline bool logEnabled(Logger::Level level) {
    const Logger *sink = logger();
    return sink != nullptr && sink->enabled(level);
}

} // namespace MacishType
