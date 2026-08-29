#include "MacishType/Manifest.h"

#include <algorithm>
#include <fstream>
#include <sstream>

#include <quickjs.h>

#include "MacishType/Log.h"
#include "MacishType/HostSeams.h"
#include "MacishType/QjsUtil.h"

namespace MacishType {

namespace {

// Owns a throwaway QuickJS runtime+context for manifest parsing and frees both
// on any exit, including a C++ exception unwinding out of the parse (building
// the parsed data can drive std::bad_alloc on a hostile/oversized manifest).
struct ScopedRuntime {
    JSRuntime *runtime = JS_NewRuntime();
    JSContext *context = JS_NewContext(runtime);
    ScopedRuntime() = default;
    ScopedRuntime(const ScopedRuntime &) = delete;
    ScopedRuntime &operator=(const ScopedRuntime &) = delete;
    ~ScopedRuntime() {
        JS_FreeContext(context);
        JS_FreeRuntime(runtime);
    }
};

std::optional<std::string> readFile(const std::filesystem::path &path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) {
        return std::nullopt;
    }
    std::ostringstream buffer;
    buffer << stream.rdbuf();
    return buffer.str();
}

std::string lowered(std::string text) {
    std::transform(text.begin(), text.end(), text.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return text;
}

// Script aliases so a zh-TW preference can pick a zh-Hant manifest name and
// vice versa.
std::vector<std::string> lookupKeysForLanguage(const std::string &language) {
    std::vector<std::string> keys{language};
    std::string lower = lowered(language);
    if (lower == "zh-tw" || lower == "zh-hk" || lower == "zh-mo" ||
        lower.rfind("zh-hant", 0) == 0) {
        keys.push_back("zh-Hant");
        keys.push_back("zh-TW");
    } else if (lower == "zh-cn" || lower == "zh-sg" ||
               lower.rfind("zh-hans", 0) == 0) {
        keys.push_back("zh-Hans");
        keys.push_back("zh-CN");
    }
    auto dash = language.find('-');
    if (dash != std::string::npos) {
        keys.push_back(language.substr(0, dash));
    }
    return keys;
}

std::string resolveLocalizedName(JSContext *ctx, JSValueConst nameValue,
                                 const std::vector<std::string> &languages) {
    if (JS_IsString(nameValue)) {
        return Qjs::toString(ctx, nameValue);
    }
    if (!JS_IsObject(nameValue)) {
        return {};
    }
    auto tryKey = [&](const std::string &key) -> std::optional<std::string> {
        Qjs::Value value(ctx,
                         JS_GetPropertyStr(ctx, nameValue, key.c_str()));
        if (JS_IsString(value.get())) {
            return Qjs::toString(ctx, value.get());
        }
        return std::nullopt;
    };
    for (const auto &language : languages) {
        for (const auto &key : lookupKeysForLanguage(language)) {
            if (auto name = tryKey(key)) {
                return *name;
            }
        }
    }
    if (auto name = tryKey("en")) {
        return *name;
    }
    // Fall back to the lowest-sorted declared localization (deterministic,
    // independent of declaration order).
    JSPropertyEnum *properties = nullptr;
    uint32_t count = 0;
    std::string result;
    if (JS_GetOwnPropertyNames(ctx, &properties, &count, nameValue,
                               JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY) == 0) {
        std::optional<std::string> lowestKey;
        for (uint32_t i = 0; i < count; i++) {
            const char *key = JS_AtomToCString(ctx, properties[i].atom);
            if (key != nullptr) {
                if (!lowestKey || std::string(key) < *lowestKey) {
                    lowestKey = key;
                }
                JS_FreeCString(ctx, key);
            }
        }
        if (lowestKey) {
            if (auto name = tryKey(*lowestKey)) {
                result = *name;
            }
        }
        JS_FreePropertyEnum(ctx, properties, count);
    }
    return result;
}

// PickerOption: a shorthand string, or {text, value?, tag?}. The token
// identity chain (tag → plain string value → plain text literal → value
// JSON) gives every usable option a stable storage identifier.
std::optional<SettingsFieldOption>
parseSettingsOption(JSContext *ctx, JSValueConst optionValue,
                    const std::vector<std::string> &languages) {
    SettingsFieldOption option;
    if (JS_IsString(optionValue)) {
        std::string text = Qjs::toString(ctx, optionValue);
        option.token = text;
        option.label = text;
        option.valueJson = Qjs::jsonStringify(ctx, optionValue);
        return option;
    }
    if (!JS_IsObject(optionValue)) {
        return std::nullopt;
    }
    Qjs::Value text(ctx, JS_GetPropertyStr(ctx, optionValue, "text"));
    option.label = resolveLocalizedName(ctx, text.get(), languages);
    const bool plainText = JS_IsString(text.get());

    Qjs::Value value(ctx, JS_GetPropertyStr(ctx, optionValue, "value"));
    if (!JS_IsUndefined(value.get())) {
        option.valueJson = Qjs::jsonStringify(ctx, value.get());
    } else if (plainText) {
        // Value defaults to the text literal.
        option.valueJson = Qjs::jsonStringify(ctx, text.get());
    }

    Qjs::Value tag(ctx, JS_GetPropertyStr(ctx, optionValue, "tag"));
    if (JS_IsString(tag.get())) {
        option.token = Qjs::toString(ctx, tag.get());
    } else if (JS_IsString(value.get())) {
        option.token = Qjs::toString(ctx, value.get());
    } else if (plainText) {
        option.token = Qjs::toString(ctx, text.get());
    } else {
        option.token = option.valueJson;
    }
    if (option.label.empty()) {
        option.label = option.token;
    }
    if (option.valueJson.empty() || option.token.empty()) {
        return std::nullopt;
    }
    return option;
}

std::string replaceFirst(std::string text, const char *placeholder,
                         const std::string &value) {
    auto position = text.find(placeholder);
    if (position != std::string::npos) {
        text.replace(position, 2, value);
    }
    return text;
}

const SettingsField *findField(const std::vector<SettingsSection> &sections,
                               const std::string &key) {
    for (const auto &section : sections) {
        for (const auto &field : section.fields) {
            if (field.key == key) {
                return &field;
            }
        }
    }
    return nullptr;
}

// Display text for a condition's comparison value: the option label when
// the referenced field is a picker, else the bare string / JSON literal.
std::string conditionValueText(JSContext *ctx, JSValueConst value,
                               const SettingsField *target) {
    std::string json = Qjs::jsonStringify(ctx, value);
    if (target != nullptr) {
        for (const auto &option : target->options) {
            if (option.valueJson == json || option.token == json) {
                return option.label;
            }
            // Tag references arrive as plain strings.
            if (json.size() >= 2 && json.front() == '"' &&
                option.token == json.substr(1, json.size() - 2)) {
                return option.label;
            }
        }
    }
    if (json.size() >= 2 && json.front() == '"' && json.back() == '"' &&
        json.find('\\') == std::string::npos) {
        return json.substr(1, json.size() - 2);
    }
    return json;
}

// Renders a disabledWhen/hiddenWhen condition as a sentence fragment. The
// host never evaluates conditions (the config dialog is a static form);
// the text keeps the rule visible to the user via the option tooltip.
std::string conditionToText(JSContext *ctx, JSValueConst condition,
                            const std::vector<SettingsSection> &sections) {
    if (!JS_IsObject(condition)) {
        return {};
    }
    auto joinChildren = [&](JSValueConst array, const std::string &glue) {
        std::string joined;
        Qjs::Value length(ctx, JS_GetPropertyStr(ctx, array, "length"));
        uint32_t count = 0;
        JS_ToUint32(ctx, &count, length.get());
        for (uint32_t i = 0; i < count; i++) {
            Qjs::Value child(ctx, JS_GetPropertyUint32(ctx, array, i));
            std::string text = conditionToText(ctx, child.get(), sections);
            if (text.empty()) {
                continue;
            }
            if (!joined.empty()) {
                joined += glue;
            }
            joined += text;
        }
        return joined;
    };

    // A bare array at the top level is an implicit allOf.
    if (JS_IsArray(condition)) {
        return joinChildren(condition, translated(" and "));
    }
    Qjs::Value allOf(ctx, JS_GetPropertyStr(ctx, condition, "allOf"));
    if (JS_IsArray(allOf.get())) {
        return joinChildren(allOf.get(), translated(" and "));
    }
    Qjs::Value anyOf(ctx, JS_GetPropertyStr(ctx, condition, "anyOf"));
    if (JS_IsArray(anyOf.get())) {
        return joinChildren(anyOf.get(), translated(" or "));
    }
    Qjs::Value negated(ctx, JS_GetPropertyStr(ctx, condition, "not"));
    if (JS_IsObject(negated.get())) {
        return replaceFirst(translated("not (%1)"), "%1",
                            conditionToText(ctx, negated.get(), sections));
    }

    Qjs::Value key(ctx, JS_GetPropertyStr(ctx, condition, "key"));
    if (!JS_IsString(key.get())) {
        return {};
    }
    std::string keyText = Qjs::toString(ctx, key.get());
    const SettingsField *target = findField(sections, keyText);
    std::string label =
        target != nullptr && !target->label.empty() ? target->label : keyText;

    auto relation = [&](const char *name,
                        const std::string &sentence) -> std::string {
        Qjs::Value operand(ctx, JS_GetPropertyStr(ctx, condition, name));
        if (operand.isUndefined()) {
            return {};
        }
        std::string values;
        if (JS_IsArray(operand.get())) {
            Qjs::Value length(
                ctx, JS_GetPropertyStr(ctx, operand.get(), "length"));
            uint32_t count = 0;
            JS_ToUint32(ctx, &count, length.get());
            for (uint32_t i = 0; i < count; i++) {
                Qjs::Value item(ctx,
                                JS_GetPropertyUint32(ctx, operand.get(), i));
                if (!values.empty()) {
                    values += translated(", ");
                }
                values += conditionValueText(ctx, item.get(), target);
            }
        } else {
            values = conditionValueText(ctx, operand.get(), target);
        }
        return replaceFirst(replaceFirst(sentence, "%1", label), "%2",
                            values);
    };

    if (auto text = relation("equals", translated("“%1” is “%2”"));
        !text.empty()) {
        return text;
    }
    if (auto text = relation("notEquals", translated("“%1” is not “%2”"));
        !text.empty()) {
        return text;
    }
    if (auto text = relation("in", translated("“%1” is one of: %2"));
        !text.empty()) {
        return text;
    }
    if (auto text = relation("notIn", translated("“%1” is none of: %2"));
        !text.empty()) {
        return text;
    }
    return {};
}

std::vector<SettingsSection>
parseSettingsSections(JSContext *ctx, JSValueConst settingsValue,
                      const std::vector<std::string> &languages) {
    std::vector<SettingsSection> sections;
    if (!JS_IsArray(settingsValue)) {
        return sections;
    }
    auto arrayLength = [&](JSValueConst array) {
        Qjs::Value length(ctx, JS_GetPropertyStr(ctx, array, "length"));
        uint32_t count = 0;
        JS_ToUint32(ctx, &count, length.get());
        return count;
    };
    auto numberProperty = [&](JSValueConst object,
                              const char *name) -> std::optional<double> {
        Qjs::Value value(ctx, JS_GetPropertyStr(ctx, object, name));
        if (!JS_IsNumber(value.get())) {
            return std::nullopt;
        }
        double number = 0;
        JS_ToFloat64(ctx, &number, value.get());
        return number;
    };

    // Condition sentences reference other fields' labels, so they render
    // in a second pass once the whole schema is assembled.
    struct PendingCondition {
        size_t section;
        size_t field;
        std::string disabledJson;
        std::string hiddenJson;
    };
    std::vector<PendingCondition> pendingConditions;

    uint32_t sectionCount = arrayLength(settingsValue);
    for (uint32_t si = 0; si < sectionCount; si++) {
        Qjs::Value sectionValue(ctx,
                                JS_GetPropertyUint32(ctx, settingsValue, si));
        SettingsSection section;
        Qjs::Value title(ctx,
                         JS_GetPropertyStr(ctx, sectionValue.get(), "title"));
        section.title = resolveLocalizedName(ctx, title.get(), languages);

        Qjs::Value fields(ctx,
                          JS_GetPropertyStr(ctx, sectionValue.get(),
                                            "fields"));
        if (!JS_IsArray(fields.get())) {
            continue;
        }
        uint32_t fieldCount = arrayLength(fields.get());
        for (uint32_t fi = 0; fi < fieldCount; fi++) {
            Qjs::Value fieldValue(
                ctx, JS_GetPropertyUint32(ctx, fields.get(), fi));
            Qjs::Value key(ctx,
                           JS_GetPropertyStr(ctx, fieldValue.get(), "key"));
            Qjs::Value type(ctx,
                            JS_GetPropertyStr(ctx, fieldValue.get(), "type"));
            if (!JS_IsString(key.get()) || !JS_IsString(type.get())) {
                continue;
            }
            SettingsField field;
            field.key = Qjs::toString(ctx, key.get());
            field.type = Qjs::toString(ctx, type.get());

            auto localized = [&](const char *name) {
                Qjs::Value value(
                    ctx, JS_GetPropertyStr(ctx, fieldValue.get(), name));
                return resolveLocalizedName(ctx, value.get(), languages);
            };
            field.label = localized("label");
            field.description = localized("description");
            field.placeholder = localized("placeholder");

            auto rawJson = [&](const char *name) {
                Qjs::Value value(
                    ctx, JS_GetPropertyStr(ctx, fieldValue.get(), name));
                return Qjs::jsonStringify(ctx, value.get());
            };
            field.defaultJson = rawJson("default");
            std::string disabledJson = rawJson("disabledWhen");
            std::string hiddenJson = rawJson("hiddenWhen");
            if (!disabledJson.empty() || !hiddenJson.empty()) {
                pendingConditions.push_back({sections.size(),
                                             section.fields.size(),
                                             std::move(disabledJson),
                                             std::move(hiddenJson)});
            }

            field.min = numberProperty(fieldValue.get(), "min");
            field.max = numberProperty(fieldValue.get(), "max");
            field.step = numberProperty(fieldValue.get(), "step");

            Qjs::Value options(
                ctx, JS_GetPropertyStr(ctx, fieldValue.get(), "options"));
            if (JS_IsArray(options.get())) {
                uint32_t optionCount = arrayLength(options.get());
                for (uint32_t oi = 0; oi < optionCount; oi++) {
                    Qjs::Value optionValue(
                        ctx, JS_GetPropertyUint32(ctx, options.get(), oi));
                    if (auto parsed = parseSettingsOption(
                            ctx, optionValue.get(), languages)) {
                        field.options.push_back(std::move(*parsed));
                    }
                }
            }
            section.fields.push_back(std::move(field));
        }
        sections.push_back(std::move(section));
    }

    for (const auto &pending : pendingConditions) {
        auto &field = sections[pending.section].fields[pending.field];
        auto render = [&](const std::string &json, const char *sentence) {
            Qjs::Value condition(ctx, JS_ParseJSON(ctx, json.c_str(),
                                                   json.size(), "condition"));
            std::string text = conditionToText(ctx, condition.get(), sections);
            return text.empty()
                       ? std::string()
                       : replaceFirst(translated(sentence), "%1", text);
        };
        // One wording for both condition kinds (hidden/disabled): the
        // practical meaning to the user is the same.
        if (!pending.disabledJson.empty()) {
            field.disabledWhenText =
                render(pending.disabledJson, "Has no effect when %1.");
        }
        if (!pending.hiddenJson.empty()) {
            field.hiddenWhenText =
                render(pending.hiddenJson, "Has no effect when %1.");
        }
    }
    return sections;
}

std::string fcitxLanguageCode(const std::string &intendedLanguage) {
    std::string lower = lowered(intendedLanguage);
    if (lower == "zh-hant") {
        return "zh_TW";
    }
    if (lower == "zh-hans") {
        return "zh_CN";
    }
    std::string code = intendedLanguage;
    std::replace(code.begin(), code.end(), '-', '_');
    return code;
}

} // namespace

std::vector<std::string> preferredLanguages() {
    PlatformInfo *platform = hostServices().platform;
    return platform != nullptr ? platform->preferredLanguages()
                               : std::vector<std::string>{};
}

std::optional<ManifestData>
parseManifest(const std::filesystem::path &manifestPath,
              const std::vector<std::string> &languages) {
    auto content = readFile(manifestPath);
    if (!content) {
        MACISHTYPE_NOTICE() << "Cannot read manifest: " << manifestPath;
        return std::nullopt;
    }

    ScopedRuntime scoped;
    JSContext *ctx = scoped.context;
    std::optional<ManifestData> result;

    {
        const std::string manifestPathText = manifestPath.string();
        Qjs::Value root(ctx, JS_ParseJSON(ctx, content->c_str(),
                                          content->size(),
                                          manifestPathText.c_str()));
        if (root.isException()) {
            MACISHTYPE_NOTICE() << "Invalid manifest JSON " << manifestPath
                                << ": " << Qjs::exceptionText(ctx);
        } else if (!JS_IsObject(root.get())) {
            MACISHTYPE_NOTICE() << "Manifest is not a JSON object: "
                                << manifestPath;
        } else {
            ManifestData data;

            Qjs::Value entry(ctx,
                             JS_GetPropertyStr(ctx, root.get(), "entry"));
            if (JS_IsString(entry.get())) {
                data.entry = Qjs::toString(ctx, entry.get());
            }

            Qjs::Value name(ctx, JS_GetPropertyStr(ctx, root.get(), "name"));
            data.displayName = resolveLocalizedName(ctx, name.get(), languages);

            Qjs::Value label(ctx,
                             JS_GetPropertyStr(ctx, root.get(), "label"));
            if (JS_IsString(label.get())) {
                data.label = Qjs::toString(ctx, label.get());
            }

            Qjs::Value icon(ctx, JS_GetPropertyStr(ctx, root.get(), "icon"));
            if (JS_IsString(icon.get())) {
                data.icon = Qjs::toString(ctx, icon.get());
            }

            Qjs::Value intendedLanguage(
                ctx, JS_GetPropertyStr(ctx, root.get(), "intendedLanguage"));
            if (JS_IsString(intendedLanguage.get())) {
                data.intendedLanguage =
                    Qjs::toString(ctx, intendedLanguage.get());
                data.languageCode = fcitxLanguageCode(data.intendedLanguage);
            }

            Qjs::Value settings(
                ctx, JS_GetPropertyStr(ctx, root.get(), "settings"));
            data.settingsSections =
                parseSettingsSections(ctx, settings.get(), languages);

            // modules: {name: true, ...}
            Qjs::Value modules(ctx,
                               JS_GetPropertyStr(ctx, root.get(), "modules"));
            if (JS_IsObject(modules.get())) {
                JSPropertyEnum *properties = nullptr;
                uint32_t count = 0;
                if (JS_GetOwnPropertyNames(ctx, &properties, &count,
                                           modules.get(),
                                           JS_GPN_STRING_MASK |
                                               JS_GPN_ENUM_ONLY) == 0) {
                    for (uint32_t i = 0; i < count; i++) {
                        Qjs::Value enabled(
                            ctx, JS_GetProperty(ctx, modules.get(),
                                                properties[i].atom));
                        if (JS_ToBool(ctx, enabled.get()) != 1) {
                            continue;
                        }
                        const char *moduleName =
                            JS_AtomToCString(ctx, properties[i].atom);
                        if (moduleName != nullptr) {
                            data.enabledModules.emplace_back(moduleName);
                            JS_FreeCString(ctx, moduleName);
                        }
                    }
                    JS_FreePropertyEnum(ctx, properties, count);
                }
            }

            Qjs::Value candidateWindow(
                ctx, JS_GetPropertyStr(ctx, root.get(), "candidateWindow"));
            if (JS_IsObject(candidateWindow.get())) {
                data.candidateWindowJson =
                    Qjs::jsonStringify(ctx, candidateWindow.get());
                Qjs::Value direction(
                    ctx, JS_GetPropertyStr(ctx, candidateWindow.get(),
                                           "layoutDirection"));
                data.candidateWindowHasLayoutDirection =
                    JS_IsString(direction.get());
            }

            // menu: [{key, ...} | divider], collect declared keys
            Qjs::Value menu(ctx, JS_GetPropertyStr(ctx, root.get(), "menu"));
            if (JS_IsArray(menu.get())) {
                Qjs::Value menuCount(
                    ctx, JS_GetPropertyStr(ctx, menu.get(), "length"));
                uint32_t items = 0;
                JS_ToUint32(ctx, &items, menuCount.get());
                for (uint32_t i = 0; i < items; i++) {
                    Qjs::Value item(ctx,
                                    JS_GetPropertyUint32(ctx, menu.get(), i));
                    Qjs::Value key(
                        ctx, JS_GetPropertyStr(ctx, item.get(), "key"));
                    if (JS_IsString(key.get())) {
                        data.menuKeys.push_back(
                            Qjs::toString(ctx, key.get()));
                    }
                }
            }

            // capabilities: {fullwidthInput: true, ...} — host-only behavior
            // flags, not surfaced on the JS `manifest`. A declared non-
            // boolean value is treated as undeclared (spec: back to the
            // default/language gate) and warned about.
            Qjs::Value capabilities(
                ctx, JS_GetPropertyStr(ctx, root.get(), "capabilities"));
            if (JS_IsObject(capabilities.get())) {
                auto capabilityFlag =
                    [&](const char *name) -> std::optional<bool> {
                    Qjs::Value flag(
                        ctx, JS_GetPropertyStr(ctx, capabilities.get(), name));
                    if (JS_IsBool(flag.get())) {
                        return JS_ToBool(ctx, flag.get()) == 1;
                    }
                    if (!JS_IsUndefined(flag.get())) {
                        MACISHTYPE_NOTICE()
                            << "capabilities." << name
                            << " must be a boolean, treated as undeclared: "
                            << manifestPath;
                    }
                    return std::nullopt;
                };
                data.fullwidthInput =
                    capabilityFlag("fullwidthInput").value_or(false);
                data.reverseLookup =
                    capabilityFlag("reverseLookup").value_or(false);
                data.outputToSimplified = capabilityFlag("outputToSimplified");
            }

            if (data.entry.empty()) {
                MACISHTYPE_NOTICE()
                    << "Manifest `entry` must be a non-empty string "
                       "(required): "
                    << manifestPath;
            } else {
                result = std::move(data);
            }
        }
    }

    return result;
}

} // namespace MacishType
