#include "manifest.h"

#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <sstream>

#include <quickjs.h>

#include "../i18n.h"
#include "../log.h"
#include "qjsutil.h"

namespace macishtype {

namespace {

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
    std::transform(text.begin(), text.end(), text.begin(),
                   [](unsigned char ch) { return std::tolower(ch); });
    return text;
}

// "zh_TW.UTF-8" → "zh-TW"; empty or "C"/"POSIX" → empty.
std::string bcp47FromLocale(const std::string &locale) {
    std::string tag = locale.substr(0, locale.find('.'));
    tag = tag.substr(0, tag.find('@'));
    if (tag.empty() || tag == "C" || tag == "POSIX") {
        return {};
    }
    std::replace(tag.begin(), tag.end(), '_', '-');
    return tag;
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
        return qjs::toString(ctx, nameValue);
    }
    if (!JS_IsObject(nameValue)) {
        return {};
    }
    auto tryKey = [&](const std::string &key) -> std::optional<std::string> {
        qjs::Value value(ctx,
                         JS_GetPropertyStr(ctx, nameValue, key.c_str()));
        if (JS_IsString(value.get())) {
            return qjs::toString(ctx, value.get());
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
    // Fall back to the first declared localization.
    JSPropertyEnum *properties = nullptr;
    uint32_t count = 0;
    std::string result;
    if (JS_GetOwnPropertyNames(ctx, &properties, &count, nameValue,
                               JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY) == 0) {
        if (count > 0) {
            const char *key = JS_AtomToCString(ctx, properties[0].atom);
            if (key != nullptr) {
                if (auto name = tryKey(key)) {
                    result = *name;
                }
                JS_FreeCString(ctx, key);
            }
        }
        JS_FreePropertyEnum(ctx, properties, count);
    }
    return result;
}

// JSON text of a JS value; empty for undefined or stringify failure.
std::string stringifyJson(JSContext *ctx, JSValueConst value) {
    if (JS_IsUndefined(value)) {
        return {};
    }
    qjs::Value json(ctx, JS_JSONStringify(ctx, value, JS_UNDEFINED,
                                          JS_UNDEFINED));
    if (!JS_IsString(json.get())) {
        return {};
    }
    return qjs::toString(ctx, json.get());
}

// PickerOption: a shorthand string, or {text, value?, tag?}. The token
// identity chain (tag → plain string value → plain text literal → value
// JSON) gives every usable option a stable storage identifier.
std::optional<SettingsFieldOption>
parseSettingsOption(JSContext *ctx, JSValueConst optionValue,
                    const std::vector<std::string> &languages) {
    SettingsFieldOption option;
    if (JS_IsString(optionValue)) {
        std::string text = qjs::toString(ctx, optionValue);
        option.token = text;
        option.label = text;
        option.valueJson = stringifyJson(ctx, optionValue);
        return option;
    }
    if (!JS_IsObject(optionValue)) {
        return std::nullopt;
    }
    qjs::Value text(ctx, JS_GetPropertyStr(ctx, optionValue, "text"));
    option.label = resolveLocalizedName(ctx, text.get(), languages);
    const bool plainText = JS_IsString(text.get());

    qjs::Value value(ctx, JS_GetPropertyStr(ctx, optionValue, "value"));
    if (!JS_IsUndefined(value.get())) {
        option.valueJson = stringifyJson(ctx, value.get());
    } else if (plainText) {
        // Value defaults to the text literal.
        option.valueJson = stringifyJson(ctx, text.get());
    }

    qjs::Value tag(ctx, JS_GetPropertyStr(ctx, optionValue, "tag"));
    if (JS_IsString(tag.get())) {
        option.token = qjs::toString(ctx, tag.get());
    } else if (JS_IsString(value.get())) {
        option.token = qjs::toString(ctx, value.get());
    } else if (plainText) {
        option.token = qjs::toString(ctx, text.get());
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
    std::string json = stringifyJson(ctx, value);
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
        qjs::Value length(ctx, JS_GetPropertyStr(ctx, array, "length"));
        uint32_t count = 0;
        JS_ToUint32(ctx, &count, length.get());
        for (uint32_t i = 0; i < count; i++) {
            qjs::Value child(ctx, JS_GetPropertyUint32(ctx, array, i));
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

    qjs::Value allOf(ctx, JS_GetPropertyStr(ctx, condition, "and"));
    if (JS_IsArray(allOf.get())) {
        return joinChildren(allOf.get(), translated(" and "));
    }
    qjs::Value anyOf(ctx, JS_GetPropertyStr(ctx, condition, "or"));
    if (JS_IsArray(anyOf.get())) {
        return joinChildren(anyOf.get(), translated(" or "));
    }
    qjs::Value negated(ctx, JS_GetPropertyStr(ctx, condition, "not"));
    if (JS_IsObject(negated.get())) {
        return replaceFirst(translated("not (%1)"), "%1",
                            conditionToText(ctx, negated.get(), sections));
    }

    qjs::Value key(ctx, JS_GetPropertyStr(ctx, condition, "key"));
    if (!JS_IsString(key.get())) {
        return {};
    }
    std::string keyText = qjs::toString(ctx, key.get());
    const SettingsField *target = findField(sections, keyText);
    std::string label =
        target != nullptr && !target->label.empty() ? target->label : keyText;

    auto relation = [&](const char *name,
                        const std::string &sentence) -> std::string {
        qjs::Value operand(ctx, JS_GetPropertyStr(ctx, condition, name));
        if (operand.isUndefined()) {
            return {};
        }
        std::string values;
        if (JS_IsArray(operand.get())) {
            qjs::Value length(
                ctx, JS_GetPropertyStr(ctx, operand.get(), "length"));
            uint32_t count = 0;
            JS_ToUint32(ctx, &count, length.get());
            for (uint32_t i = 0; i < count; i++) {
                qjs::Value item(ctx,
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
        qjs::Value length(ctx, JS_GetPropertyStr(ctx, array, "length"));
        uint32_t count = 0;
        JS_ToUint32(ctx, &count, length.get());
        return count;
    };
    auto numberProperty = [&](JSValueConst object,
                              const char *name) -> std::optional<double> {
        qjs::Value value(ctx, JS_GetPropertyStr(ctx, object, name));
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
        qjs::Value sectionValue(ctx,
                                JS_GetPropertyUint32(ctx, settingsValue, si));
        SettingsSection section;
        qjs::Value title(ctx,
                         JS_GetPropertyStr(ctx, sectionValue.get(), "title"));
        section.title = resolveLocalizedName(ctx, title.get(), languages);

        qjs::Value fields(ctx,
                          JS_GetPropertyStr(ctx, sectionValue.get(),
                                            "fields"));
        if (!JS_IsArray(fields.get())) {
            continue;
        }
        uint32_t fieldCount = arrayLength(fields.get());
        for (uint32_t fi = 0; fi < fieldCount; fi++) {
            qjs::Value fieldValue(
                ctx, JS_GetPropertyUint32(ctx, fields.get(), fi));
            qjs::Value key(ctx,
                           JS_GetPropertyStr(ctx, fieldValue.get(), "key"));
            qjs::Value type(ctx,
                            JS_GetPropertyStr(ctx, fieldValue.get(), "type"));
            if (!JS_IsString(key.get()) || !JS_IsString(type.get())) {
                continue;
            }
            SettingsField field;
            field.key = qjs::toString(ctx, key.get());
            field.type = qjs::toString(ctx, type.get());

            auto localized = [&](const char *name) {
                qjs::Value value(
                    ctx, JS_GetPropertyStr(ctx, fieldValue.get(), name));
                return resolveLocalizedName(ctx, value.get(), languages);
            };
            field.label = localized("label");
            field.description = localized("description");
            field.placeholder = localized("placeholder");

            auto rawJson = [&](const char *name) {
                qjs::Value value(
                    ctx, JS_GetPropertyStr(ctx, fieldValue.get(), name));
                return stringifyJson(ctx, value.get());
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

            qjs::Value options(
                ctx, JS_GetPropertyStr(ctx, fieldValue.get(), "options"));
            if (JS_IsArray(options.get())) {
                uint32_t optionCount = arrayLength(options.get());
                for (uint32_t oi = 0; oi < optionCount; oi++) {
                    qjs::Value optionValue(
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
            qjs::Value condition(ctx, JS_ParseJSON(ctx, json.c_str(),
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
    std::vector<std::string> languages;
    auto push = [&](const std::string &tag) {
        if (!tag.empty() &&
            std::find(languages.begin(), languages.end(), tag) ==
                languages.end()) {
            languages.push_back(tag);
        }
    };
    if (const char *languageList = std::getenv("LANGUAGE")) {
        std::stringstream stream(languageList);
        std::string item;
        while (std::getline(stream, item, ':')) {
            push(bcp47FromLocale(item));
        }
    }
    for (const char *name : {"LC_ALL", "LC_MESSAGES", "LANG"}) {
        if (const char *value = std::getenv(name)) {
            push(bcp47FromLocale(value));
        }
    }
    return languages;
}

std::optional<ManifestData>
parseManifest(const std::filesystem::path &manifestPath,
              const std::vector<std::string> &languages) {
    auto content = readFile(manifestPath);
    if (!content) {
        MACISHTYPE_WARN() << "Cannot read manifest: " << manifestPath;
        return std::nullopt;
    }

    JSRuntime *runtime = JS_NewRuntime();
    JSContext *ctx = JS_NewContext(runtime);
    std::optional<ManifestData> result;

    {
        qjs::Value root(ctx, JS_ParseJSON(ctx, content->c_str(),
                                          content->size(),
                                          manifestPath.c_str()));
        if (root.isException()) {
            MACISHTYPE_WARN() << "Invalid manifest JSON " << manifestPath
                              << ": " << qjs::exceptionText(ctx);
        } else if (!JS_IsObject(root.get())) {
            MACISHTYPE_WARN() << "Manifest is not a JSON object: "
                              << manifestPath;
        } else {
            ManifestData data;

            qjs::Value entry(ctx,
                             JS_GetPropertyStr(ctx, root.get(), "entry"));
            if (JS_IsString(entry.get())) {
                data.entry = qjs::toString(ctx, entry.get());
            }

            qjs::Value name(ctx, JS_GetPropertyStr(ctx, root.get(), "name"));
            data.displayName = resolveLocalizedName(ctx, name.get(), languages);

            qjs::Value label(ctx,
                             JS_GetPropertyStr(ctx, root.get(), "label"));
            if (JS_IsString(label.get())) {
                data.label = qjs::toString(ctx, label.get());
            }

            qjs::Value icon(ctx, JS_GetPropertyStr(ctx, root.get(), "icon"));
            if (JS_IsString(icon.get())) {
                data.icon = qjs::toString(ctx, icon.get());
            }

            qjs::Value intendedLanguage(
                ctx, JS_GetPropertyStr(ctx, root.get(), "intendedLanguage"));
            if (JS_IsString(intendedLanguage.get())) {
                data.intendedLanguage =
                    qjs::toString(ctx, intendedLanguage.get());
                data.languageCode = fcitxLanguageCode(data.intendedLanguage);
            }

            qjs::Value settings(
                ctx, JS_GetPropertyStr(ctx, root.get(), "settings"));
            data.settingsSections =
                parseSettingsSections(ctx, settings.get(), languages);

            // modules: {name: true, ...}
            qjs::Value modules(ctx,
                               JS_GetPropertyStr(ctx, root.get(), "modules"));
            if (JS_IsObject(modules.get())) {
                JSPropertyEnum *properties = nullptr;
                uint32_t count = 0;
                if (JS_GetOwnPropertyNames(ctx, &properties, &count,
                                           modules.get(),
                                           JS_GPN_STRING_MASK |
                                               JS_GPN_ENUM_ONLY) == 0) {
                    for (uint32_t i = 0; i < count; i++) {
                        qjs::Value enabled(
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

            qjs::Value candidateWindow(
                ctx, JS_GetPropertyStr(ctx, root.get(), "candidateWindow"));
            if (JS_IsObject(candidateWindow.get())) {
                qjs::Value json(
                    ctx, JS_JSONStringify(ctx, candidateWindow.get(),
                                          JS_UNDEFINED, JS_UNDEFINED));
                if (JS_IsString(json.get())) {
                    data.candidateWindowJson = qjs::toString(ctx, json.get());
                }
                qjs::Value direction(
                    ctx, JS_GetPropertyStr(ctx, candidateWindow.get(),
                                           "layoutDirection"));
                data.candidateWindowHasLayoutDirection =
                    JS_IsString(direction.get());
            }

            // menu: [{key, ...} | divider], collect declared keys
            qjs::Value menu(ctx, JS_GetPropertyStr(ctx, root.get(), "menu"));
            if (JS_IsArray(menu.get())) {
                qjs::Value menuCount(
                    ctx, JS_GetPropertyStr(ctx, menu.get(), "length"));
                uint32_t items = 0;
                JS_ToUint32(ctx, &items, menuCount.get());
                for (uint32_t i = 0; i < items; i++) {
                    qjs::Value item(ctx,
                                    JS_GetPropertyUint32(ctx, menu.get(), i));
                    qjs::Value key(
                        ctx, JS_GetPropertyStr(ctx, item.get(), "key"));
                    if (JS_IsString(key.get())) {
                        data.menuKeys.push_back(
                            qjs::toString(ctx, key.get()));
                    }
                }
            }

            // capabilities: {fullwidthInput: true, ...} — host-only behavior
            // flags, not surfaced on the JS `manifest`.
            qjs::Value capabilities(
                ctx, JS_GetPropertyStr(ctx, root.get(), "capabilities"));
            if (JS_IsObject(capabilities.get())) {
                qjs::Value fullwidth(
                    ctx, JS_GetPropertyStr(ctx, capabilities.get(),
                                           "fullwidthInput"));
                data.fullwidthInput = JS_ToBool(ctx, fullwidth.get()) == 1;
            }

            if (data.entry.empty()) {
                MACISHTYPE_WARN()
                    << "Manifest `entry` must be a non-empty string "
                       "(required): "
                    << manifestPath;
            } else {
                result = std::move(data);
            }
        }
    }

    JS_FreeContext(ctx);
    JS_FreeRuntime(runtime);
    return result;
}

} // namespace macishtype
