#include "enginehost.h"

#include <cstring>
#include <fstream>
#include <sstream>

#include <fcitx-utils/standardpaths.h>
#include <fcitx-utils/utf8.h>

#include "../log.h"
#include "qjsutil.h"

namespace macishtype {

namespace {

constexpr std::string_view kEngineUrlPrefix = "engine:///";
constexpr auto kWatchdogTimeout = std::chrono::seconds(3);
constexpr size_t kStorageMaxEncodedKeyBytes = 200;
constexpr size_t kStorageMaxValueBytes = 10 * 1024 * 1024;

enum class FieldType { Boolean, Number, String };

const std::map<std::string, FieldType> &candidateWindowFieldTypes() {
    static const std::map<std::string, FieldType> types = {
        {"layoutDirection", FieldType::String},
        {"fontSize", FieldType::Number},
        {"indexLabels", FieldType::String},
        {"pageSize", FieldType::Number},
        {"widerExpandedColumns", FieldType::Boolean},
        {"moveOnExpand", FieldType::Boolean},
        {"horizontalMaxVisibleRows", FieldType::Number},
        {"verticalMinVisibleRows", FieldType::Number},
        {"expandable", FieldType::Boolean},
        {"handleNavigationKeys", FieldType::Boolean},
        {"handleIndexLabelKeys", FieldType::Boolean},
    };
    return types;
}

std::optional<std::string> readFile(const std::filesystem::path &path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) {
        return std::nullopt;
    }
    std::ostringstream buffer;
    buffer << stream.rdbuf();
    return buffer.str();
}

bool isStorageSafeByte(char ch) {
    return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
           (ch >= '0' && ch <= '9') || ch == '.' || ch == '_' || ch == '-';
}

std::string encodeStorageKey(const std::string &key) {
    static const char hexDigits[] = "0123456789ABCDEF";
    std::string encoded;
    encoded.reserve(key.size());
    for (char ch : key) {
        if (isStorageSafeByte(ch)) {
            encoded.push_back(ch);
        } else {
            auto byte = static_cast<unsigned char>(ch);
            encoded.push_back('%');
            encoded.push_back(hexDigits[byte >> 4]);
            encoded.push_back(hexDigits[byte & 0xf]);
        }
    }
    return encoded;
}

std::optional<std::string> decodeStorageKey(const std::string &encoded) {
    std::string key;
    key.reserve(encoded.size());
    for (size_t i = 0; i < encoded.size(); i++) {
        if (encoded[i] != '%') {
            key.push_back(encoded[i]);
            continue;
        }
        if (i + 2 >= encoded.size()) {
            return std::nullopt;
        }
        auto hexValue = [](char digit) -> int {
            if (digit >= '0' && digit <= '9') {
                return digit - '0';
            }
            if (digit >= 'A' && digit <= 'F') {
                return digit - 'A' + 10;
            }
            return -1;
        };
        int high = hexValue(encoded[i + 1]);
        int low = hexValue(encoded[i + 2]);
        if (high < 0 || low < 0) {
            return std::nullopt;
        }
        key.push_back(static_cast<char>((high << 4) | low));
        i += 2;
    }
    return key;
}

// Textual normalization of "/"-separated segments; rejects escapes above
// the root. Empty result is allowed (caller decides).
std::optional<std::string> normalizeRelativePath(const std::string &path) {
    std::vector<std::string> segments;
    std::stringstream stream(path);
    std::string segment;
    while (std::getline(stream, segment, '/')) {
        if (segment.empty() || segment == ".") {
            continue;
        }
        if (segment == "..") {
            if (segments.empty()) {
                return std::nullopt;
            }
            segments.pop_back();
            continue;
        }
        segments.push_back(segment);
    }
    std::string result;
    for (const auto &part : segments) {
        if (!result.empty()) {
            result += "/";
        }
        result += part;
    }
    return result;
}

} // namespace

// Loading --------------------------------------------------------------

std::unique_ptr<JsEngineHost>
JsEngineHost::load(const std::string &engineId,
                   const std::filesystem::path &engineRoot,
                   const ManifestData &manifest,
                   const std::vector<std::string> &languages) {
    std::unique_ptr<JsEngineHost> host(
        new JsEngineHost(engineId, engineRoot, manifest, languages));
    if (!host->initialize()) {
        return nullptr;
    }
    return host;
}

JsEngineHost::JsEngineHost(std::string engineId,
                           std::filesystem::path engineRoot,
                           ManifestData manifest,
                           std::vector<std::string> languages)
    : engineId_(std::move(engineId)), engineRoot_(std::move(engineRoot)),
      manifest_(std::move(manifest)), languages_(std::move(languages)) {}

JsEngineHost::~JsEngineHost() {
    if (ctx_ != nullptr) {
        for (auto &[id, instance] : instances_) {
            JS_FreeValue(ctx_, instance);
        }
        instances_.clear();
        JS_FreeValue(ctx_, engineClass_);
        JS_FreeContext(ctx_);
    }
    if (runtime_ != nullptr) {
        JS_FreeRuntime(runtime_);
    }
}

bool JsEngineHost::initialize() {
    std::error_code errorCode;
    canonicalRoot_ = std::filesystem::canonical(engineRoot_, errorCode);
    if (errorCode) {
        MACISHTYPE_ERROR() << "Cannot resolve engine root " << engineRoot_
                           << ": " << errorCode.message();
        return false;
    }

    runtime_ = JS_NewRuntime();
    ctx_ = JS_NewContext(runtime_);
    JS_SetContextOpaque(ctx_, this);
    JS_SetInterruptHandler(runtime_, &JsEngineHost::interruptHandler, this);
    JS_SetHostPromiseRejectionTracker(runtime_,
                                      &JsEngineHost::rejectionTracker, this);
    JS_SetModuleLoaderFunc(runtime_, &JsEngineHost::moduleNormalize,
                           &JsEngineHost::moduleLoad, this);

    userAgent_ = std::string("MacishType/") + "0.1.0" +
                 " (Linux; fcitx5-macishtype) quickjs-ng/" + JS_GetVersion();

    // Manifest-declared candidate window fields become the read fallback
    // for the manifest.candidateWindow proxy.
    if (!manifest_.candidateWindowJson.empty()) {
        qjs::Value declared(
            ctx_, JS_ParseJSON(ctx_, manifest_.candidateWindowJson.c_str(),
                               manifest_.candidateWindowJson.size(),
                               "manifest.candidateWindow"));
        if (JS_IsObject(declared.get())) {
            for (const auto &[field, type] : candidateWindowFieldTypes()) {
                FCITX_UNUSED(type);
                qjs::Value value(
                    ctx_,
                    JS_GetPropertyStr(ctx_, declared.get(), field.c_str()));
                if (!value.isUndefined() && !value.isException()) {
                    setCandidateWindowField(field, value.get());
                }
            }
            // Manifest declarations belong to the fallback layer, not the
            // engine-write overlay.
            manifestCandidateWindow_ = std::move(engineCandidateWindow_);
            engineCandidateWindow_.clear();
        }
    }
    for (const auto &key : manifest_.menuKeys) {
        menuValues_.emplace(key, false);
    }

    registerBridgeGlobals();

    const auto &paths = fcitx::StandardPaths::global();
    auto glue = paths.locate(fcitx::StandardPathsType::PkgData,
                             "macishtype/hostglue.js");
    auto runtimeJs = paths.locate(fcitx::StandardPathsType::PkgData,
                                  "macishtype/runtime.js");
    if (glue.empty() || runtimeJs.empty()) {
        MACISHTYPE_ERROR()
            << "Shared runtime scripts not found under <pkgdata>/macishtype "
               "(hostglue.js / runtime.js); is the addon fully installed?";
        return false;
    }
    if (!evaluateScript(glue, "hostglue.js") ||
        !evaluateScript(runtimeJs, "runtime.js")) {
        return false;
    }
    if (!pushSettings() || !injectModules()) {
        return false;
    }
    if (!evaluateEntryModule()) {
        return false;
    }
    MACISHTYPE_INFO() << "Engine loaded: " << engineId_;
    return true;
}

bool JsEngineHost::evaluateScript(const std::filesystem::path &path,
                                  const char *scriptName) {
    auto content = readFile(path);
    if (!content) {
        MACISHTYPE_ERROR() << "Cannot read " << path;
        return false;
    }
    Entry entry(*this);
    qjs::Value result(ctx_, JS_Eval(ctx_, content->c_str(), content->size(),
                                    scriptName, JS_EVAL_TYPE_GLOBAL));
    if (result.isException()) {
        MACISHTYPE_ERROR() << scriptName
                           << " failed: " << qjs::exceptionText(ctx_);
        return false;
    }
    return true;
}

bool JsEngineHost::pushSettings() {
    Entry entry(*this);
    qjs::Value global(ctx_, JS_GetGlobalObject(ctx_));
    qjs::Value setter(
        ctx_, JS_GetPropertyStr(ctx_, global.get(), "__MacishType_setSettings"));
    if (!setter.isFunction()) {
        MACISHTYPE_ERROR() << "runtime.js did not define "
                              "__MacishType_setSettings";
        return false;
    }
    qjs::Value defaults(
        ctx_, JS_ParseJSON(ctx_, manifest_.settingsDefaultsJson.c_str(),
                           manifest_.settingsDefaultsJson.size(),
                           "settings-defaults"));
    if (defaults.isException()) {
        MACISHTYPE_ERROR() << "Invalid settings defaults: "
                           << qjs::exceptionText(ctx_);
        return false;
    }
    JSValue argument = defaults.get();
    qjs::Value result(
        ctx_, JS_Call(ctx_, setter.get(), JS_UNDEFINED, 1, &argument));
    if (result.isException()) {
        MACISHTYPE_ERROR() << "Settings push failed: "
                           << qjs::exceptionText(ctx_);
        return false;
    }
    return true;
}

bool JsEngineHost::injectModules() {
    if (manifest_.enabledModules.empty()) {
        return true;
    }
    Entry entry(*this);
    qjs::Value global(ctx_, JS_GetGlobalObject(ctx_));
    for (const auto &moduleName : manifest_.enabledModules) {
        // TODO: fontCoverage should come from fontconfig; symbolNames from
        // a bundled CLDR table. Modules without a data source inject empty
        // views so they answer with their miss value.
        const char *setterName = moduleName == "fontCoverage"
                                     ? "__MacishType_setCoverageModule"
                                     : "__MacishType_setModuleData";
        qjs::Value setter(
            ctx_, JS_GetPropertyStr(ctx_, global.get(), setterName));
        if (!setter.isFunction()) {
            MACISHTYPE_ERROR() << "runtime.js did not define " << setterName;
            return false;
        }
        qjs::Value result;
        if (moduleName == "fontCoverage") {
            JSValue arguments[2] = {
                JS_NewString(ctx_, moduleName.c_str()),
                JS_NewString(ctx_, ""),
            };
            result = qjs::Value(
                ctx_, JS_Call(ctx_, setter.get(), JS_UNDEFINED, 2, arguments));
            JS_FreeValue(ctx_, arguments[0]);
            JS_FreeValue(ctx_, arguments[1]);
        } else {
            JSValue missValue = moduleName == "wordFrequency"
                                    ? JS_NewInt32(ctx_, 0)
                                    : JS_UNDEFINED;
            JSValue table = JS_NewObject(ctx_);
            if (moduleName == "wordFrequency") {
                loadFrequencyTable(table);
            }
            JSValue arguments[3] = {
                JS_NewString(ctx_, moduleName.c_str()),
                table,
                missValue,
            };
            result = qjs::Value(
                ctx_, JS_Call(ctx_, setter.get(), JS_UNDEFINED, 3, arguments));
            JS_FreeValue(ctx_, arguments[0]);
            JS_FreeValue(ctx_, arguments[1]);
            JS_FreeValue(ctx_, arguments[2]);
        }
        if (result.isException()) {
            MACISHTYPE_ERROR() << "Module injection failed for " << moduleName
                               << ": " << qjs::exceptionText(ctx_);
            return false;
        }
    }
    return true;
}

// Fills `table` from the per-language module data file installed under
// <pkgdata>/macishtype/modules/ ("char<TAB>count" lines, # comments). A
// missing file leaves the table empty, which reads as all-miss.
void JsEngineHost::loadFrequencyTable(JSValue table) {
    if (manifest_.intendedLanguage.empty()) {
        return;
    }
    auto path = fcitx::StandardPaths::global().locate(
        fcitx::StandardPathsType::PkgData,
        "macishtype/modules/wordFrequency." + manifest_.intendedLanguage +
            ".tsv");
    if (path.empty()) {
        MACISHTYPE_INFO() << "No wordFrequency table for "
                          << manifest_.intendedLanguage
                          << "; module answers with 0 (run "
                             "scripts/prepare-data.sh and dev-install.sh)";
        return;
    }
    std::ifstream stream(path, std::ios::binary);
    std::string line;
    size_t count = 0;
    while (std::getline(stream, line)) {
        if (line.empty() || line[0] == '#') {
            continue;
        }
        auto tab = line.find('\t');
        if (tab == std::string::npos) {
            continue;
        }
        std::string character = line.substr(0, tab);
        int64_t frequency = 0;
        try {
            frequency = std::stoll(line.substr(tab + 1));
        } catch (...) {
            continue;
        }
        JS_SetPropertyStr(ctx_, table, character.c_str(),
                          JS_NewInt64(ctx_, frequency));
        count++;
    }
    MACISHTYPE_INFO() << "wordFrequency." << manifest_.intendedLanguage
                      << ": " << count << " entries";
}

bool JsEngineHost::evaluateEntryModule() {
    auto resolved = resolveEnginePath("./" + manifest_.entry);
    if (auto *error = std::get_if<std::string>(&resolved)) {
        MACISHTYPE_ERROR() << "Entry module: " << *error;
        return false;
    }
    auto &entryPath = std::get<ResolvedPath>(resolved);
    auto content = readFile(entryPath.fileSystemPath);
    if (!content) {
        MACISHTYPE_ERROR() << "Cannot read entry module "
                           << entryPath.fileSystemPath;
        return false;
    }

    Entry entry(*this);
    qjs::Value compiled(
        ctx_, JS_Eval(ctx_, content->c_str(), content->size(),
                      entryPath.url.c_str(),
                      JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY));
    if (compiled.isException()) {
        MACISHTYPE_ERROR() << "Entry module compile failed: "
                           << qjs::exceptionText(ctx_);
        return false;
    }
    auto *module =
        static_cast<JSModuleDef *>(JS_VALUE_GET_PTR(compiled.get()));
    qjs::Value meta(ctx_, JS_GetImportMeta(ctx_, module));
    if (JS_IsObject(meta.get())) {
        JS_DefinePropertyValueStr(ctx_, meta.get(), "url",
                                  JS_NewString(ctx_, entryPath.url.c_str()),
                                  JS_PROP_C_W_E);
    }

    qjs::Value evaluation(ctx_, JS_EvalFunction(ctx_, compiled.release()));
    if (evaluation.isException()) {
        MACISHTYPE_ERROR() << "Entry module threw: "
                           << qjs::exceptionText(ctx_);
        return false;
    }
    drainJobs();

    if (JS_IsPromise(evaluation.get())) {
        switch (JS_PromiseState(ctx_, evaluation.get())) {
        case JS_PROMISE_FULFILLED:
            break;
        case JS_PROMISE_REJECTED: {
            qjs::Value reason(ctx_,
                              JS_PromiseResult(ctx_, evaluation.get()));
            MACISHTYPE_ERROR() << "Entry module rejected: "
                               << qjs::toString(ctx_, reason.get());
            return false;
        }
        default:
            MACISHTYPE_ERROR()
                << "Entry module did not settle synchronously; top-level "
                   "await on pending work is unsupported";
            return false;
        }
    }

    qjs::Value moduleNamespace(ctx_, JS_GetModuleNamespace(ctx_, module));
    if (moduleNamespace.isException()) {
        MACISHTYPE_ERROR() << "Cannot access entry module namespace: "
                           << qjs::exceptionText(ctx_);
        return false;
    }
    qjs::Value defaultExport(
        ctx_, JS_GetPropertyStr(ctx_, moduleNamespace.get(), "default"));
    if (!defaultExport.isFunction()) {
        MACISHTYPE_ERROR()
            << "Entry module has no constructible default export";
        return false;
    }
    engineClass_ = defaultExport.release();
    return true;
}

// Instances ------------------------------------------------------------

uint64_t JsEngineHost::createInstance() {
    Entry entry(*this);
    qjs::Value instance(
        ctx_, JS_CallConstructor(ctx_, engineClass_, 0, nullptr));
    if (instance.isException()) {
        MACISHTYPE_ERROR() << "Engine constructor threw: "
                           << qjs::exceptionText(ctx_);
        return 0;
    }
    uint64_t instanceId = nextInstanceId_++;
    instances_.emplace(instanceId, instance.release());
    return instanceId;
}

void JsEngineHost::destroyInstance(uint64_t instanceId) {
    auto found = instances_.find(instanceId);
    if (found == instances_.end()) {
        return;
    }
    JS_FreeValue(ctx_, found->second);
    instances_.erase(found);
}

std::optional<bool> JsEngineHost::invokeHook(uint64_t instanceId,
                                             const char *method,
                                             JSValue argument) {
    qjs::Value argumentGuard(ctx_, argument);
    auto found = instances_.find(instanceId);
    if (found == instances_.end()) {
        return std::nullopt;
    }
    qjs::Value hook(ctx_, JS_GetPropertyStr(ctx_, found->second, method));
    if (!hook.isFunction()) {
        return std::nullopt;
    }
    Entry entry(*this);
    int argc = JS_IsUndefined(argumentGuard.get()) ? 0 : 1;
    JSValue argv = argumentGuard.get();
    qjs::Value result(
        ctx_, JS_Call(ctx_, hook.get(), found->second, argc, &argv));
    if (result.isException()) {
        MACISHTYPE_ERROR() << engineId_ << "." << method
                           << " threw: " << qjs::exceptionText(ctx_);
        return std::nullopt;
    }
    return JS_ToBool(ctx_, result.get()) == 1;
}

std::optional<bool> JsEngineHost::invokeHook(uint64_t instanceId,
                                             const char *method) {
    return invokeHook(instanceId, method, JS_UNDEFINED);
}

bool JsEngineHost::instanceHasHook(uint64_t instanceId, const char *method) {
    auto found = instances_.find(instanceId);
    if (found == instances_.end()) {
        return false;
    }
    qjs::Value hook(ctx_, JS_GetPropertyStr(ctx_, found->second, method));
    return hook.isFunction();
}

// Watchdog, jobs, rejections --------------------------------------------

JsEngineHost::Entry::Entry(JsEngineHost &host) : host_(host) {
    if (host_.callDepth_++ == 0) {
        host_.deadline_ = std::chrono::steady_clock::now() + kWatchdogTimeout;
    }
}

JsEngineHost::Entry::~Entry() {
    if (host_.callDepth_ == 1) {
        host_.drainJobs();
        host_.reportRejections();
    }
    host_.callDepth_--;
}

int JsEngineHost::interruptHandler(JSRuntime *runtime, void *opaque) {
    FCITX_UNUSED(runtime);
    auto *host = static_cast<JsEngineHost *>(opaque);
    if (host->callDepth_ > 0 &&
        std::chrono::steady_clock::now() > host->deadline_) {
        MACISHTYPE_ERROR() << "Watchdog: terminating " << host->engineId_
                           << " after "
                           << kWatchdogTimeout.count() << "s";
        return 1;
    }
    return 0;
}

void JsEngineHost::drainJobs() {
    for (;;) {
        JSContext *jobCtx = nullptr;
        int status = JS_ExecutePendingJob(runtime_, &jobCtx);
        if (status == 0) {
            break;
        }
        if (status < 0 && jobCtx != nullptr) {
            MACISHTYPE_ERROR() << "Microtask threw: "
                               << qjs::exceptionText(jobCtx);
        }
    }
}

void JsEngineHost::rejectionTracker(JSContext *ctx, JSValueConst promise,
                                    JSValueConst reason, bool isHandled,
                                    void *opaque) {
    auto *host = static_cast<JsEngineHost *>(opaque);
    void *key = JS_VALUE_GET_PTR(promise);
    if (isHandled) {
        host->pendingRejections_.erase(key);
        return;
    }
    host->pendingRejections_[key] = qjs::toString(ctx, reason);
}

void JsEngineHost::reportRejections() {
    for (const auto &[key, reason] : pendingRejections_) {
        FCITX_UNUSED(key);
        MACISHTYPE_ERROR() << engineId_
                           << ": unhandled promise rejection: " << reason;
    }
    pendingRejections_.clear();
}

// Path containment -------------------------------------------------------

std::variant<JsEngineHost::ResolvedPath, std::string>
JsEngineHost::resolveEnginePath(const std::string &input) const {
    std::string relative;
    if (input.rfind("./", 0) == 0) {
        relative = input.substr(2);
    } else if (input.rfind(kEngineUrlPrefix, 0) == 0) {
        relative = input.substr(kEngineUrlPrefix.size());
    } else {
        return "unsupported path (want ./relative or engine:///path): " +
               input;
    }
    if (relative.find('?') != std::string::npos ||
        relative.find('#') != std::string::npos) {
        return "query strings and fragments are not allowed: " + input;
    }
    auto normalized = normalizeRelativePath(relative);
    if (!normalized || normalized->empty()) {
        return "path escapes the engine folder: " + input;
    }

    std::error_code errorCode;
    auto fullPath =
        std::filesystem::canonical(canonicalRoot_ / *normalized, errorCode);
    if (errorCode) {
        return "file not found: " + input;
    }
    auto rootWithSlash = canonicalRoot_.string() + "/";
    if (fullPath.string().rfind(rootWithSlash, 0) != 0) {
        return "path escapes the engine folder: " + input;
    }
    if (!std::filesystem::is_regular_file(fullPath, errorCode)) {
        return "not a regular file: " + input;
    }
    return ResolvedPath{fullPath, std::string(kEngineUrlPrefix) + *normalized};
}

char *JsEngineHost::moduleNormalize(JSContext *ctx, const char *baseName,
                                    const char *moduleName, void *opaque) {
    FCITX_UNUSED(opaque);
    std::string name(moduleName);
    if (name.rfind(kEngineUrlPrefix, 0) == 0) {
        return js_strdup(ctx, name.c_str());
    }
    if (name.rfind("./", 0) != 0 && name.rfind("../", 0) != 0) {
        // Bare specifiers have no resolution scheme here; hand back as-is so
        // the loader rejects with a clear error.
        return js_strdup(ctx, name.c_str());
    }
    std::string base(baseName);
    std::string baseDir;
    if (base.rfind(kEngineUrlPrefix, 0) == 0) {
        auto lastSlash = base.rfind('/');
        baseDir = base.substr(kEngineUrlPrefix.size(),
                              lastSlash + 1 - kEngineUrlPrefix.size());
    }
    auto normalized = normalizeRelativePath(baseDir + name);
    if (!normalized || normalized->empty()) {
        // Escapes the engine folder; produce a name the loader rejects.
        return js_strdup(ctx, name.c_str());
    }
    std::string resolved = std::string(kEngineUrlPrefix) + *normalized;
    return js_strdup(ctx, resolved.c_str());
}

JSModuleDef *JsEngineHost::moduleLoad(JSContext *ctx, const char *moduleName,
                                      void *opaque) {
    auto *host = static_cast<JsEngineHost *>(opaque);
    auto resolved = host->resolveEnginePath(moduleName);
    if (auto *error = std::get_if<std::string>(&resolved)) {
        JS_ThrowReferenceError(ctx, "could not load module '%s': %s",
                               moduleName, error->c_str());
        return nullptr;
    }
    auto &modulePath = std::get<ResolvedPath>(resolved);
    auto content = readFile(modulePath.fileSystemPath);
    if (!content) {
        JS_ThrowReferenceError(ctx, "could not read module '%s'", moduleName);
        return nullptr;
    }
    JSValue compiled =
        JS_Eval(ctx, content->c_str(), content->size(),
                modulePath.url.c_str(),
                JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    if (JS_IsException(compiled)) {
        return nullptr;
    }
    auto *module = static_cast<JSModuleDef *>(JS_VALUE_GET_PTR(compiled));
    JSValue meta = JS_GetImportMeta(ctx, module);
    if (JS_IsObject(meta)) {
        JS_DefinePropertyValueStr(ctx, meta, "url",
                                  JS_NewString(ctx, modulePath.url.c_str()),
                                  JS_PROP_C_W_E);
    }
    JS_FreeValue(ctx, meta);
    JS_FreeValue(ctx, compiled);
    return module;
}

// Candidate window / menu stores ----------------------------------------

std::optional<JsEngineHost::FieldValue>
JsEngineHost::candidateWindowField(const std::string &field) const {
    if (auto found = engineCandidateWindow_.find(field);
        found != engineCandidateWindow_.end()) {
        return found->second;
    }
    if (auto found = manifestCandidateWindow_.find(field);
        found != manifestCandidateWindow_.end()) {
        return found->second;
    }
    return std::nullopt;
}

void JsEngineHost::setCandidateWindowField(const std::string &field,
                                           JSValueConst value) {
    const auto &types = candidateWindowFieldTypes();
    auto typeEntry = types.find(field);
    if (typeEntry == types.end()) {
        MACISHTYPE_WARN() << "candidateWindow: unknown field ignored: "
                          << field;
        return;
    }
    switch (typeEntry->second) {
    case FieldType::Boolean:
        if (!JS_IsBool(value)) {
            MACISHTYPE_WARN() << "candidateWindow." << field
                              << ": expected boolean, write ignored";
            return;
        }
        engineCandidateWindow_[field] = JS_ToBool(ctx_, value) == 1;
        return;
    case FieldType::Number: {
        double number = 0;
        if (!JS_IsNumber(value) || JS_ToFloat64(ctx_, &number, value) != 0 ||
            number <= 0) {
            MACISHTYPE_WARN() << "candidateWindow." << field
                              << ": expected positive number, write ignored";
            return;
        }
        engineCandidateWindow_[field] = number;
        return;
    }
    case FieldType::String: {
        if (!JS_IsString(value)) {
            MACISHTYPE_WARN() << "candidateWindow." << field
                              << ": expected string, write ignored";
            return;
        }
        std::string text = qjs::toString(ctx_, value);
        if (field == "layoutDirection" && text != "horizontal" &&
            text != "vertical") {
            MACISHTYPE_WARN()
                << "candidateWindow.layoutDirection: invalid value ignored: "
                << text;
            return;
        }
        engineCandidateWindow_[field] = std::move(text);
        return;
    }
    }
}

std::filesystem::path
JsEngineHost::storagePathForKey(const std::string &key) const {
    return canonicalRoot_ / "_storage" / encodeStorageKey(key);
}

// Native bridge functions -------------------------------------------------

JsEngineHost *JsEngineHost::hostOf(JSContext *ctx) {
    return static_cast<JsEngineHost *>(JS_GetContextOpaque(ctx));
}

JSValue JsEngineHost::nativeLog(JSContext *ctx, JSValueConst thisVal,
                                int argc, JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
    auto *host = hostOf(ctx);
    std::string level = argc > 0 ? qjs::toString(ctx, argv[0]) : "info";
    std::string message = argc > 1 ? qjs::toString(ctx, argv[1]) : "";
    if (level == "error" || level == "fault") {
        MACISHTYPE_ERROR() << "[" << host->engineId_ << "] " << message;
    } else if (level == "notice") {
        MACISHTYPE_WARN() << "[" << host->engineId_ << "] " << message;
    } else if (level == "debug") {
        MACISHTYPE_DEBUG() << "[" << host->engineId_ << "] " << message;
    } else {
        MACISHTYPE_INFO() << "[" << host->engineId_ << "] " << message;
    }
    return JS_UNDEFINED;
}

JSValue JsEngineHost::nativeManifestName(JSContext *ctx,
                                         JSValueConst thisVal, int argc,
                                         JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
    FCITX_UNUSED(argc);
    FCITX_UNUSED(argv);
    auto *host = hostOf(ctx);
    if (host->manifest_.displayName.empty()) {
        return JS_NULL;
    }
    return JS_NewString(ctx, host->manifest_.displayName.c_str());
}

JSValue JsEngineHost::nativeGetCandidateWindowField(JSContext *ctx,
                                                    JSValueConst thisVal,
                                                    int argc,
                                                    JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
    auto *host = hostOf(ctx);
    if (argc < 1) {
        return JS_NULL;
    }
    auto value = host->candidateWindowField(qjs::toString(ctx, argv[0]));
    if (!value) {
        return JS_NULL;
    }
    if (auto *boolean = std::get_if<bool>(&*value)) {
        return JS_NewBool(ctx, *boolean);
    }
    if (auto *number = std::get_if<double>(&*value)) {
        return JS_NewFloat64(ctx, *number);
    }
    return JS_NewString(ctx, std::get<std::string>(*value).c_str());
}

JSValue JsEngineHost::nativeSetCandidateWindowField(JSContext *ctx,
                                                    JSValueConst thisVal,
                                                    int argc,
                                                    JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
    auto *host = hostOf(ctx);
    if (argc >= 2) {
        host->setCandidateWindowField(qjs::toString(ctx, argv[0]), argv[1]);
    }
    return JS_UNDEFINED;
}

JSValue JsEngineHost::nativeCandidateWindowFields(JSContext *ctx,
                                                  JSValueConst thisVal,
                                                  int argc,
                                                  JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
    FCITX_UNUSED(argc);
    FCITX_UNUSED(argv);
    auto *host = hostOf(ctx);
    JSValue array = JS_NewArray(ctx);
    uint32_t index = 0;
    auto push = [&](const std::string &field) {
        JS_SetPropertyUint32(ctx, array, index++,
                             JS_NewString(ctx, field.c_str()));
    };
    for (const auto &[field, value] : host->engineCandidateWindow_) {
        FCITX_UNUSED(value);
        push(field);
    }
    for (const auto &[field, value] : host->manifestCandidateWindow_) {
        FCITX_UNUSED(value);
        if (host->engineCandidateWindow_.count(field) == 0) {
            push(field);
        }
    }
    return array;
}

void JsEngineHost::setMenuDelegate(const std::string &key,
                                   MenuDelegate delegate) {
    if (menuValues_.count(key) == 0) {
        MACISHTYPE_WARN() << "menu delegate for undeclared key ignored: "
                          << key;
        return;
    }
    menuDelegates_[key] = std::move(delegate);
}

JSValue JsEngineHost::nativeGetMenuValue(JSContext *ctx, JSValueConst thisVal,
                                         int argc, JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
    auto *host = hostOf(ctx);
    if (argc < 1) {
        return JS_NULL;
    }
    std::string key = qjs::toString(ctx, argv[0]);
    auto found = host->menuValues_.find(key);
    if (found == host->menuValues_.end()) {
        return JS_NULL;
    }
    if (auto delegate = host->menuDelegates_.find(key);
        delegate != host->menuDelegates_.end()) {
        return JS_NewBool(ctx, delegate->second.get());
    }
    return JS_NewBool(ctx, found->second);
}

JSValue JsEngineHost::nativeSetMenuValue(JSContext *ctx, JSValueConst thisVal,
                                         int argc, JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
    auto *host = hostOf(ctx);
    if (argc < 2) {
        return JS_UNDEFINED;
    }
    std::string key = qjs::toString(ctx, argv[0]);
    auto found = host->menuValues_.find(key);
    if (found == host->menuValues_.end()) {
        MACISHTYPE_WARN() << "menu: write to undeclared key ignored: " << key;
        return JS_UNDEFINED;
    }
    if (!JS_IsBool(argv[1])) {
        MACISHTYPE_WARN() << "menu." << key
                          << ": expected boolean, write ignored";
        return JS_UNDEFINED;
    }
    bool value = JS_ToBool(ctx, argv[1]) == 1;
    found->second = value;
    if (auto delegate = host->menuDelegates_.find(key);
        delegate != host->menuDelegates_.end()) {
        delegate->second.set(value);
    }
    return JS_UNDEFINED;
}

JSValue JsEngineHost::nativeMenuKeys(JSContext *ctx, JSValueConst thisVal,
                                     int argc, JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
    FCITX_UNUSED(argc);
    FCITX_UNUSED(argv);
    auto *host = hostOf(ctx);
    JSValue array = JS_NewArray(ctx);
    uint32_t index = 0;
    for (const auto &[key, value] : host->menuValues_) {
        FCITX_UNUSED(value);
        JS_SetPropertyUint32(ctx, array, index++,
                             JS_NewString(ctx, key.c_str()));
    }
    return array;
}

JSValue JsEngineHost::nativeStorageGetItem(JSContext *ctx,
                                           JSValueConst thisVal, int argc,
                                           JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
    auto *host = hostOf(ctx);
    if (argc < 1) {
        return JS_NULL;
    }
    auto content =
        readFile(host->storagePathForKey(qjs::toString(ctx, argv[0])));
    if (!content) {
        return JS_NULL;
    }
    return JS_NewStringLen(ctx, content->c_str(), content->size());
}

JSValue JsEngineHost::nativeStorageSetItem(JSContext *ctx,
                                           JSValueConst thisVal, int argc,
                                           JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
    auto *host = hostOf(ctx);
    if (argc < 2) {
        return JS_UNDEFINED;
    }
    std::string key = qjs::toString(ctx, argv[0]);
    if (key.empty()) {
        return JS_ThrowTypeError(ctx, "localStorage: key must not be empty");
    }
    if (encodeStorageKey(key).size() > kStorageMaxEncodedKeyBytes) {
        return JS_ThrowRangeError(
            ctx, "localStorage: encoded key exceeds %zu bytes",
            kStorageMaxEncodedKeyBytes);
    }
    std::string value = qjs::toString(ctx, argv[1]);
    if (value.size() > kStorageMaxValueBytes) {
        return JS_ThrowRangeError(ctx,
                                  "localStorage: value exceeds %zu bytes",
                                  kStorageMaxValueBytes);
    }
    auto path = host->storagePathForKey(key);
    std::error_code errorCode;
    std::filesystem::create_directories(path.parent_path(), errorCode);
    std::ofstream stream(path, std::ios::binary | std::ios::trunc);
    if (!stream || !(stream << value)) {
        MACISHTYPE_ERROR() << "localStorage: cannot write " << path;
    }
    return JS_UNDEFINED;
}

JSValue JsEngineHost::nativeStorageRemoveItem(JSContext *ctx,
                                              JSValueConst thisVal, int argc,
                                              JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
    auto *host = hostOf(ctx);
    if (argc < 1) {
        return JS_UNDEFINED;
    }
    std::error_code errorCode;
    std::filesystem::remove(
        host->storagePathForKey(qjs::toString(ctx, argv[0])), errorCode);
    return JS_UNDEFINED;
}

JSValue JsEngineHost::nativeStorageClear(JSContext *ctx, JSValueConst thisVal,
                                         int argc, JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
    FCITX_UNUSED(argc);
    FCITX_UNUSED(argv);
    auto *host = hostOf(ctx);
    std::error_code errorCode;
    std::filesystem::remove_all(host->canonicalRoot_ / "_storage", errorCode);
    return JS_UNDEFINED;
}

JSValue JsEngineHost::nativeStorageKeys(JSContext *ctx, JSValueConst thisVal,
                                        int argc, JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
    FCITX_UNUSED(argc);
    FCITX_UNUSED(argv);
    auto *host = hostOf(ctx);
    JSValue array = JS_NewArray(ctx);
    uint32_t index = 0;
    std::error_code errorCode;
    std::filesystem::directory_iterator iterator(
        host->canonicalRoot_ / "_storage", errorCode);
    if (errorCode) {
        return array;
    }
    for (const auto &fileEntry : iterator) {
        if (!fileEntry.is_regular_file(errorCode)) {
            continue;
        }
        auto key = decodeStorageKey(fileEntry.path().filename().string());
        if (key) {
            JS_SetPropertyUint32(ctx, array, index++,
                                 JS_NewStringLen(ctx, key->c_str(),
                                                 key->size()));
        }
    }
    return array;
}

JSValue JsEngineHost::nativeSetStorageListening(JSContext *ctx,
                                                JSValueConst thisVal,
                                                int argc, JSValueConst *argv) {
    FCITX_UNUSED(ctx);
    FCITX_UNUSED(thisVal);
    FCITX_UNUSED(argc);
    FCITX_UNUSED(argv);
    // TODO: inotify watcher on _storage/ feeding
    // __MacishType_dispatchStorageEvent.
    return JS_UNDEFINED;
}

JSValue JsEngineHost::nativeGetLanguages(JSContext *ctx, JSValueConst thisVal,
                                         int argc, JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
    FCITX_UNUSED(argc);
    FCITX_UNUSED(argv);
    auto *host = hostOf(ctx);
    JSValue array = JS_NewArray(ctx);
    uint32_t index = 0;
    for (const auto &language : host->languages_) {
        JS_SetPropertyUint32(ctx, array, index++,
                             JS_NewString(ctx, language.c_str()));
    }
    return array;
}

JSValue JsEngineHost::nativeReadEngineFile(JSContext *ctx,
                                           JSValueConst thisVal, int argc,
                                           JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
    auto *host = hostOf(ctx);
    if (argc < 1) {
        return JS_ThrowTypeError(ctx, "fetch: missing path");
    }
    auto resolved = host->resolveEnginePath(qjs::toString(ctx, argv[0]));
    if (auto *error = std::get_if<std::string>(&resolved)) {
        return JS_ThrowPlainError(ctx, "fetch: %s", error->c_str());
    }
    auto &filePath = std::get<ResolvedPath>(resolved);
    auto content = readFile(filePath.fileSystemPath);
    if (!content) {
        return JS_ThrowPlainError(ctx, "fetch: cannot read %s",
                                  filePath.url.c_str());
    }
    JSValue result = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, result, "url",
                      JS_NewString(ctx, filePath.url.c_str()));
    JS_SetPropertyStr(
        ctx, result, "buffer",
        JS_NewArrayBufferCopy(
            ctx, reinterpret_cast<const uint8_t *>(content->data()),
            content->size()));
    return result;
}

JSValue JsEngineHost::nativeAction(JSContext *ctx, JSValueConst thisVal,
                                   int argc, JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
    auto *host = hostOf(ctx);
    if (argc < 1) {
        return JS_UNDEFINED;
    }
    std::string name = qjs::toString(ctx, argv[0]);
    if (!host->actionHandler_) {
        MACISHTYPE_WARN() << host->engineId_ << ": mutator '" << name
                          << "' called outside an engine hook, ignored";
        return JS_UNDEFINED;
    }
    host->actionHandler_(name, argc - 1, argv + 1);
    return JS_UNDEFINED;
}

JSValue JsEngineHost::nativeUtf8Decode(JSContext *ctx, JSValueConst thisVal,
                                       int argc, JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
    if (argc < 1) {
        return JS_ThrowTypeError(ctx, "utf8Decode: missing buffer");
    }
    size_t size = 0;
    uint8_t *data = JS_GetArrayBuffer(ctx, &size, argv[0]);
    if (data == nullptr) {
        return JS_EXCEPTION;
    }
    std::string_view text(reinterpret_cast<const char *>(data), size);
    if (!fcitx::utf8::validate(text)) {
        return JS_ThrowTypeError(ctx, "invalid UTF-8");
    }
    return JS_NewStringLen(ctx, text.data(), text.size());
}

void JsEngineHost::registerBridgeGlobals() {
    qjs::Value global(ctx_, JS_GetGlobalObject(ctx_));
    auto define = [&](const char *name, JSCFunction *function, int length) {
        JS_SetPropertyStr(ctx_, global.get(), name,
                          JS_NewCFunction(ctx_, function, name, length));
    };
    define("__MacishType_log", &JsEngineHost::nativeLog, 2);
    define("__MacishType_manifestName", &JsEngineHost::nativeManifestName, 0);
    define("__MacishType_getCandidateWindowField",
           &JsEngineHost::nativeGetCandidateWindowField, 1);
    define("__MacishType_setCandidateWindowField",
           &JsEngineHost::nativeSetCandidateWindowField, 2);
    define("__MacishType_candidateWindowFields",
           &JsEngineHost::nativeCandidateWindowFields, 0);
    define("__MacishType_getMenuValue", &JsEngineHost::nativeGetMenuValue, 1);
    define("__MacishType_setMenuValue", &JsEngineHost::nativeSetMenuValue, 2);
    define("__MacishType_menuKeys", &JsEngineHost::nativeMenuKeys, 0);
    define("__MacishType_storageGetItem",
           &JsEngineHost::nativeStorageGetItem, 1);
    define("__MacishType_storageSetItem",
           &JsEngineHost::nativeStorageSetItem, 2);
    define("__MacishType_storageRemoveItem",
           &JsEngineHost::nativeStorageRemoveItem, 1);
    define("__MacishType_storageClear", &JsEngineHost::nativeStorageClear, 0);
    define("__MacishType_storageKeys", &JsEngineHost::nativeStorageKeys, 0);
    define("__MacishType_setStorageListening",
           &JsEngineHost::nativeSetStorageListening, 1);
    define("__MacishType_getLanguages", &JsEngineHost::nativeGetLanguages, 0);
    define("__MacishTypeHost_readEngineFile",
           &JsEngineHost::nativeReadEngineFile, 1);
    define("__MacishTypeHost_utf8Decode", &JsEngineHost::nativeUtf8Decode, 1);
    define("__MacishTypeHost_action", &JsEngineHost::nativeAction, 1);
    JS_SetPropertyStr(ctx_, global.get(), "__MacishType_userAgent",
                      JS_NewString(ctx_, userAgent_.c_str()));
}

} // namespace macishtype
