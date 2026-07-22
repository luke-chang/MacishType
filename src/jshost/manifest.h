#pragma once

#include <filesystem>
#include <optional>
#include <string>
#include <vector>

namespace macishtype {

// One choice of a picker field. `token` identifies the option in host
// storage and in the configtool enum: the manifest tag when declared, else
// a plain string value, else the plain text literal, else the value's
// canonical JSON. `valueJson` is what the engine receives when chosen.
struct SettingsFieldOption {
    std::string token;
    std::string label;
    std::string valueJson;
};

// One manifest settings field, labels already locale-resolved. Numeric
// properties stay raw doubles; integrality checks and rounding are the
// consumer's concern.
struct SettingsField {
    std::string key;
    std::string type;
    std::string label;
    std::string description;
    std::string placeholder;
    std::string defaultJson;
    // Human-readable renderings of disabledWhen/hiddenWhen (the conditions
    // are not evaluated on this host; these feed the option tooltip).
    std::string disabledWhenText;
    std::string hiddenWhenText;
    std::vector<SettingsFieldOption> options;
    std::optional<double> min;
    std::optional<double> max;
    std::optional<double> step;
};

struct SettingsSection {
    std::string title;
    std::vector<SettingsField> fields;
};

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
    // Full manifest settings schema; drives the per-IM configuration UI
    // and the values pushed to the engine.
    std::vector<SettingsSection> settingsSections;
    // Module names enabled via the manifest `modules` object.
    std::vector<std::string> enabledModules;
    // Raw JSON object of manifest `candidateWindow`; empty when absent.
    std::string candidateWindowJson;
    // Whether `candidateWindow.layoutDirection` is declared. When it is not,
    // the addon auto-generates a per-input-method orientation setting (macOS
    // parity), so the user picks the candidate direction.
    bool candidateWindowHasLayoutDirection = false;
    // Keys of manifest `menu` items (dividers carry no key).
    std::vector<std::string> menuKeys;
    // Whether manifest `capabilities.fullwidthInput` is declared. Host-only
    // (not exposed on the JS `manifest`); on fcitx5 it puts fcitx's full-width
    // toggle in the engine's status area — the portable stand-in for macOS's
    // Option+key full-width trigger.
    bool fullwidthInput = false;
    // Tri-state manifest `capabilities.outputToSimplified`: true force-
    // enables, false force-disables, nullopt (absent or malformed) falls
    // back to the language gate. Host-only; the addon resolves availability
    // against what chttrans can actually deliver.
    std::optional<bool> outputToSimplified;
};

// Parses and validates manifest.json using a throwaway QuickJS context.
// `languages` are BCP 47 preferences used to resolve localized names.
std::optional<ManifestData>
parseManifest(const std::filesystem::path &manifestPath,
              const std::vector<std::string> &languages);

// BCP 47 preferences from LANGUAGE / LC_ALL / LC_MESSAGES / LANG.
std::vector<std::string> preferredLanguages();

} // namespace macishtype
