#pragma once

#include <filesystem>
#include <optional>
#include <string>
#include <vector>

namespace macishtype {

// The subset of manifest.json the C++ side needs. The JS host re-parses the
// raw JSON in the engine's own context for everything bridge-visible.
struct ManifestData {
    // Entry module path relative to the engine folder. Required by the
    // contract (macOS rejects a manifest without it); parseManifest fails
    // when it is missing, so it is never empty here.
    std::string entry;
    // Locale-resolved manifest name; empty when the manifest omits it.
    std::string displayName;
    // Optional short panel text from manifest `label`; empty means derive
    // one from the display name.
    std::string label;
    // Optional panel icon base name (extensionless, relative to the
    // engine folder) from manifest `icon`; empty means the default base
    // "icon". Hosts append platform-appropriate suffixes.
    std::string icon;
    // Raw manifest intendedLanguage (BCP 47, e.g. zh-Hant); keys the
    // per-language module data files.
    std::string intendedLanguage;
    // Fcitx-style language code derived from intendedLanguage (e.g. zh_TW).
    std::string languageCode;
    // JSON object mapping settings field keys to their manifest defaults.
    std::string settingsDefaultsJson = "{}";
    // Module names enabled via the manifest `modules` object.
    std::vector<std::string> enabledModules;
    // Raw JSON object of manifest `candidateWindow`; empty when absent.
    std::string candidateWindowJson;
    // Keys of manifest `menu` items (dividers carry no key).
    std::vector<std::string> menuKeys;
};

// Parses and validates manifest.json using a throwaway QuickJS context.
// `languages` are BCP 47 preferences used to resolve localized names.
std::optional<ManifestData>
parseManifest(const std::filesystem::path &manifestPath,
              const std::vector<std::string> &languages);

// BCP 47 preferences from LANGUAGE / LC_ALL / LC_MESSAGES / LANG.
std::vector<std::string> preferredLanguages();

} // namespace macishtype
