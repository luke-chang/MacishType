#include "MacishType/HostSeams.h"

#include "MacishType/Log.h"

namespace MacishType {

namespace {

HostServices installedServices;

} // namespace

void setHostServices(const HostServices &services) {
    installedServices = services;
    // The log facade lives in the shared library and keeps its own sink,
    // so a host that only links that library still gets MACISHTYPE_*.
    setLogger(services.logger);
}

const HostServices &hostServices() { return installedServices; }

std::string translated(const char *text) {
    if (Translator *translator = installedServices.translator) {
        return translator->translate(text);
    }
    return text;
}

} // namespace MacishType
