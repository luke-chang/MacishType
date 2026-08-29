#include "MacishType/HostSeams.h"

#include "MacishType/HostLog.h"

namespace macishtype {

namespace {

HostServices installedServices;

} // namespace

void setHostServices(const HostServices &services) {
    installedServices = services;
}

const HostServices &hostServices() { return installedServices; }

std::string translated(const char *text) {
    if (Translator *translator = installedServices.translator) {
        return translator->translate(text);
    }
    return text;
}

LogLine::~LogLine() {
    if (Logger *logger = installedServices.logger) {
        logger->write(level_, stream_.str());
    }
}

} // namespace macishtype
