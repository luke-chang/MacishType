#include "manifest.h"

#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <sstream>

#include <quickjs.h>

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

            qjs::Value intendedLanguage(
                ctx, JS_GetPropertyStr(ctx, root.get(), "intendedLanguage"));
            if (JS_IsString(intendedLanguage.get())) {
                data.intendedLanguage =
                    qjs::toString(ctx, intendedLanguage.get());
                data.languageCode = fcitxLanguageCode(data.intendedLanguage);
            }

            // settings: [{fields: [{key, default}, ...]}, ...] → {key: default}
            qjs::Value defaults(ctx, JS_NewObject(ctx));
            qjs::Value settings(
                ctx, JS_GetPropertyStr(ctx, root.get(), "settings"));
            if (JS_IsArray(settings.get())) {
                qjs::Value sectionCount(
                    ctx, JS_GetPropertyStr(ctx, settings.get(), "length"));
                uint32_t sections = 0;
                JS_ToUint32(ctx, &sections, sectionCount.get());
                for (uint32_t si = 0; si < sections; si++) {
                    qjs::Value section(
                        ctx, JS_GetPropertyUint32(ctx, settings.get(), si));
                    qjs::Value fields(
                        ctx,
                        JS_GetPropertyStr(ctx, section.get(), "fields"));
                    if (!JS_IsArray(fields.get())) {
                        continue;
                    }
                    qjs::Value fieldCount(
                        ctx, JS_GetPropertyStr(ctx, fields.get(), "length"));
                    uint32_t fieldTotal = 0;
                    JS_ToUint32(ctx, &fieldTotal, fieldCount.get());
                    for (uint32_t fi = 0; fi < fieldTotal; fi++) {
                        qjs::Value field(
                            ctx,
                            JS_GetPropertyUint32(ctx, fields.get(), fi));
                        qjs::Value key(
                            ctx, JS_GetPropertyStr(ctx, field.get(), "key"));
                        if (!JS_IsString(key.get())) {
                            continue;
                        }
                        qjs::Value defaultValue(
                            ctx,
                            JS_GetPropertyStr(ctx, field.get(), "default"));
                        if (defaultValue.isUndefined()) {
                            continue;
                        }
                        std::string keyText = qjs::toString(ctx, key.get());
                        JS_SetPropertyStr(ctx, defaults.get(),
                                          keyText.c_str(),
                                          defaultValue.release());
                    }
                }
            }
            qjs::Value defaultsJson(
                ctx, JS_JSONStringify(ctx, defaults.get(), JS_UNDEFINED,
                                      JS_UNDEFINED));
            if (JS_IsString(defaultsJson.get())) {
                data.settingsDefaultsJson =
                    qjs::toString(ctx, defaultsJson.get());
            }

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
