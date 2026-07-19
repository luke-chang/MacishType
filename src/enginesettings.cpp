#include "enginesettings.h"

#include <climits>
#include <cmath>
#include <cstdlib>
#include <set>

#include "i18n.h"
#include "log.h"

namespace macishtype {

namespace {

using ToggleOption =
    fcitx::Option<bool, fcitx::NoConstrain<bool>,
                  fcitx::DefaultMarshaller<bool>, FieldAnnotation>;
using TextOption =
    fcitx::Option<std::string, fcitx::NoConstrain<std::string>,
                  fcitx::DefaultMarshaller<std::string>, FieldAnnotation>;
using NumberOption =
    fcitx::Option<int, fcitx::IntConstrain, fcitx::DefaultMarshaller<int>,
                  FieldAnnotation>;
using PickerOption = TextOption;

std::string jsonEscape(const std::string &text) {
    std::string escaped;
    escaped.reserve(text.size());
    for (char ch : text) {
        switch (ch) {
        case '"':
            escaped += "\\\"";
            break;
        case '\\':
            escaped += "\\\\";
            break;
        case '\n':
            escaped += "\\n";
            break;
        case '\t':
            escaped += "\\t";
            break;
        case '\r':
            escaped += "\\r";
            break;
        default:
            if (static_cast<unsigned char>(ch) < 0x20) {
                char buffer[8];
                std::snprintf(buffer, sizeof(buffer), "\\u%04x", ch);
                escaped += buffer;
            } else {
                escaped += ch;
            }
        }
    }
    return escaped;
}

std::optional<bool> boolFromJson(const std::string &json) {
    if (json == "true") {
        return true;
    }
    if (json == "false") {
        return false;
    }
    return std::nullopt;
}

std::optional<double> numberFromJson(const std::string &json) {
    if (json.empty()) {
        return std::nullopt;
    }
    char *end = nullptr;
    double value = std::strtod(json.c_str(), &end);
    if (end != json.c_str() + json.size()) {
        return std::nullopt;
    }
    return value;
}

// Decodes a JSON string literal. JSON.stringify emits raw UTF-8, so
// escapes are limited to the short forms and \uXXXX (with surrogate
// pairs for the astral planes).
std::optional<std::string> stringFromJson(const std::string &json) {
    if (json.size() < 2 || json.front() != '"' || json.back() != '"') {
        return std::nullopt;
    }
    std::string decoded;
    decoded.reserve(json.size() - 2);
    auto appendCodepoint = [&](uint32_t codepoint) {
        if (codepoint < 0x80) {
            decoded += static_cast<char>(codepoint);
        } else if (codepoint < 0x800) {
            decoded += static_cast<char>(0xc0 | (codepoint >> 6));
            decoded += static_cast<char>(0x80 | (codepoint & 0x3f));
        } else if (codepoint < 0x10000) {
            decoded += static_cast<char>(0xe0 | (codepoint >> 12));
            decoded += static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f));
            decoded += static_cast<char>(0x80 | (codepoint & 0x3f));
        } else {
            decoded += static_cast<char>(0xf0 | (codepoint >> 18));
            decoded += static_cast<char>(0x80 | ((codepoint >> 12) & 0x3f));
            decoded += static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f));
            decoded += static_cast<char>(0x80 | (codepoint & 0x3f));
        }
    };
    auto hex4 = [&](size_t index) -> std::optional<uint32_t> {
        if (index + 4 > json.size() - 1) {
            return std::nullopt;
        }
        uint32_t value = 0;
        for (size_t i = index; i < index + 4; i++) {
            char digit = json[i];
            value <<= 4;
            if (digit >= '0' && digit <= '9') {
                value |= digit - '0';
            } else if (digit >= 'a' && digit <= 'f') {
                value |= digit - 'a' + 10;
            } else if (digit >= 'A' && digit <= 'F') {
                value |= digit - 'A' + 10;
            } else {
                return std::nullopt;
            }
        }
        return value;
    };
    for (size_t i = 1; i + 1 < json.size(); i++) {
        char ch = json[i];
        if (ch != '\\') {
            decoded += ch;
            continue;
        }
        if (i + 2 >= json.size()) {
            return std::nullopt;
        }
        char escape = json[++i];
        switch (escape) {
        case '"':
        case '\\':
        case '/':
            decoded += escape;
            break;
        case 'n':
            decoded += '\n';
            break;
        case 't':
            decoded += '\t';
            break;
        case 'r':
            decoded += '\r';
            break;
        case 'b':
            decoded += '\b';
            break;
        case 'f':
            decoded += '\f';
            break;
        case 'u': {
            auto high = hex4(i + 1);
            if (!high) {
                return std::nullopt;
            }
            i += 4;
            uint32_t codepoint = *high;
            if (codepoint >= 0xd800 && codepoint <= 0xdbff &&
                i + 2 < json.size() && json[i + 1] == '\\' &&
                json[i + 2] == 'u') {
                auto low = hex4(i + 3);
                if (low && *low >= 0xdc00 && *low <= 0xdfff) {
                    codepoint = 0x10000 + ((codepoint - 0xd800) << 10) +
                                (*low - 0xdc00);
                    i += 6;
                }
            }
            appendCodepoint(codepoint);
            break;
        }
        default:
            return std::nullopt;
        }
    }
    return decoded;
}

bool isIntegral(double value) {
    return std::floor(value) == value && value >= INT_MIN && value <= INT_MAX;
}

std::string replaceFirst(std::string text, const std::string &value) {
    auto position = text.find("%1");
    if (position != std::string::npos) {
        text.replace(position, 2, value);
    }
    return text;
}

// The token the picker starts on: an explicit default (tag string or
// option index), else the first option.
std::string pickerDefaultToken(const SettingsField &field) {
    if (!field.defaultJson.empty()) {
        if (auto index = numberFromJson(field.defaultJson);
            index && isIntegral(*index) && *index >= 0 &&
            static_cast<size_t>(*index) < field.options.size()) {
            return field.options[static_cast<size_t>(*index)].token;
        }
        if (auto tag = stringFromJson(field.defaultJson)) {
            for (const auto &option : field.options) {
                if (option.token == *tag) {
                    return option.token;
                }
            }
            MACISHTYPE_WARN() << "Settings field " << field.key
                              << ": default matches no option, using the "
                                 "first";
        }
    }
    return field.options.front().token;
}

} // namespace

void FieldAnnotation::dumpDescription(fcitx::RawConfig &config) const {
    if (!tooltip.empty()) {
        config.setValueByPath("Tooltip", tooltip);
    }
    if (!enumTokens.empty()) {
        config.setValueByPath("IsEnum", "True");
        for (size_t i = 0; i < enumTokens.size(); i++) {
            config.setValueByPath("Enum/" + std::to_string(i),
                                  enumTokens[i]);
        }
        for (size_t i = 0; i < enumLabels.size(); i++) {
            config.setValueByPath("EnumI18n/" + std::to_string(i),
                                  enumLabels[i]);
        }
    }
}

EngineSettings::EngineSettings(
    const std::vector<SettingsSection> &sections) {
    std::set<std::string> usedKeys;
    for (const auto &section : sections) {
        for (const auto &field : section.fields) {
            // '/' is reserved by fcitx option paths; duplicates would
            // throw in addOption.
            if (field.key.empty() ||
                field.key.find('/') != std::string::npos ||
                !usedKeys.insert(field.key).second) {
                MACISHTYPE_WARN()
                    << "Settings field skipped (invalid or duplicate key): "
                    << field.key;
                continue;
            }
            materializeField(field);
        }
    }
}

void EngineSettings::materializeField(const SettingsField &field) {
    BoundField bound;
    bound.schema = field;

    FieldAnnotation annotation;
    annotation.tooltip = field.description;
    auto appendTooltipLine = [&](const std::string &text) {
        if (text.empty()) {
            return;
        }
        if (!annotation.tooltip.empty()) {
            annotation.tooltip += "\n";
        }
        annotation.tooltip += text;
    };
    if (!field.placeholder.empty()) {
        appendTooltipLine(
            replaceFirst(translated("Placeholder: %1"), field.placeholder));
    }
    appendTooltipLine(field.disabledWhenText);
    appendTooltipLine(field.hiddenWhenText);

    const std::string &label = field.label.empty() ? field.key : field.label;

    if (field.type == "system") {
        // No system feature is backed on this host yet (associated-mode
        // dictionaries are not implemented), so the field counts as never
        // declared: no option, and no value pushed — mirroring macOS
        // availability gating.
        bound.kind = Kind::Gated;
        MACISHTYPE_DEBUG() << "System settings field gated off: "
                           << field.key;
    } else if (field.type == "toggle") {
        auto option = std::make_unique<ToggleOption>(
            this, field.key, label,
            boolFromJson(field.defaultJson).value_or(false),
            fcitx::NoConstrain<bool>{}, fcitx::DefaultMarshaller<bool>{},
            annotation);
        bound.kind = Kind::Toggle;
        bound.option = option.get();
        options_.push_back(std::move(option));
    } else if (field.type == "textField") {
        auto option = std::make_unique<TextOption>(
            this, field.key, label,
            stringFromJson(field.defaultJson).value_or(""),
            fcitx::NoConstrain<std::string>{},
            fcitx::DefaultMarshaller<std::string>{}, annotation);
        bound.kind = Kind::Text;
        bound.option = option.get();
        options_.push_back(std::move(option));
    } else if (field.type == "number") {
        // On macOS the control is a stepper, so the reachable values are
        // default + n*step: all integers exactly when default and step
        // are. Fractional fields cannot render equivalently here (fcitx
        // has no double option) and stay hidden.
        auto defaultValue = numberFromJson(field.defaultJson);
        double step = field.step.value_or(1.0);
        if (defaultValue && isIntegral(*defaultValue) && isIntegral(step)) {
            int low = field.min ? static_cast<int>(std::ceil(*field.min))
                                : INT_MIN;
            int high = field.max ? static_cast<int>(std::floor(*field.max))
                                 : INT_MAX;
            auto option = std::make_unique<NumberOption>(
                this, field.key, label, static_cast<int>(*defaultValue),
                fcitx::IntConstrain(low, high),
                fcitx::DefaultMarshaller<int>{}, annotation);
            bound.kind = Kind::Number;
            bound.option = option.get();
            options_.push_back(std::move(option));
        } else {
            MACISHTYPE_WARN() << "Fractional number field hidden: "
                              << field.key;
        }
    } else if (field.type == "picker") {
        if (field.options.empty()) {
            MACISHTYPE_WARN() << "Picker without options hidden: "
                              << field.key;
        } else {
            for (const auto &choice : field.options) {
                annotation.enumTokens.push_back(choice.token);
                annotation.enumLabels.push_back(choice.label);
            }
            auto option = std::make_unique<PickerOption>(
                this, field.key, label, pickerDefaultToken(field),
                fcitx::NoConstrain<std::string>{},
                fcitx::DefaultMarshaller<std::string>{}, annotation);
            bound.kind = Kind::Picker;
            bound.option = option.get();
            options_.push_back(std::move(option));
        }
    } else {
        // multiSelect has no equivalent widget; unknown types are future
        // schema. Either way the manifest default still reaches the
        // engine.
        MACISHTYPE_WARN() << "Unsupported settings field type '"
                          << field.type << "' hidden: " << field.key;
    }
    fields_.push_back(std::move(bound));
}

std::string EngineSettings::valuesToJson() const {
    std::string json = "{";
    bool first = true;
    auto append = [&](const std::string &key, const std::string &valueJson) {
        if (valueJson.empty()) {
            return;
        }
        if (!first) {
            json += ",";
        }
        first = false;
        json += "\"" + jsonEscape(key) + "\":" + valueJson;
    };

    for (const auto &bound : fields_) {
        switch (bound.kind) {
        case Kind::Gated:
            break;
        case Kind::HiddenDefault:
            append(bound.schema.key, bound.schema.defaultJson);
            break;
        case Kind::Toggle:
            append(bound.schema.key,
                   static_cast<const ToggleOption *>(bound.option)->value()
                       ? "true"
                       : "false");
            break;
        case Kind::Text:
            append(bound.schema.key,
                   "\"" +
                       jsonEscape(static_cast<const TextOption *>(
                                      bound.option)
                                      ->value()) +
                       "\"");
            break;
        case Kind::Number:
            append(bound.schema.key,
                   std::to_string(static_cast<const NumberOption *>(
                                      bound.option)
                                      ->value()));
            break;
        case Kind::Picker: {
            const std::string &token =
                static_cast<const PickerOption *>(bound.option)->value();
            const SettingsFieldOption *chosen = nullptr;
            for (const auto &choice : bound.schema.options) {
                if (choice.token == token) {
                    chosen = &choice;
                    break;
                }
            }
            if (chosen == nullptr) {
                // A stale token (hand-edited ini); fall back to the
                // schema default.
                std::string defaultToken = pickerDefaultToken(bound.schema);
                for (const auto &choice : bound.schema.options) {
                    if (choice.token == defaultToken) {
                        chosen = &choice;
                        break;
                    }
                }
            }
            if (chosen != nullptr) {
                append(bound.schema.key, chosen->valueJson);
            }
            break;
        }
        }
    }
    json += "}";
    return json;
}

} // namespace macishtype
