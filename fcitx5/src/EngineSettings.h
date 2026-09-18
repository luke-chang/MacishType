#pragma once

#include <memory>
#include <string>
#include <vector>

#include <fcitx-config/configuration.h>
#include <fcitx-config/option.h>
#include <fcitx-config/rawconfig.h>

#include <MacishType/Manifest.h>

namespace MacishType::Fcitx5 {

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

// Shared with the addon-wide config, which needs the same runtime enum
// entries configtool reads here.
using TextOption =
    fcitx::Option<std::string, fcitx::NoConstrain<std::string>,
                  fcitx::DefaultMarshaller<std::string>, FieldAnnotation>;
using PickerOption = TextOption;

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
    // `layoutDirectionFixed` is true when the manifest declares
    // `candidateWindow.layoutDirection`; only when it does not does the
    // orientation picker materialize (macOS parity).
    EngineSettings(const std::vector<SettingsSection> &sections,
                   bool associatedAvailable, bool layoutDirectionFixed);

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

    // Selected orientation token ("system"/"horizontal"/"vertical"), or empty
    // when the picker is absent (the manifest fixes the direction). "system"
    // means follow the fcitx global; the addon resolves it to a concrete
    // direction before pushing it to the host.
    std::string layoutDirection() const;

private:
    enum class Kind { Toggle, Text, Number, Picker, HiddenDefault, Gated };
    struct BoundField {
        SettingsField schema;
        Kind kind = Kind::HiddenDefault;
        fcitx::OptionBase *option = nullptr;
    };

    void materializeField(const SettingsField &field);
    void materializeOrientation();

    bool associatedAvailable_ = false;
    std::vector<BoundField> fields_;
    // Host-level orientation control (not a manifest setting, so kept out of
    // fields_ and the JS values push); non-null only when materialized.
    fcitx::OptionBase *orientationOption_ = nullptr;
    // Configuration keeps raw pointers to its options; they are owned
    // here and destroyed with this object (members before base).
    std::vector<std::unique_ptr<fcitx::OptionBase>> options_;
};

} // namespace MacishType::Fcitx5
