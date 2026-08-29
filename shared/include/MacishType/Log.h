#pragma once

#include <source_location>
#include <sstream>

#include "MacishType/Logger.h"

namespace MacishType {

// Stream-shaped log line: MACISHTYPE_ERROR() << "engine " << id << " gone".
// Flushes one message to the installed Logger on destruction; dropped
// silently when no logger is installed.
class LogLine {
public:
    // The default argument is evaluated where the macro expands, so `where`
    // names the logging call site rather than anything in here.
    explicit LogLine(
        Logger::Level level,
        std::source_location where = std::source_location::current())
        : level_(level), where_(where) {}
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
    std::source_location where_;
    std::ostringstream stream_;
};

#define MACISHTYPE_DEBUG()                                                     \
    ::MacishType::LogLine(::MacishType::Logger::Level::Debug)
#define MACISHTYPE_INFO()                                                      \
    ::MacishType::LogLine(::MacishType::Logger::Level::Info)
#define MACISHTYPE_NOTICE()                                                    \
    ::MacishType::LogLine(::MacishType::Logger::Level::Notice)
#define MACISHTYPE_ERROR()                                                     \
    ::MacishType::LogLine(::MacishType::Logger::Level::Error)
#define MACISHTYPE_FAULT()                                                     \
    ::MacishType::LogLine(::MacishType::Logger::Level::Fault)

} // namespace MacishType
