#pragma once

#include <sstream>

#include "macishtype/hostseams.h"

namespace macishtype {

// Stream-shaped log line: MACISHTYPE_ERROR() << "engine " << id << " gone".
// Flushes one message to the installed Logger on destruction; dropped
// silently when no logger is installed.
class LogLine {
public:
    explicit LogLine(Logger::Level level) : level_(level) {}
    ~LogLine();
    LogLine(const LogLine &) = delete;
    LogLine &operator=(const LogLine &) = delete;

    template <typename T>
    LogLine &operator<<(const T &value) {
        stream_ << value;
        return *this;
    }

private:
    Logger::Level level_;
    std::ostringstream stream_;
};

#define MACISHTYPE_DEBUG()                                                     \
    ::macishtype::LogLine(::macishtype::Logger::Level::Debug)
#define MACISHTYPE_INFO()                                                      \
    ::macishtype::LogLine(::macishtype::Logger::Level::Info)
#define MACISHTYPE_WARN()                                                      \
    ::macishtype::LogLine(::macishtype::Logger::Level::Notice)
#define MACISHTYPE_ERROR()                                                     \
    ::macishtype::LogLine(::macishtype::Logger::Level::Error)
#define MACISHTYPE_FAULT()                                                     \
    ::macishtype::LogLine(::macishtype::Logger::Level::Fault)

} // namespace macishtype
