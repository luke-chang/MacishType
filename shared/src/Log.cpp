#include "MacishType/Log.h"

namespace MacishType {

namespace {

Logger *installedLogger = nullptr;

} // namespace

void setLogger(Logger *logger) { installedLogger = logger; }

Logger *logger() { return installedLogger; }

LogLine::~LogLine() {
    if (installedLogger != nullptr) {
        installedLogger->write(level_, stream_.str());
    }
}

} // namespace MacishType
