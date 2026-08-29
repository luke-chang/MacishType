#include "MacishType/HostSeams.h"


namespace MacishType {

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

} // namespace MacishType
