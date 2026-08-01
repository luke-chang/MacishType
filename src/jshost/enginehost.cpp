#include "enginehost.h"

#include <sys/stat.h>
#include <sys/utsname.h>

#include <algorithm>
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

namespace macishtype {

namespace {

constexpr std::string_view kEngineUrlPrefix = "engine:///";
constexpr auto kWatchdogTimeout = std::chrono::seconds(3);
constexpr size_t kStorageMaxEncodedKeyBytes = 200;
constexpr size_t kStorageMaxValueBytes = 10 * 1024 * 1024;
// Per-engine JS heap ceiling. Without it a malicious or buggy engine that
// allocates without bound grows until the kernel OOM-killer fires, taking
// fcitx5 (and possibly the desktop) down with it; the cap turns that into a JS
// out-of-memory exception confined to the offending engine. Sized far above
// any realistic input-method engine's footprint; raise it if a legitimate
// engine ever logs an out-of-memory failure.
constexpr size_t kRuntimeMemoryLimit = 512 * 1024 * 1024;

// Upper bound on codes marshaled from one reverseLookup result. A buggy or
// malicious engine returning a huge-length array (e.g. `new Array(2**32-1)`)
// would otherwise spin the marshal loop for billions of iterations on the main
// loop, past the watchdog's reach (element reads don't poll it). The display
// truncates far below this, so legitimate results are unaffected.
constexpr uint32_t kReverseLookupMaxMarshaledCodes = 4096;

// Idle delay (microseconds) before releasing a built reverse-lookup index,
// debouncing rapid focus/window switches. Overridable for tests.
uint64_t reverseLookupIdleReleaseMicros() {
    if (const char *ms = std::getenv("MACISHTYPE_REVERSE_LOOKUP_RELEASE_MS")) {
        char *end = nullptr;
        long value = std::strtol(ms, &end, 10);
        if (end != ms && value >= 0) {
            return static_cast<uint64_t>(value) * 1000;
        }
    }
    return 30ULL * 1000 * 1000;
}

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
                   const std::vector<std::string> &languages,
                   std::map<std::string, ToggleDelegate> toggleDelegates,
                   fcitx::EventLoop *eventLoop,
                   fcitx::EventDispatcher *dispatcher) {
    std::unique_ptr<JsEngineHost> host(
        new JsEngineHost(engineId, engineRoot, storageRoot,
                         settingsValuesJson, manifest, languages,
                         std::move(toggleDelegates), eventLoop, dispatcher));
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
                           std::vector<std::string> languages,
                           std::map<std::string, ToggleDelegate> toggleDelegates,
                           fcitx::EventLoop *eventLoop,
                           fcitx::EventDispatcher *dispatcher)
    : engineId_(std::move(engineId)), engineRoot_(std::move(engineRoot)),
      storageRoot_(std::move(storageRoot)),
      settingsValuesJson_(settingsValuesJson.empty() ? "{}"
                                                     : std::move(
                                                           settingsValuesJson)),
      manifest_(std::move(manifest)), languages_(std::move(languages)),
      toggleDelegates_(std::move(toggleDelegates)), eventLoop_(eventLoop),
      dispatcher_(dispatcher) {}

JsEngineHost::~JsEngineHost() {
    // Async-fetch teardown, strictly before the JS context dies:
    // cancel pending event sources, then join the worker (after which no
    // thread can touch this host), then invalidate the liveness token so a
    // completion closure already queued on the main loop becomes a pure
    // drop — it must not call JS_FreeValue on its batch's handles (the
    // context is about to be freed); those dup'd refs are reclaimed
    // wholesale by JS_FreeRuntime below.
    deferredSettle_.reset();
    reverseLookupReleaseTimer_.reset();
    if (fetchWorker_.joinable()) {
        fetchWorker_.join();
    }
    aliveToken_.reset();
    if (ctx_ != nullptr) {
        for (auto &fetch : pendingFetches_) {
            JS_FreeValue(ctx_, fetch.resolve);
            JS_FreeValue(ctx_, fetch.reject);
        }
        pendingFetches_.clear();
        JS_FreeValue(ctx_, makeResponse_);
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
    JS_SetMemoryLimit(runtime_, kRuntimeMemoryLimit);
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
    // COMPILE_ONLY still resolves the module's imports, so the whole static
    // import graph loads within this scope.
    JSValue compiledModule;
    {
        StaticImportScope staticImports(*this);
        compiledModule =
            JS_Eval(ctx_, content->c_str(), content->size(),
                    entryPath.url.c_str(),
                    JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    }
    qjs::Value compiled(ctx_, compiledModule);
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
        // The module top-level awaits a fetch. Deferred reads would leave
        // the module promise pending forever (load fails before any session
        // could arm the pipeline), so settle the queued fetches inline — the
        // engine opted into paying its read+parse during load by awaiting.
        // Loop: each settled generation can resume the module far enough to
        // queue the next dependent fetch; a module that is still pending
        // without queueing anything falls through to the error below.
        while (JS_PromiseState(ctx_, evaluation.get()) == JS_PROMISE_PENDING &&
               !pendingFetches_.empty()) {
            flushPendingFetchesSync();
            drainJobs();
        }
        switch (JS_PromiseState(ctx_, evaluation.get())) {
        case JS_PROMISE_FULFILLED:
            break;
        case JS_PROMISE_REJECTED: {
            qjs::Value reason(ctx_,
                              JS_PromiseResult(ctx_, evaluation.get()));
            MACISHTYPE_ERROR() << "Entry module rejected: "
                               << qjs::errorText(ctx_, reason.get());
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

// Reverse lookup ---------------------------------------------------------

uint64_t JsEngineHost::prepareReverseLookup(std::function<void(bool)> onReady) {
    uint64_t token = ++reverseLookupToken_;
    reverseLookupOnReady_ = std::move(onReady);
    // A fresh lookup cancels any pending idle release of the index.
    reverseLookupReleaseTimer_.reset();
    Entry entry(*this);
    qjs::Value method(
        ctx_, JS_GetPropertyStr(ctx_, engineClass_, "prepareReverseLookup"));
    if (!method.isFunction()) {
        settleReverseLookup(token, true); // absent => ready
        return token;
    }
    reverseLookupPrepared_ = true;
    qjs::Value result(
        ctx_, JS_Call(ctx_, method.get(), engineClass_, 0, nullptr));
    if (result.isException()) {
        MACISHTYPE_ERROR() << engineId_ << ".prepareReverseLookup threw: "
                           << qjs::exceptionText(ctx_);
        settleReverseLookup(token, false);
        return token;
    }
    if (!JS_IsPromise(result.get())) {
        settleReverseLookup(token, true); // synchronous => ready
        return token;
    }
    // Attach C++ reactions carrying the token (onResolve magic 1, onReject
    // magic 0). A synchronously-settled promise runs them during this Entry's
    // drainJobs (before we return); a pending one settles on a later turn.
    qjs::Value tokenValue(ctx_, JS_NewInt64(ctx_, static_cast<int64_t>(token)));
    JSValueConst data = tokenValue.get();
    qjs::Value onResolve(
        ctx_, JS_NewCFunctionData(ctx_, reverseLookupReaction, 1, 1, 1, &data));
    qjs::Value onReject(
        ctx_, JS_NewCFunctionData(ctx_, reverseLookupReaction, 1, 0, 1, &data));
    qjs::Value thenFn(ctx_, JS_GetPropertyStr(ctx_, result.get(), "then"));
    if (!thenFn.isFunction()) {
        settleReverseLookup(token, true);
        return token;
    }
    JSValue args[2] = {onResolve.get(), onReject.get()};
    qjs::Value chained(
        ctx_, JS_Call(ctx_, thenFn.get(), result.get(), 2, args));
    if (chained.isException()) {
        MACISHTYPE_ERROR() << engineId_
                           << ": prepareReverseLookup .then failed: "
                           << qjs::exceptionText(ctx_);
        settleReverseLookup(token, false);
    }
    return token;
}

void JsEngineHost::settleReverseLookup(uint64_t token, bool ready) {
    if (token != reverseLookupToken_ || !reverseLookupOnReady_) {
        return; // superseded / cancelled: drop the abandoned query's result
    }
    auto callback = std::move(reverseLookupOnReady_);
    reverseLookupOnReady_ = nullptr;
    callback(ready);
}

void JsEngineHost::cancelReverseLookupWait(uint64_t token) {
    if (token != reverseLookupToken_) {
        return;
    }
    ++reverseLookupToken_; // invalidate any still-pending reaction
    reverseLookupOnReady_ = nullptr;
}

std::vector<JsEngineHost::ReverseCode>
JsEngineHost::reverseLookup(const std::string &character) {
    std::vector<ReverseCode> codes;
    Entry entry(*this);
    qjs::Value method(
        ctx_, JS_GetPropertyStr(ctx_, engineClass_, "reverseLookup"));
    if (!method.isFunction()) {
        return codes;
    }
    qjs::Value arg(
        ctx_, JS_NewStringLen(ctx_, character.c_str(), character.size()));
    JSValue argv = arg.get();
    qjs::Value result(
        ctx_, JS_Call(ctx_, method.get(), engineClass_, 1, &argv));
    if (result.isException()) {
        MACISHTYPE_ERROR() << engineId_ << ".reverseLookup threw: "
                           << qjs::exceptionText(ctx_);
        return codes;
    }
    if (!JS_IsArray(result.get())) {
        return codes;
    }
    qjs::Value lengthValue(ctx_,
                           JS_GetPropertyStr(ctx_, result.get(), "length"));
    uint32_t length = 0;
    JS_ToUint32(ctx_, &length, lengthValue.get());
    uint32_t limit = std::min(length, kReverseLookupMaxMarshaledCodes);
    for (uint32_t i = 0; i < limit; i++) {
        qjs::Value item(ctx_, JS_GetPropertyUint32(ctx_, result.get(), i));
        ReverseCode code;
        if (JS_IsString(item.get())) {
            code.code = qjs::toString(ctx_, item.get());
        } else if (JS_IsObject(item.get())) {
            qjs::Value codeValue(
                ctx_, JS_GetPropertyStr(ctx_, item.get(), "code"));
            if (!JS_IsString(codeValue.get())) {
                continue; // require a string `code`
            }
            code.code = qjs::toString(ctx_, codeValue.get());
            qjs::Value annotation(
                ctx_, JS_GetPropertyStr(ctx_, item.get(), "annotation"));
            if (JS_IsString(annotation.get())) {
                code.annotation = qjs::toString(ctx_, annotation.get());
            }
        } else {
            continue;
        }
        codes.push_back(std::move(code));
    }
    return codes;
}

void JsEngineHost::releaseReverseLookup() {
    if (!reverseLookupPrepared_) {
        return;
    }
    reverseLookupPrepared_ = false;
    ++reverseLookupToken_; // invalidate any straggler reaction
    reverseLookupOnReady_ = nullptr;
    Entry entry(*this);
    qjs::Value method(
        ctx_, JS_GetPropertyStr(ctx_, engineClass_, "endReverseLookup"));
    if (method.isFunction()) {
        qjs::Value result(
            ctx_, JS_Call(ctx_, method.get(), engineClass_, 0, nullptr));
        if (result.isException()) {
            MACISHTYPE_ERROR() << engineId_ << ".endReverseLookup threw: "
                               << qjs::exceptionText(ctx_);
        }
    }
}

JSValue JsEngineHost::reverseLookupReaction(JSContext *ctx,
                                            JSValueConst thisVal, int argc,
                                            JSValueConst *argv, int magic,
                                            JSValueConst *funcData) {
    FCITX_UNUSED(thisVal);
    FCITX_UNUSED(argc);
    FCITX_UNUSED(argv);
    int64_t token = 0;
    JS_ToInt64(ctx, &token, funcData[0]);
    hostOf(ctx)->settleReverseLookup(static_cast<uint64_t>(token), magic != 0);
    return JS_UNDEFINED;
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
    host->pendingRejections_[key] = qjs::errorText(ctx, reason);
}

// Async fetch pipeline ---------------------------------------------------
//
// fetch() resolves the path synchronously (spec: invalid paths reject at
// fetch() time) but the disk read runs on a worker thread and the promise
// settles — where the engine's .then/JSON.parse runs — on a later main-loop
// turn, as soon as the bytes arrive. No artificial delay: this mirrors the
// macOS host (GCD background read, main-thread settle) and the web, where
// only the I/O is off-thread. The active gate exists for correctness, not
// pacing: while a module load runs (no session yet) fetches stay queued so
// the top-level-await fallback can read them inline.
//
// Hard invariants (each PendingFetch is settled and freed exactly once):
// - dispatchToWorker moves out only not-yet-read items (bytes == nullopt);
//   staged results never reach the worker again.
// - The deferred-settle path moves out only staged items (bytes present).
// - settleFetches owns its batch; items never return to the queue.
// The two paths operate on disjoint subsets.

void JsEngineHost::incrementActive() {
    // Reuse within the idle window keeps the reverse index (cheap re-lookup).
    reverseLookupReleaseTimer_.reset();
    ++activeCount_;
    if (activeCount_ == 1) {
        dispatchToWorker();
        scheduleDeferredSettle();
    }
}

void JsEngineHost::decrementActive() {
    --activeCount_;
    if (activeCount_ <= 0) {
        // Queued items and staged bytes survive for the next activation; an
        // in-flight worker read finishes harmlessly off-loop and its results
        // are staged by the (inactive) completion.
        deferredSettle_.reset();
        // Release the host-scoped reverse index after an idle grace period, so
        // brief focus/window switches don't churn a rebuild.
        if (reverseLookupPrepared_ && eventLoop_ != nullptr) {
            reverseLookupReleaseTimer_ = eventLoop_->addTimeEvent(
                CLOCK_MONOTONIC,
                fcitx::now(CLOCK_MONOTONIC) + reverseLookupIdleReleaseMicros(),
                0, [this](fcitx::EventSourceTime *, uint64_t) {
                    // Guard the self-destroy: touch only `self` after reset.
                    auto *self = this;
                    if (self->activeCount_ <= 0) {
                        self->releaseReverseLookup();
                    }
                    self->reverseLookupReleaseTimer_.reset();
                    return true;
                });
        }
    }
}

void JsEngineHost::dispatchToWorker() {
    if (workerBusy_ || dispatcher_ == nullptr || activeCount_ <= 0) {
        return;
    }
    std::vector<PendingFetch> batch;
    auto it = pendingFetches_.begin();
    while (it != pendingFetches_.end()) {
        if (!it->bytes) {
            batch.push_back(std::move(*it));
            it = pendingFetches_.erase(it);
        } else {
            ++it;
        }
    }
    if (batch.empty()) {
        return;
    }
    workerBusy_ = true;
    if (fetchWorker_.joinable()) {
        // The previous worker already scheduled its completion; reclaim it.
        fetchWorker_.join();
    }
    // The worker touches only the moved batch's paths/bytes — never the
    // JSContext or other host state. It must always schedule the completion
    // (even on failure), or workerBusy_ would stay stuck.
    fetchWorker_ = std::thread([this, alive = std::weak_ptr<char>(aliveToken_),
                                dispatcher = dispatcher_,
                                batch = std::move(batch)]() mutable {
        for (auto &fetch : batch) {
            try {
                fetch.bytes = readFile(fetch.fileSystemPath);
            } catch (...) {
                fetch.bytes = std::nullopt;
            }
        }
        dispatcher->schedule([this, alive = std::move(alive),
                              batch = std::move(batch)]() mutable {
            if (alive.expired()) {
                // Host died first: pure drop. No JS_* calls — the context is
                // gone and JS_FreeRuntime reclaimed the batch's dup'd refs.
                return;
            }
            completeWorkerBatch(std::move(batch));
        });
    });
}

void JsEngineHost::completeWorkerBatch(std::vector<PendingFetch> batch) {
    workerBusy_ = false;
    if (activeCount_ > 0) {
        settleFetches(std::move(batch));
    } else {
        // Inactive: stage successful reads for the next activation (the read
        // is not repeated), but reject failures right away — a nullopt is
        // only distinguishable as "failed" inside a completed batch.
        std::vector<PendingFetch> failures;
        for (auto &fetch : batch) {
            if (fetch.bytes) {
                pendingFetches_.push_back(std::move(fetch));
            } else {
                failures.push_back(std::move(fetch));
            }
        }
        if (!failures.empty()) {
            settleFetches(std::move(failures));
        }
    }
    // Anything enqueued while the worker ran.
    dispatchToWorker();
}

void JsEngineHost::scheduleDeferredSettle() {
    if (deferredSettle_ || eventLoop_ == nullptr) {
        return;
    }
    bool hasStaged = std::any_of(
        pendingFetches_.begin(), pendingFetches_.end(),
        [](const PendingFetch &fetch) { return fetch.bytes.has_value(); });
    if (!hasStaged) {
        return;
    }
    // Never settle synchronously here: incrementActive runs inside
    // activate(), and settling would put the parse back on the activate
    // turn — the stall this pipeline exists to remove.
    deferredSettle_ = eventLoop_->addDeferEvent([this](fcitx::EventSource *) {
        auto *self = this;
        self->deferredSettle_.reset();
        std::vector<PendingFetch> staged;
        auto it = self->pendingFetches_.begin();
        while (it != self->pendingFetches_.end()) {
            if (it->bytes.has_value()) {
                staged.push_back(std::move(*it));
                it = self->pendingFetches_.erase(it);
            } else {
                ++it;
            }
        }
        self->settleFetches(std::move(staged));
        return true;
    });
}

void JsEngineHost::settleFetches(std::vector<PendingFetch> batch) {
    for (auto &fetch : batch) {
        // One Entry per fetch: each settle (and the .then/parse chain that
        // drains when it unwinds) gets its own watchdog window, matching the
        // per-invokeHook granularity runtime fetches had when synchronous.
        Entry entry(*this);
        bool resolved = false;
        if (fetch.bytes && !JS_IsUndefined(makeResponse_)) {
            JSValue url = JS_NewString(ctx_, fetch.url.c_str());
            JSValue buffer = JS_NewArrayBufferCopy(
                ctx_, reinterpret_cast<const uint8_t *>(fetch.bytes->data()),
                fetch.bytes->size());
            JSValue args[2] = {url, buffer};
            JSValue response =
                JS_Call(ctx_, makeResponse_, JS_UNDEFINED, 2, args);
            JS_FreeValue(ctx_, url);
            JS_FreeValue(ctx_, buffer);
            if (JS_IsException(response)) {
                MACISHTYPE_ERROR() << engineId_ << ": fetch response failed: "
                                   << qjs::exceptionText(ctx_);
            } else {
                JSValue result =
                    JS_Call(ctx_, fetch.resolve, JS_UNDEFINED, 1, &response);
                JS_FreeValue(ctx_, result);
                resolved = true;
            }
            JS_FreeValue(ctx_, response);
        }
        if (!resolved) {
            std::string message = "fetch: cannot read " + fetch.url;
            JSValue error = JS_NewError(ctx_);
            JS_SetPropertyStr(ctx_, error, "message",
                              JS_NewStringLen(ctx_, message.c_str(),
                                              message.size()));
            JSValue result =
                JS_Call(ctx_, fetch.reject, JS_UNDEFINED, 1, &error);
            JS_FreeValue(ctx_, error);
            JS_FreeValue(ctx_, result);
        }
        JS_FreeValue(ctx_, fetch.resolve);
        JS_FreeValue(ctx_, fetch.reject);
        fetch.resolve = JS_UNDEFINED;
        fetch.reject = JS_UNDEFINED;
    }
}

void JsEngineHost::flushPendingFetchesSync() {
    std::vector<PendingFetch> batch;
    batch.swap(pendingFetches_);
    for (auto &fetch : batch) {
        if (!fetch.bytes) {
            fetch.bytes = readFile(fetch.fileSystemPath);
        }
    }
    settleFetches(std::move(batch));
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
    auto *host = static_cast<JsEngineHost *>(opaque);
    if (host->staticImportDepth_ == 0) {
        // The contract has no dynamic import(); quickjs would otherwise serve
        // it. Rejecting in the normalizer rather than the loader also covers a
        // specifier the static graph already loaded, which quickjs answers
        // from its module map without ever calling the loader.
        JS_ThrowTypeError(ctx, "dynamic import() is not supported");
        return nullptr;
    }
    std::string name(moduleName);
    if (name.rfind(kEngineUrlPrefix, 0) == 0) {
        return js_strdup(ctx, name.c_str());
    }
    if (name.rfind('/', 0) == 0) {
        // Engine-root-absolute specifier ("/util.js" → engine folder root).
        auto normalized = normalizeRelativePath(name.substr(1));
        if (!normalized || normalized->empty()) {
            return js_strdup(ctx, name.c_str());
        }
        std::string resolved = std::string(kEngineUrlPrefix) + *normalized;
        return js_strdup(ctx, resolved.c_str());
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
        if (field == "pageSize" && number > 11) {
            MACISHTYPE_WARN() << "candidateWindow.pageSize: out of range "
                                 "(1-11), write ignored";
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
        if (field == "indexLabels") {
            for (unsigned char ch : text) {
                if (ch < 0x20 || ch > 0x7E) {
                    MACISHTYPE_WARN()
                        << "candidateWindow.indexLabels: expected ASCII "
                           "printable (0x20-0x7E), write ignored";
                    return;
                }
            }
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

bool JsEngineHost::storageRootUsable() const {
    std::error_code errorCode;
    if (std::filesystem::is_symlink(storageRoot_, errorCode)) {
        MACISHTYPE_ERROR() << "[" << engineId_
                           << "] storage root is a symlink; refusing access: "
                           << storageRoot_;
        return false;
    }
    return true;
}

std::optional<std::filesystem::path>
JsEngineHost::safeStoragePath(const std::string &key) const {
    if (!storageRootUsable()) {
        return std::nullopt;
    }
    auto path = storagePathForKey(key);
    std::error_code errorCode;
    if (std::filesystem::is_symlink(path, errorCode)) {
        MACISHTYPE_WARN() << "[" << engineId_
                          << "] refusing symlinked storage file: " << path;
        return std::nullopt;
    }
    return path;
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
    if (!storageRootUsable()) {
        return;
    }
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
    // Arm the watchdog and drain microtasks on unwind, like every other
    // host->JS entry point; a storage listener is arbitrary engine code.
    Entry entry(*this);
    JSValue keyValue = JS_NewStringLen(ctx_, key.c_str(), key.size());
    qjs::Value result(ctx_, JS_Call(ctx_, dispatch.get(), JS_UNDEFINED, 1,
                                    &keyValue));
    JS_FreeValue(ctx_, keyValue);
    if (result.isException()) {
        MACISHTYPE_ERROR() << "[" << engineId_
                           << "] storage event dispatch failed: "
                           << qjs::exceptionText(ctx_);
    }
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

void JsEngineHost::dispatchToggleChange(const std::string &key) {
    if (toggleDelegates_.count(key) == 0) {
        return;
    }
    qjs::Value global(ctx_, JS_GetGlobalObject(ctx_));
    qjs::Value dispatch(ctx_,
                        JS_GetPropertyStr(ctx_, global.get(),
                                          "__MacishType_dispatchGlobal"));
    if (!JS_IsFunction(ctx_, dispatch.get())) {
        return;
    }
    // Arm the watchdog and drain microtasks on unwind, like every other
    // host->JS entry point; a togglechange listener is arbitrary engine code.
    Entry entry(*this);
    JSValue event = JS_NewObject(ctx_);
    JS_SetPropertyStr(ctx_, event, "type", JS_NewString(ctx_, "togglechange"));
    JS_SetPropertyStr(ctx_, event, "key",
                      JS_NewStringLen(ctx_, key.c_str(), key.size()));
    qjs::Value result(ctx_, JS_Call(ctx_, dispatch.get(), JS_UNDEFINED, 1,
                                    &event));
    JS_FreeValue(ctx_, event);
    if (result.isException()) {
        MACISHTYPE_ERROR() << "[" << engineId_
                           << "] togglechange dispatch failed: "
                           << qjs::exceptionText(ctx_);
    }
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
    found->second = JS_ToBool(ctx, argv[1]) == 1;
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

JSValue JsEngineHost::nativeGetToggleValue(JSContext *ctx,
                                           JSValueConst thisVal, int argc,
                                           JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
    auto *host = hostOf(ctx);
    if (argc < 1) {
        return JS_NULL;
    }
    std::string key = qjs::toString(ctx, argv[0]);
    auto found = host->toggleDelegates_.find(key);
    if (found == host->toggleDelegates_.end()) {
        return JS_NULL;
    }
    return JS_NewBool(ctx, found->second.get());
}

JSValue JsEngineHost::nativeSetToggleValue(JSContext *ctx,
                                           JSValueConst thisVal, int argc,
                                           JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
    auto *host = hostOf(ctx);
    if (argc < 2) {
        return JS_UNDEFINED;
    }
    std::string key = qjs::toString(ctx, argv[0]);
    auto found = host->toggleDelegates_.find(key);
    if (found == host->toggleDelegates_.end()) {
        MACISHTYPE_WARN() << "toggle: write to unavailable key ignored: "
                          << key;
        return JS_UNDEFINED;
    }
    if (!JS_IsBool(argv[1])) {
        MACISHTYPE_WARN() << "toggle." << key
                          << ": expected boolean, write ignored";
        return JS_UNDEFINED;
    }
    found->second.set(JS_ToBool(ctx, argv[1]) == 1);
    return JS_UNDEFINED;
}

JSValue JsEngineHost::nativeToggleKeys(JSContext *ctx, JSValueConst thisVal,
                                       int argc, JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
    FCITX_UNUSED(argc);
    FCITX_UNUSED(argv);
    auto *host = hostOf(ctx);
    JSValue array = JS_NewArray(ctx);
    uint32_t index = 0;
    for (const auto &[key, delegate] : host->toggleDelegates_) {
        FCITX_UNUSED(delegate);
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
    auto path = host->safeStoragePath(qjs::toString(ctx, argv[0]));
    if (!path) {
        return JS_NULL;
    }
    auto content = readFile(*path);
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
    auto path = host->safeStoragePath(key);
    if (!path) {
        return JS_UNDEFINED;
    }
    std::error_code errorCode;
    std::filesystem::create_directories(path->parent_path(), errorCode);
    {
        std::ofstream stream(*path, std::ios::binary | std::ios::trunc);
        if (!stream || !(stream << value)) {
            MACISHTYPE_ERROR() << "localStorage: cannot write " << *path;
        }
    }
    host->recordSelfWrite(*path);
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
    auto path = host->safeStoragePath(qjs::toString(ctx, argv[0]));
    if (!path) {
        return JS_UNDEFINED;
    }
    std::error_code errorCode;
    std::filesystem::remove(*path, errorCode);
    host->recordSelfWrite(*path);
    return JS_UNDEFINED;
}

JSValue JsEngineHost::nativeStorageClear(JSContext *ctx, JSValueConst thisVal,
                                         int argc, JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
    FCITX_UNUSED(argc);
    FCITX_UNUSED(argv);
    auto *host = hostOf(ctx);
    if (!host->storageRootUsable()) {
        return JS_UNDEFINED;
    }
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
    if (!host->storageRootUsable()) {
        return array;
    }
    std::error_code errorCode;
    std::filesystem::directory_iterator iterator(host->storageRoot_,
                                                 errorCode);
    if (errorCode) {
        return array;
    }
    // key(index) reports keys sorted alphabetically; the directory iterator
    // order is filesystem-defined, so collect and sort.
    std::vector<std::string> keys;
    for (const auto &fileEntry : iterator) {
        if (!fileEntry.is_regular_file(errorCode)) {
            continue;
        }
        if (auto key = decodeStorageKey(fileEntry.path().filename().string())) {
            keys.push_back(std::move(*key));
        }
    }
    std::sort(keys.begin(), keys.end());
    uint32_t index = 0;
    for (const auto &key : keys) {
        JS_SetPropertyUint32(
            ctx, array, index++,
            JS_NewStringLen(ctx, key.c_str(), key.size()));
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
    // Each region-tagged entry is followed by its base form so first-match
    // lookups get a natural fallback chain (e.g. [zh-TW, zh, en-US, en]).
    std::vector<std::string> expanded;
    auto push = [&](const std::string &tag) {
        if (!tag.empty() && std::find(expanded.begin(), expanded.end(), tag) ==
                                expanded.end()) {
            expanded.push_back(tag);
        }
    };
    for (const auto &language : host->languages_) {
        push(language);
        auto dash = language.find('-');
        if (dash != std::string::npos) {
            push(language.substr(0, dash));
        }
    }
    uint32_t index = 0;
    for (const auto &language : expanded) {
        JS_SetPropertyUint32(ctx, array, index++,
                             JS_NewString(ctx, language.c_str()));
    }
    return array;
}

JSValue JsEngineHost::nativeBeginFetch(JSContext *ctx, JSValueConst thisVal,
                                       int argc, JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
    auto *host = hostOf(ctx);
    if (argc < 3 || !JS_IsFunction(ctx, argv[1]) ||
        !JS_IsFunction(ctx, argv[2])) {
        return JS_ThrowTypeError(ctx,
                                 "beginFetch: expected (path, resolve, "
                                 "reject)");
    }
    auto resolved = host->resolveEnginePath(qjs::toString(ctx, argv[0]));
    if (auto *errorText = std::get_if<std::string>(&resolved)) {
        // Path-level failures reject at fetch() time (the spec's "background
        // stat" semantics); only the disk read is deferred. Call the reject
        // function directly — the JS wrapper is a thin forwarder with no
        // try/catch left around this native.
        std::string message = "fetch: " + *errorText;
        JSValue error = JS_NewError(ctx);
        JS_SetPropertyStr(
            ctx, error, "message",
            JS_NewStringLen(ctx, message.c_str(), message.size()));
        JSValue result = JS_Call(ctx, argv[2], JS_UNDEFINED, 1, &error);
        JS_FreeValue(ctx, error);
        JS_FreeValue(ctx, result);
        return JS_UNDEFINED;
    }
    auto &filePath = std::get<ResolvedPath>(resolved);
    // A fetch alone expresses interest in the file; record it before the
    // read so a later edit reloads even when the read fails.
    host->loadedFilePaths_.insert(filePath.fileSystemPath.string());
    PendingFetch fetch;
    fetch.fileSystemPath = filePath.fileSystemPath;
    fetch.url = filePath.url;
    fetch.resolve = JS_DupValue(ctx, argv[1]);
    fetch.reject = JS_DupValue(ctx, argv[2]);
    host->pendingFetches_.push_back(std::move(fetch));
    // Reads start right away for runtime fetches. During a module load there
    // is no session yet (inactive), so the item stays queued — either for
    // the top-level-await fallback to read inline, or for the first
    // session's incrementActive to dispatch.
    host->dispatchToWorker();
    return JS_UNDEFINED;
}

JSValue JsEngineHost::nativeRegisterMakeResponse(JSContext *ctx,
                                                 JSValueConst thisVal,
                                                 int argc,
                                                 JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
    auto *host = hostOf(ctx);
    if (argc < 1 || !JS_IsFunction(ctx, argv[0])) {
        return JS_ThrowTypeError(ctx,
                                 "registerMakeResponse: expected a function");
    }
    JS_FreeValue(ctx, host->makeResponse_);
    host->makeResponse_ = JS_DupValue(ctx, argv[0]);
    return JS_UNDEFINED;
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

// Strict WHATWG UTF-8 validation. fcitx::utf8::validate stops scanning at an
// embedded NUL and would bless whatever follows it.
bool isStrictUtf8(const uint8_t *data, size_t size) {
    size_t i = 0;
    while (i < size) {
        uint8_t byte = data[i];
        if (byte <= 0x7F) {
            i += 1;
            continue;
        }
        size_t continuations;
        uint8_t lower = 0x80;
        uint8_t upper = 0xBF;
        if (byte >= 0xC2 && byte <= 0xDF) {
            continuations = 1;
        } else if (byte == 0xE0) {
            continuations = 2;
            lower = 0xA0; // reject overlongs
        } else if (byte == 0xED) {
            continuations = 2;
            upper = 0x9F; // reject surrogates
        } else if (byte >= 0xE1 && byte <= 0xEF) {
            continuations = 2;
        } else if (byte == 0xF0) {
            continuations = 3;
            lower = 0x90; // reject overlongs
        } else if (byte == 0xF4) {
            continuations = 3;
            upper = 0x8F; // reject > U+10FFFF
        } else if (byte >= 0xF1 && byte <= 0xF3) {
            continuations = 3;
        } else {
            return false; // C0/C1, F5-FF, or a stray continuation byte
        }
        if (size - i - 1 < continuations) {
            return false;
        }
        if (data[i + 1] < lower || data[i + 1] > upper) {
            return false;
        }
        for (size_t k = 2; k <= continuations; ++k) {
            if (data[i + k] < 0x80 || data[i + k] > 0xBF) {
                return false;
            }
        }
        i += continuations + 1;
    }
    return true;
}

} // namespace

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
    if (!isStrictUtf8(data, size)) {
        return JS_ThrowTypeError(ctx, "invalid UTF-8");
    }
    return JS_NewStringLen(ctx, reinterpret_cast<const char *>(data), size);
}

// TextDecoder fast path: decodes a whole valid buffer natively; anything
// invalid returns null and stays with the runtime.js state machine.
JSValue JsEngineHost::nativeDecodeUtf8(JSContext *ctx, JSValueConst thisVal,
                                       int argc, JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
    FCITX_UNUSED(argc); // declared arity 2; quickjs pads argv with undefined
    int ignoreBOM = JS_ToBool(ctx, argv[1]);
    size_t size = 0;
    const uint8_t *data = JS_GetUint8Array(ctx, &size, argv[0]);
    if (data == nullptr) {
        return JS_EXCEPTION;
    }
    if (!ignoreBOM && size >= 3 && data[0] == 0xEF && data[1] == 0xBB &&
        data[2] == 0xBF) {
        data += 3;
        size -= 3;
    }
    if (!isStrictUtf8(data, size)) {
        MACISHTYPE_DEBUG() << "decodeUTF8: declined, invalid UTF-8";
        return JS_NULL;
    }
    MACISHTYPE_DEBUG() << "decodeUTF8: native fast path, " << size << " bytes";
    return JS_NewStringLen(ctx, reinterpret_cast<const char *>(data), size);
}

// TextEncoder fast path. quickjs keeps unpaired surrogates as WTF-8
// (0xED 0xA0-0xBF ..) where WHATWG wants U+FFFD (0xEF 0xBF 0xBD, same
// length); patch a copy — the returned pointer may alias the live string.
JSValue JsEngineHost::nativeEncodeUtf8(JSContext *ctx, JSValueConst thisVal,
                                       int argc, JSValueConst *argv) {
    FCITX_UNUSED(thisVal);
    FCITX_UNUSED(argc);
    size_t size = 0;
    const char *chars = JS_ToCStringLen(ctx, &size, argv[0]);
    if (chars == nullptr) {
        return JS_EXCEPTION;
    }
    const auto *bytes = reinterpret_cast<const uint8_t *>(chars);
    JSValue result;
    if (memchr(bytes, 0xED, size) == nullptr) {
        result = JS_NewUint8ArrayCopy(ctx, bytes, size);
    } else {
        std::string patched(chars, size);
        for (size_t i = 0; i + 2 < patched.size(); ++i) {
            if (static_cast<uint8_t>(patched[i]) == 0xED &&
                static_cast<uint8_t>(patched[i + 1]) >= 0xA0 &&
                static_cast<uint8_t>(patched[i + 1]) <= 0xBF) {
                patched[i] = '\xEF';
                patched[i + 1] = '\xBF';
                patched[i + 2] = '\xBD';
                i += 2;
            }
        }
        result = JS_NewUint8ArrayCopy(
            ctx, reinterpret_cast<const uint8_t *>(patched.data()),
            patched.size());
    }
    MACISHTYPE_DEBUG() << "encodeUTF8: native fast path, " << size << " bytes";
    JS_FreeCString(ctx, chars);
    return result;
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
    define("__MacishType_getToggleValue", &JsEngineHost::nativeGetToggleValue,
           1);
    define("__MacishType_setToggleValue", &JsEngineHost::nativeSetToggleValue,
           2);
    define("__MacishType_toggleKeys", &JsEngineHost::nativeToggleKeys, 0);
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
    define("__MacishType_decodeUTF8", &JsEngineHost::nativeDecodeUtf8, 2);
    define("__MacishType_encodeUTF8", &JsEngineHost::nativeEncodeUtf8, 1);
    define("__MacishTypeHost_beginFetch", &JsEngineHost::nativeBeginFetch, 3);
    define("__MacishTypeHost_registerMakeResponse",
           &JsEngineHost::nativeRegisterMakeResponse, 1);
    define("__MacishTypeHost_utf8Decode", &JsEngineHost::nativeUtf8Decode, 1);
    define("__MacishTypeHost_intlSegment",
           &JsEngineHost::nativeIntlSegment, 3);
    define("__MacishTypeHost_intlDateTimeResolve",
           &JsEngineHost::nativeIntlDateTimeResolve, 5);
    define("__MacishTypeHost_intlDateTimeFormat",
           &JsEngineHost::nativeIntlDateTimeFormat, 4);
    define("__MacishTypeHost_intlDateTimeFormatToParts",
           &JsEngineHost::nativeIntlDateTimeFormatToParts, 4);
    define("__MacishTypeHost_intlResolveLocale",
           &JsEngineHost::nativeIntlResolveLocale, 1);
    define("__MacishTypeHost_intlNumberFormat",
           &JsEngineHost::nativeIntlNumberFormat, 3);
    define("__MacishTypeHost_intlNumberFormatToParts",
           &JsEngineHost::nativeIntlNumberFormatToParts, 3);
    define("__MacishTypeHost_intlPluralSelect",
           &JsEngineHost::nativeIntlPluralSelect, 4);
    define("__MacishTypeHost_intlPluralCategories",
           &JsEngineHost::nativeIntlPluralCategories, 2);
    define("__MacishTypeHost_intlCollatorCompare",
           &JsEngineHost::nativeIntlCollatorCompare, 4);
    define("__MacishTypeHost_action", &JsEngineHost::nativeAction, 1);
    JS_SetPropertyStr(ctx_, global.get(), "__MacishType_userAgent",
                      JS_NewString(ctx_, userAgent_.c_str()));
}

} // namespace macishtype
