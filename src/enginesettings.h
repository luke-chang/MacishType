#pragma once

#include <memory>
#include <string>
#include <vector>

#include <fcitx-config/configuration.h>
#include <fcitx-config/option.h>
#include <fcitx-config/rawconfig.h>

#include "jshost/manifest.h"

namespace macishtype {

// Extra description keys configtool reads beyond type/default: a hover
// tooltip, and for pickers the runtime enum entries — the documented
// EnumAnnotation contract for values only known at runtime.
struct FieldAnnotation {
    std::string tooltip;
    std::vector<std::string> enumTokens;
    std::vector<std::string> enumLabels;

    bool skipDescription() const { return false; }
    bool skipSave() const { return false; }
    void dumpDescription(fcitx::RawConfig &config) const;
};

// fcitx configuration composed at runtime from a manifest settings
// schema. Only fields whose behavior can match the macOS host materialize
// as options ("render means equivalent"); unsupported fields keep their
// manifest default in the pushed values, and gated system fields are
// omitted entirely, mirroring macOS availability gating.
class EngineSettings : public fcitx::Configuration {
public:
    // `associatedAvailable` reports whether an associated-mode dictionary
    // is bundled for the engine's language; only then is the
    // enableAssociatedMode system field surfaced (macOS availability gating).
    EngineSettings(const std::vector<SettingsSection> &sections,
                   bool associatedAvailable);

    const char *typeName() const override { return "EngineSettings"; }

    // At least one option materialized → the input method entry is
    // configurable.
    bool hasOptions() const { return !options_.empty(); }

    // JSON object for the JS settings push: every non-gated schema field,
    // pickers resolved token→value.
    std::string valuesToJson() const;

    // Current value of the enableAssociatedMode toggle (false when the
    // field is absent or gated); the addon feeds it to the host.
    bool associatedModeEnabled() const;

private:
    enum class Kind { Toggle, Text, Number, Picker, HiddenDefault, Gated };
    struct BoundField {
        SettingsField schema;
        Kind kind = Kind::HiddenDefault;
        fcitx::OptionBase *option = nullptr;
    };

    void materializeField(const SettingsField &field);

    bool associatedAvailable_ = false;
    std::vector<BoundField> fields_;
    // Configuration keeps raw pointers to its options; they are owned
    // here and destroyed with this object (members before base).
    std::vector<std::unique_ptr<fcitx::OptionBase>> options_;
};

} // namespace macishtype
