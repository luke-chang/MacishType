#pragma once

#include <filesystem>
#include <string>
#include <string_view>
#include <vector>

#include "MacishType/Logger.h"

namespace MacishType {

// Host seam interfaces: the platform capabilities the core engine host
// needs from whichever process embeds it. Implementations are installed
// process-wide once at startup via setHostServices(), before any other
// core call — several consumers are free functions with no instance to
// hang a reference on.
//
// Threading contract: the host runs on a single loop thread. Every seam
// method is invoked on that thread only.

class ResourceLocator {
public:
    virtual ~ResourceLocator() = default;

    // Shared runtime script installed by the platform package
    // ("hostglue.js", "runtime.js"). Empty path = not installed.
    virtual std::filesystem::path
    locateRuntimeScript(std::string_view fileName) = 0;

    // Per-language host data table ("SymbolNames", "WordFrequency",
    // "AssociatedDictionary") keyed by the manifest's intended language.
    // Empty path = no table for this language.
    virtual std::filesystem::path
    locateDataTable(std::string_view fileBase, std::string_view language) = 0;
};

class PlatformInfo {
public:
    virtual ~PlatformInfo() = default;

    // "MacishType/<version> (<platform tokens>) <host>/<version>" — core
    // appends the JS engine token itself (only core knows the
    // interpreter and its version).
    virtual std::string userAgentPrefix() = 0;

    // BCP-47 language preferences, most preferred first. Feeds
    // navigator.languages and manifest name localization.
    virtual std::vector<std::string> preferredLanguages() = 0;
};

class Translator {
public:
    virtual ~Translator() = default;

    // msgid -> localized text in the host UI language; returns the msgid
    // unchanged when no translation exists.
    virtual std::string translate(const char *text) = 0;
};

class FontCoverageProvider {
public:
    virtual ~FontCoverageProvider() = default;

    // Base64 codepoint-coverage bitmap for the manifest fontCoverage
    // module. Cached by the provider; the reference stays valid for the
    // process lifetime.
    virtual const std::string &coverageBitmapBase64() = 0;
};

struct HostServices {
    Logger *logger = nullptr;
    ResourceLocator *resources = nullptr;
    PlatformInfo *platform = nullptr;
    Translator *translator = nullptr;
    // Optional: null falls back to full coverage (no candidate filtering).
    FontCoverageProvider *fontCoverage = nullptr;
};

// Pointers are borrowed; the host keeps them alive for the process
// lifetime. A missing logger or translator degrades gracefully (the line
// is dropped / the msgid comes back untranslated); resources and platform
// are required before any engine loads.
void setHostServices(const HostServices &services);
const HostServices &hostServices();

// Translation through the installed Translator; the msgid unchanged when
// none is installed. Free function so call sites keep the shape they had
// against the addon-side helper.
std::string translated(const char *text);

} // namespace MacishType
