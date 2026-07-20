#include "enginehost.h"

#include <sys/stat.h>
#include <sys/utsname.h>

#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>

#include <fcitx/instance.h>

#include <fcitx-utils/standardpaths.h>
#include <fcitx-utils/utf8.h>

#include "../log.h"
#include "fontcoverage.h"
#include "qjsutil.h"

// quickjs-ng's Unicode tables back the grapheme segmenter (UAX #29). Folded
// into this .so as a static lib, so its symbols link despite hidden
// visibility; the header ships on the qjs target's public include path.
#include "libunicode.h"

namespace macishtype {

namespace {

constexpr std::string_view kEngineUrlPrefix = "engine:///";
constexpr auto kWatchdogTimeout = std::chrono::seconds(3);
constexpr size_t kStorageMaxEncodedKeyBytes = 200;
constexpr size_t kStorageMaxValueBytes = 10 * 1024 * 1024;

// navigator.userAgent platform segment helpers. Each host info axis is
// resolved independently so a missing source drops only its own token.
std::string displayServerName() {
    const char *sessionType = std::getenv("XDG_SESSION_TYPE");
    if (sessionType == nullptr) {
        return {};
    }
    const std::string_view type(sessionType);
    if (type == "wayland") {
        return "Wayland";
    }
    if (type == "x11") {
        return "X11";
    }
    return {};
}

std::string machineArchitecture() {
    struct utsname info;
    if (uname(&info) != 0) {
        return {};
    }
    return info.machine;
}

// Distro label like "Ubuntu 26.04" from /etc/os-release NAME + VERSION_ID.
std::string distroLabel() {
    std::ifstream file("/etc/os-release");
    if (!file) {
        return {};
    }
    std::string name;
    std::string versionId;
    std::string line;
    const auto readField = [&line](std::string_view key, std::string &out) {
        if (line.rfind(key, 0) != 0) {
            return;
        }
        std::string value = line.substr(key.size());
        if (value.size() >= 2 && value.front() == '"' && value.back() == '"') {
            value = value.substr(1, value.size() - 2);
        }
        out = std::move(value);
    };
    while (std::getline(file, line)) {
        readField("NAME=", name);
        readField("VERSION_ID=", versionId);
    }
    if (name.empty()) {
        return {};
    }
    if (versionId.empty()) {
        return name;
    }
    return name + " " + versionId;
}

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

// Filenames must match the macOS host byte for byte, so a user-layer
// engine folder (which carries its _storage) moves between platforms with
// its data intact. macOS encodes uppercase because the default APFS
// volume is case-insensitive, and excludes '.' so no key can produce a
// dotfile; both restrictions are inherited here.
constexpr char kStorageFilenamePrefix[] = "localStorage_";

bool isStorageSafeByte(char ch) {
    return (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') ||
           ch == '_' || ch == '-';
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

// Filename → key; nullopt for foreign files (no prefix) or malformed
// escapes, mirroring the macOS decodeFilename.
std::optional<std::string> decodeStorageKey(const std::string &filename) {
    constexpr size_t prefixLength = sizeof(kStorageFilenamePrefix) - 1;
    if (filename.rfind(kStorageFilenamePrefix, 0) != 0) {
        return std::nullopt;
    }
    std::string encoded = filename.substr(prefixLength);
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
                   const std::filesystem::path &storageRoot,
                   const std::string &settingsValuesJson,
                   const ManifestData &manifest,
                   const std::vector<std::string> &languages) {
    std::unique_ptr<JsEngineHost> host(
        new JsEngineHost(engineId, engineRoot, storageRoot,
                         settingsValuesJson, manifest, languages));
    if (!host->initialize()) {
        return nullptr;
    }
    return host;
}

JsEngineHost::JsEngineHost(std::string engineId,
                           std::filesystem::path engineRoot,
                           std::filesystem::path storageRoot,
                           std::string settingsValuesJson,
                           ManifestData manifest,
                           std::vector<std::string> languages)
    : engineId_(std::move(engineId)), engineRoot_(std::move(engineRoot)),
      storageRoot_(std::move(storageRoot)),
      settingsValuesJson_(settingsValuesJson.empty() ? "{}"
                                                     : std::move(
                                                           settingsValuesJson)),
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
    loadedFilePaths_.insert((canonicalRoot_ / "manifest.json").string());

    runtime_ = JS_NewRuntime();
    ctx_ = JS_NewContext(runtime_);
    JS_SetContextOpaque(ctx_, this);
    JS_SetInterruptHandler(runtime_, &JsEngineHost::interruptHandler, this);
    JS_SetHostPromiseRejectionTracker(runtime_,
                                      &JsEngineHost::rejectionTracker, this);
    JS_SetModuleLoaderFunc(runtime_, &JsEngineHost::moduleNormalize,
                           &JsEngineHost::moduleLoad, this);

    // Product token stays "MacishType/" across host ports; platform tokens
    // and the fcitx5/quickjs-ng segments identify this Linux host.
    std::vector<std::string> platformTokens;
    if (std::string displayServer = displayServerName();
        !displayServer.empty()) {
        platformTokens.push_back(std::move(displayServer));
    }
    if (std::string arch = machineArchitecture(); !arch.empty()) {
        platformTokens.push_back("Linux " + arch);
    } else {
        platformTokens.emplace_back("Linux");
    }
    if (std::string distro = distroLabel(); !distro.empty()) {
        platformTokens.push_back(std::move(distro));
    }
    std::string platform;
    for (size_t i = 0; i < platformTokens.size(); ++i) {
        if (i != 0) {
            platform += "; ";
        }
        platform += platformTokens[i];
    }
    userAgent_ = std::string("MacishType/") + MACISHTYPE_VERSION + " (" +
                 platform + ") fcitx5/" + fcitx::Instance::version() +
                 " quickjs-ng/" + JS_GetVersion();

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
    if (!pushSettings(settingsValuesJson_) || !injectModules()) {
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

bool JsEngineHost::pushSettings(const std::string &valuesJson) {
    Entry entry(*this);
    qjs::Value global(ctx_, JS_GetGlobalObject(ctx_));
    qjs::Value setter(
        ctx_, JS_GetPropertyStr(ctx_, global.get(), "__MacishType_setSettings"));
    if (!setter.isFunction()) {
        MACISHTYPE_ERROR() << "runtime.js did not define "
                              "__MacishType_setSettings";
        return false;
    }
    qjs::Value values(ctx_, JS_ParseJSON(ctx_, valuesJson.c_str(),
                                         valuesJson.size(), "settings"));
    if (values.isException()) {
        MACISHTYPE_ERROR() << "Invalid settings values: "
                           << qjs::exceptionText(ctx_);
        return false;
    }
    JSValue argument = values.get();
    qjs::Value result(
        ctx_, JS_Call(ctx_, setter.get(), JS_UNDEFINED, 1, &argument));
    if (result.isException()) {
        MACISHTYPE_ERROR() << "Settings push failed: "
                           << qjs::exceptionText(ctx_);
        return false;
    }
    return true;
}

void JsEngineHost::updateSettings(const std::string &valuesJson) {
    if (valuesJson.empty() || valuesJson == settingsValuesJson_) {
        return;
    }
    if (pushSettings(valuesJson)) {
        settingsValuesJson_ = valuesJson;
    }
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
            const std::string &coverage = fontCoverageBitmapBase64();
            JSValue arguments[2] = {
                JS_NewString(ctx_, moduleName.c_str()),
                JS_NewString(ctx_, coverage.c_str()),
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
            if (moduleName == "wordFrequency" || moduleName == "symbolNames") {
                loadModuleTable(table, moduleName,
                                moduleName == "wordFrequency");
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
// <pkgdata>/macishtype/modules/ ("key<TAB>value" lines, # comments). A
// missing file leaves the table empty, which reads as all-miss.
void JsEngineHost::loadModuleTable(JSValue table,
                                   const std::string &moduleName,
                                   bool numericValues) {
    if (manifest_.intendedLanguage.empty()) {
        return;
    }
    auto path = fcitx::StandardPaths::global().locate(
        fcitx::StandardPathsType::PkgData,
        "macishtype/modules/" + moduleName + "." +
            manifest_.intendedLanguage + ".tsv");
    if (path.empty()) {
        MACISHTYPE_INFO() << "No " << moduleName << " table for "
                          << manifest_.intendedLanguage
                          << "; module answers with its miss value (run "
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
        std::string key = line.substr(0, tab);
        std::string value = line.substr(tab + 1);
        if (numericValues) {
            int64_t number = 0;
            try {
                number = std::stoll(value);
            } catch (...) {
                continue;
            }
            JS_SetPropertyStr(ctx_, table, key.c_str(),
                              JS_NewInt64(ctx_, number));
        } else {
            JS_SetPropertyStr(ctx_, table, key.c_str(),
                              JS_NewStringLen(ctx_, value.c_str(),
                                              value.size()));
        }
        count++;
    }
    MACISHTYPE_INFO() << moduleName << "." << manifest_.intendedLanguage
                      << ": " << count << " entries";
}

namespace {
std::filesystem::path associatedDictionaryPath(const std::string &language) {
    if (language.empty()) {
        return {};
    }
    return fcitx::StandardPaths::global().locate(
        fcitx::StandardPathsType::PkgData,
        "macishtype/modules/AssociatedDictionary." + language + ".tsv");
}
} // namespace

bool associatedDictionaryAvailable(const std::string &intendedLanguage) {
    return !associatedDictionaryPath(intendedLanguage).empty();
}

void JsEngineHost::ensureAssociatedDictionary() {
    if (associatedDictionaryLoaded_) {
        return;
    }
    associatedDictionaryLoaded_ = true;
    auto path = associatedDictionaryPath(manifest_.intendedLanguage);
    if (path.empty()) {
        return;
    }
    std::ifstream stream(path, std::ios::binary);
    std::string line;
    while (std::getline(stream, line)) {
        if (line.empty() || line[0] == '#') {
            continue;
        }
        auto tab = line.find('\t');
        if (tab == std::string::npos) {
            continue;
        }
        std::string key = line.substr(0, tab);
        std::vector<std::string> followups;
        std::istringstream values(line.substr(tab + 1));
        std::string phrase;
        while (values >> phrase) {
            followups.push_back(phrase);
        }
        if (!key.empty() && !followups.empty()) {
            associatedDictionary_[key] = std::move(followups);
        }
    }
    MACISHTYPE_INFO() << "AssociatedDictionary." << manifest_.intendedLanguage
                      << ": " << associatedDictionary_.size() << " prefixes";
}

std::vector<std::string>
JsEngineHost::associatedFollowups(const std::string &heldChar) {
    ensureAssociatedDictionary();
    if (heldChar.empty() || !fcitx::utf8::validate(heldChar)) {
        return {};
    }
    // Key on the first character only; the dictionary is keyed by single
    // leading characters.
    size_t firstCharBytes =
        fcitx::utf8::ncharByteLength(heldChar.begin(), 1);
    auto found = associatedDictionary_.find(heldChar.substr(0, firstCharBytes));
    return found != associatedDictionary_.end() ? found->second
                                                : std::vector<std::string>{};
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
    loadedFilePaths_.insert(entryPath.fileSystemPath.string());

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
    host->loadedFilePaths_.insert(modulePath.fileSystemPath.string());
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
    return storageRoot_ / (kStorageFilenamePrefix + encodeStorageKey(key));
}

JsEngineHost::StorageFileState
JsEngineHost::statStorageFile(const std::filesystem::path &path) {
    struct stat buffer;
    if (::stat(path.c_str(), &buffer) != 0) {
        return {};
    }
    return {true,
            static_cast<int64_t>(buffer.st_mtim.tv_sec) * 1000000000 +
                buffer.st_mtim.tv_nsec,
            static_cast<uint64_t>(buffer.st_size)};
}

void JsEngineHost::recordSelfWrite(const std::filesystem::path &path) {
    recentSelfWrites_[path.string()] = statStorageFile(path);
}

void JsEngineHost::setStorageListeningObserver(
    std::function<void(bool)> observer) {
    storageListeningObserver_ = std::move(observer);
    if (storageListeningObserver_) {
        storageListeningObserver_(storageListening_);
    }
}

void JsEngineHost::handleStorageChanges(
    const std::set<std::string> &changedPaths) {
    std::set<std::string> keys;
    for (const auto &path : changedPaths) {
        if (auto found = recentSelfWrites_.find(path);
            found != recentSelfWrites_.end()) {
            if (statStorageFile(path) == found->second) {
                // Our own write's echo; keep the record so repeated
                // events for the same state stay silent.
                continue;
            }
            // An external write superseded ours.
            recentSelfWrites_.erase(found);
        }
        auto key = decodeStorageKey(
            std::filesystem::path(path).filename().string());
        if (key) {
            keys.insert(*key);
        }
    }
    for (const auto &key : keys) {
        dispatchStorageEvent(key);
    }
}

void JsEngineHost::dispatchStorageEvent(const std::string &key) {
    qjs::Value global(ctx_, JS_GetGlobalObject(ctx_));
    qjs::Value dispatch(
        ctx_,
        JS_GetPropertyStr(ctx_, global.get(),
                          "__MacishType_dispatchStorageEvent"));
    if (!JS_IsFunction(ctx_, dispatch.get())) {
        return;
    }
    JSValue keyValue = JS_NewStringLen(ctx_, key.c_str(), key.size());
    qjs::Value result(ctx_, JS_Call(ctx_, dispatch.get(), JS_UNDEFINED, 1,
                                    &keyValue));
    JS_FreeValue(ctx_, keyValue);
    if (result.isException()) {
        MACISHTYPE_ERROR() << "[" << engineId_
                           << "] storage event dispatch failed: "
                           << qjs::exceptionText(ctx_);
    }
    drainJobs();
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
    {
        std::ofstream stream(path, std::ios::binary | std::ios::trunc);
        if (!stream || !(stream << value)) {
            MACISHTYPE_ERROR() << "localStorage: cannot write " << path;
        }
    }
    host->recordSelfWrite(path);
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
    auto path = host->storagePathForKey(qjs::toString(ctx, argv[0]));
    std::error_code errorCode;
    std::filesystem::remove(path, errorCode);
    host->recordSelfWrite(path);
    return JS_UNDEFINED;
}

JSValue JsEngineHost::nativeStorageClear(JSContext *ctx, JSValueConst thisVal,
                                         int argc, JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
    FCITX_UNUSED(argc);
    FCITX_UNUSED(argv);
    auto *host = hostOf(ctx);
    // File-by-file rather than remove_all: deleting the directory itself
    // would kill the inotify watch serving storage events. Only files
    // carrying the storage prefix are ours to clear.
    std::error_code errorCode;
    std::filesystem::directory_iterator iterator(host->storageRoot_,
                                                 errorCode);
    if (errorCode) {
        return JS_UNDEFINED;
    }
    for (const auto &fileEntry : iterator) {
        if (!decodeStorageKey(fileEntry.path().filename().string())) {
            continue;
        }
        std::filesystem::remove(fileEntry.path(), errorCode);
        host->recordSelfWrite(fileEntry.path());
    }
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
    std::filesystem::directory_iterator iterator(host->storageRoot_,
                                                 errorCode);
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
    FCITX_UNUSED(thisVal);
    auto *host = hostOf(ctx);
    bool active = argc > 0 && JS_ToBool(ctx, argv[0]) == 1;
    if (host->storageListening_ == active) {
        return JS_UNDEFINED;
    }
    host->storageListening_ = active;
    if (host->storageListeningObserver_) {
        host->storageListeningObserver_(active);
    }
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
    // A fetch alone expresses interest in the file; record it before the
    // read so a later edit reloads even when this read fails.
    host->loadedFilePaths_.insert(filePath.fileSystemPath.string());
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

namespace {

// UAX #29 grapheme cluster segmentation, backed by quickjs-ng's Unicode
// tables. Prepend and SpacingMark are folded into Other: no current engine
// targets the Arabic or Indic scripts that need them, and misgrouping is
// confined to those scripts.
enum class GraphemeClass {
    Other,
    CR,
    LF,
    Control,
    Extend,
    ZWJ,
    RegionalIndicator,
    HangulL,
    HangulV,
    HangulT,
    HangulLV,
    HangulLVT,
    ExtendedPictographic,
};

void *graphemeCrRealloc(void *opaque, void *ptr, size_t size) {
    FCITX_UNUSED(opaque);
    if (size == 0) {
        free(ptr);
        return nullptr;
    }
    return realloc(ptr, size);
}

// Process-lifetime property sets from libunicode; the ranges are half-open
// [start, end) pairs, so membership is a parity check on the count of
// boundary points at or below the codepoint.
struct GraphemeTables {
    CharRange extend;
    CharRange emojiModifier;
    CharRange extendedPictographic;
    CharRange formatCf;
    GraphemeTables() {
        cr_init(&extend, nullptr, graphemeCrRealloc);
        unicode_prop(&extend, "Grapheme_Extend");
        cr_init(&emojiModifier, nullptr, graphemeCrRealloc);
        unicode_prop(&emojiModifier, "Emoji_Modifier");
        cr_init(&extendedPictographic, nullptr, graphemeCrRealloc);
        unicode_prop(&extendedPictographic, "Extended_Pictographic");
        cr_init(&formatCf, nullptr, graphemeCrRealloc);
        unicode_general_category(&formatCf, "Cf");
    }
};

bool crContains(const CharRange &cr, uint32_t c) {
    int lo = 0;
    int hi = cr.len;
    while (lo < hi) {
        int mid = (lo + hi) / 2;
        if (cr.points[mid] <= c) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return (lo & 1) != 0;
}

GraphemeClass classifyGrapheme(uint32_t c) {
    if (c == 0x0D) {
        return GraphemeClass::CR;
    }
    if (c == 0x0A) {
        return GraphemeClass::LF;
    }
    if (c == 0x200D) {
        return GraphemeClass::ZWJ;
    }
    if (c >= 0x1F1E6 && c <= 0x1F1FF) {
        return GraphemeClass::RegionalIndicator;
    }
    if ((c >= 0x1100 && c <= 0x115F) || (c >= 0xA960 && c <= 0xA97C)) {
        return GraphemeClass::HangulL;
    }
    if ((c >= 0x1160 && c <= 0x11A7) || (c >= 0xD7B0 && c <= 0xD7C6)) {
        return GraphemeClass::HangulV;
    }
    if ((c >= 0x11A8 && c <= 0x11FF) || (c >= 0xD7CB && c <= 0xD7FB)) {
        return GraphemeClass::HangulT;
    }
    if (c >= 0xAC00 && c <= 0xD7A3) {
        return ((c - 0xAC00) % 28 == 0) ? GraphemeClass::HangulLV
                                        : GraphemeClass::HangulLVT;
    }
    static const GraphemeTables tables;
    if (crContains(tables.extend, c) || crContains(tables.emojiModifier, c)) {
        return GraphemeClass::Extend;
    }
    if (crContains(tables.extendedPictographic, c)) {
        return GraphemeClass::ExtendedPictographic;
    }
    if (c <= 0x1F || (c >= 0x7F && c <= 0x9F) || c == 0x2028 || c == 0x2029 ||
        crContains(tables.formatCf, c)) {
        return GraphemeClass::Control;
    }
    return GraphemeClass::Other;
}

// A boundary exists between prev and curr. `emojiChain` is true when the run
// ending at prev is `ExtPict (Extend|ZWJ)*` (for GB11); `riRun` is the count
// of regional indicators ending at prev (for GB12/13).
bool graphemeBreakBetween(GraphemeClass prev, GraphemeClass curr,
                          bool emojiChain, int riRun) {
    using G = GraphemeClass;
    if (prev == G::CR && curr == G::LF) {
        return false; // GB3
    }
    if (prev == G::Control || prev == G::CR || prev == G::LF) {
        return true; // GB4
    }
    if (curr == G::Control || curr == G::CR || curr == G::LF) {
        return true; // GB5
    }
    if (prev == G::HangulL &&
        (curr == G::HangulL || curr == G::HangulV || curr == G::HangulLV ||
         curr == G::HangulLVT)) {
        return false; // GB6
    }
    if ((prev == G::HangulLV || prev == G::HangulV) &&
        (curr == G::HangulV || curr == G::HangulT)) {
        return false; // GB7
    }
    if ((prev == G::HangulLVT || prev == G::HangulT) && curr == G::HangulT) {
        return false; // GB8
    }
    if (curr == G::Extend || curr == G::ZWJ) {
        return false; // GB9
    }
    if (prev == G::ZWJ && emojiChain && curr == G::ExtendedPictographic) {
        return false; // GB11
    }
    if (prev == G::RegionalIndicator && curr == G::RegionalIndicator &&
        (riRun % 2 == 1)) {
        return false; // GB12/GB13
    }
    return true; // GB999
}

} // namespace

JSValue JsEngineHost::nativeSegmentGraphemes(JSContext *ctx,
                                             JSValueConst thisVal, int argc,
                                             JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
    JSValue array = JS_NewArray(ctx);
    if (argc < 1) {
        return array;
    }
    size_t byteLength = 0;
    const char *raw = JS_ToCStringLen(ctx, &byteLength, argv[0]);
    if (raw == nullptr) {
        JS_FreeValue(ctx, array);
        return JS_EXCEPTION;
    }
    std::string input(raw, byteLength);
    JS_FreeCString(ctx, raw);

    std::vector<uint32_t> codepoints;
    std::vector<size_t> byteStart;
    size_t offset = 0;
    auto charRange = fcitx::utf8::MakeUTF8CharRange(input);
    for (auto iterator = std::begin(charRange);
         iterator != std::end(charRange); ++iterator) {
        codepoints.push_back(*iterator);
        byteStart.push_back(offset);
        auto bytes = iterator.charRange();
        offset += static_cast<size_t>(bytes.second - bytes.first);
    }
    if (codepoints.empty()) {
        return array;
    }

    auto emit = [&](uint32_t index, size_t start, size_t end) {
        JS_SetPropertyUint32(
            ctx, array, index,
            JS_NewStringLen(ctx, input.data() + start, end - start));
    };

    uint32_t out = 0;
    size_t clusterStart = 0;
    GraphemeClass prev = classifyGrapheme(codepoints[0]);
    bool emojiChain = prev == GraphemeClass::ExtendedPictographic;
    int riRun = prev == GraphemeClass::RegionalIndicator ? 1 : 0;
    for (size_t i = 1; i < codepoints.size(); i++) {
        GraphemeClass curr = classifyGrapheme(codepoints[i]);
        if (graphemeBreakBetween(prev, curr, emojiChain, riRun)) {
            emit(out++, clusterStart, byteStart[i]);
            clusterStart = byteStart[i];
        }
        if (curr == GraphemeClass::ExtendedPictographic) {
            emojiChain = true;
        } else if (emojiChain && (curr == GraphemeClass::Extend ||
                                  curr == GraphemeClass::ZWJ)) {
            emojiChain = true;
        } else {
            emojiChain = false;
        }
        if (curr == GraphemeClass::RegionalIndicator) {
            riRun = prev == GraphemeClass::RegionalIndicator ? riRun + 1 : 1;
        } else {
            riRun = 0;
        }
        prev = curr;
    }
    emit(out, clusterStart, offset);
    return array;
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
    define("__MacishTypeHost_segmentGraphemes",
           &JsEngineHost::nativeSegmentGraphemes, 1);
    define("__MacishTypeHost_action", &JsEngineHost::nativeAction, 1);
    JS_SetPropertyStr(ctx_, global.get(), "__MacishType_userAgent",
                      JS_NewString(ctx_, userAgent_.c_str()));
}

} // namespace macishtype
