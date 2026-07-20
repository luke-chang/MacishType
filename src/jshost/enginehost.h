#pragma once

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <variant>
#include <vector>

#include <quickjs.h>

#include "intl.h"
#include "manifest.h"

namespace macishtype {

// One fully loaded JS engine: its own QuickJS runtime/context, the shared
// runtime.js globals, and the evaluated entry module. Created lazily on the
// first activate of the corresponding input method.
class JsEngineHost {
public:
    // `settingsValuesJson` is the sanitized settings object the engine
    // observes as manifest.settings; it must be final before load because
    // engines read it while their entry module evaluates.
    static std::unique_ptr<JsEngineHost>
    load(const std::string &engineId, const std::filesystem::path &engineRoot,
         const std::filesystem::path &storageRoot,
         const std::string &settingsValuesJson, const ManifestData &manifest,
         const std::vector<std::string> &languages);

    ~JsEngineHost();
    JsEngineHost(const JsEngineHost &) = delete;
    JsEngineHost &operator=(const JsEngineHost &) = delete;

    // One JS engine-class instance per text-field session.
    // Returns 0 when construction fails.
    uint64_t createInstance();
    void destroyInstance(uint64_t instanceId);

    // Calls a duck-typed hook when the instance defines it. `argument` is
    // consumed. Returns the hook's boolean result; nullopt when the hook is
    // absent or threw.
    std::optional<bool> invokeHook(uint64_t instanceId, const char *method,
                                   JSValue argument);
    std::optional<bool> invokeHook(uint64_t instanceId, const char *method);
    bool instanceHasHook(uint64_t instanceId, const char *method);

    JSContext *context() const { return ctx_; }
    const std::string &engineId() const { return engineId_; }

    // Canonical paths of files the engine expressed interest in: manifest,
    // entry, every imported module, every fetched resource. Consumed by
    // the reload policy to scope hot reloads to relevant edits, mirroring
    // the macOS host's loadedFilePaths.
    const std::set<std::string> &loadedFilePaths() const {
        return loadedFilePaths_;
    }

    // Engine-private persistence directory (one file per localStorage
    // key); resolved by discovery, see EngineInfo::storageRoot.
    const std::filesystem::path &storageRoot() const { return storageRoot_; }

    // Storage watcher lifecycle: the runtime reports whether any `storage`
    // listeners exist, and the observer arms or disarms the watch. Set
    // after load; replays the current state immediately, because engines
    // typically register listeners while their entry module evaluates.
    void setStorageListeningObserver(std::function<void(bool)> observer);

    // Files changed inside storageRoot(): skip our own writes' echoes,
    // decode the remaining filenames, and raise the contract's storage
    // event for each affected key. Mirrors the macOS host's
    // handleStorageEvent.
    void handleStorageChanges(const std::set<std::string> &changedPaths);

    // Replaces manifest.settings at runtime; the runtime dispatches the
    // contract's settingschange event. Deduplicated against the last
    // pushed values, mirroring the macOS host's lastPushedSettings gate.
    void updateSettings(const std::string &valuesJson);

    // Associated-mode host dictionary. `associatedModeEnabled_` mirrors the
    // engine's enableAssociatedMode setting (set by the addon); it gates the
    // dictionary fallback, matching the macOS host.
    void setAssociatedModeEnabled(bool enabled) {
        associatedModeEnabled_ = enabled;
    }
    bool associatedModeEnabled() const { return associatedModeEnabled_; }

    // Base candidate orientation used when the manifest does not fix
    // `candidateWindow.layoutDirection`. The addon resolves the per-input-
    // method orientation setting (including "follow the fcitx global") to a
    // concrete direction and pushes it here; manifest/updateCandidates values
    // still override per candidate window.
    void setLayoutVertical(bool vertical) { layoutVertical_ = vertical; }
    bool layoutVertical() const { return layoutVertical_; }
    // Follow-up phrases for a held character from the locale dictionary
    // (lazily loaded); empty when no entry.
    std::vector<std::string> associatedFollowups(const std::string &heldChar);

    using FieldValue = std::variant<bool, double, std::string>;
    // Bridge-visible candidate window field: engine write overlay first,
    // then the manifest declaration.
    std::optional<FieldValue>
    candidateWindowField(const std::string &field) const;

    // Backs a manifest-declared system menu key with host-side state (e.g.
    // the shared Chinese conversion toggle) instead of the plain in-memory
    // value.
    struct MenuDelegate {
        std::function<bool()> get;
        std::function<void(bool)> set;
    };
    void setMenuDelegate(const std::string &key, MenuDelegate delegate);

    // Receiver for the event-object mutator dispatcher
    // (__MacishTypeHost_action). Scoped to the active session invocation.
    using ActionHandler = std::function<void(
        const std::string &name, int argc, JSValueConst *argv)>;
    class ScopedActionHandler {
    public:
        ScopedActionHandler(JsEngineHost &host, ActionHandler handler)
            : host_(host), previous_(std::move(host.actionHandler_)) {
            host_.actionHandler_ = std::move(handler);
        }
        ~ScopedActionHandler() {
            host_.actionHandler_ = std::move(previous_);
        }
        ScopedActionHandler(const ScopedActionHandler &) = delete;
        ScopedActionHandler &operator=(const ScopedActionHandler &) = delete;

    private:
        JsEngineHost &host_;
        ActionHandler previous_;
    };

    // RAII guard for host→JS entries: arms the execution watchdog on the
    // outermost entry and drains microtasks when it unwinds.
    class Entry {
    public:
        explicit Entry(JsEngineHost &host);
        ~Entry();
        Entry(const Entry &) = delete;
        Entry &operator=(const Entry &) = delete;

    private:
        JsEngineHost &host_;
    };

private:
    JsEngineHost(std::string engineId, std::filesystem::path engineRoot,
                 std::filesystem::path storageRoot,
                 std::string settingsValuesJson, ManifestData manifest,
                 std::vector<std::string> languages);

    // Snapshot of a storage file's on-disk identity, recorded after the
    // host's own writes so their inotify echoes can be told apart from
    // external modifications.
    struct StorageFileState {
        bool exists = false;
        int64_t mtimeNanoseconds = 0;
        uint64_t size = 0;
        bool operator==(const StorageFileState &other) const {
            return exists == other.exists &&
                   mtimeNanoseconds == other.mtimeNanoseconds &&
                   size == other.size;
        }
    };
    static StorageFileState statStorageFile(const std::filesystem::path &path);
    void recordSelfWrite(const std::filesystem::path &path);
    void dispatchStorageEvent(const std::string &key);

    bool initialize();
    bool evaluateScript(const std::filesystem::path &path,
                        const char *scriptName);
    bool evaluateEntryModule();
    bool pushSettings(const std::string &valuesJson);
    bool injectModules();
    void loadModuleTable(JSValue table, const std::string &moduleName,
                         bool numericValues);
    void ensureAssociatedDictionary();
    void registerBridgeGlobals();
    void drainJobs();
    void reportRejections();

    // engine:///-style path resolution with realpath containment. Returns
    // the on-disk path and normalized "engine:///…" URL, or an error
    // message suitable for a thrown Error.
    struct ResolvedPath {
        std::filesystem::path fileSystemPath;
        std::string url;
    };
    std::variant<ResolvedPath, std::string>
    resolveEnginePath(const std::string &input) const;

    // Bridge state ------------------------------------------------------

    void setCandidateWindowField(const std::string &field, JSValueConst value);

    std::filesystem::path storagePathForKey(const std::string &key) const;

    // Native callbacks (dispatch through JS_GetContextOpaque) ------------

    static JSValue nativeLog(JSContext *ctx, JSValueConst thisVal, int argc,
                             JSValueConst *argv);
    static JSValue nativeManifestName(JSContext *ctx, JSValueConst thisVal,
                                      int argc, JSValueConst *argv);
    static JSValue nativeGetCandidateWindowField(JSContext *ctx,
                                                 JSValueConst thisVal,
                                                 int argc, JSValueConst *argv);
    static JSValue nativeSetCandidateWindowField(JSContext *ctx,
                                                 JSValueConst thisVal,
                                                 int argc, JSValueConst *argv);
    static JSValue nativeCandidateWindowFields(JSContext *ctx,
                                               JSValueConst thisVal, int argc,
                                               JSValueConst *argv);
    static JSValue nativeGetMenuValue(JSContext *ctx, JSValueConst thisVal,
                                      int argc, JSValueConst *argv);
    static JSValue nativeSetMenuValue(JSContext *ctx, JSValueConst thisVal,
                                      int argc, JSValueConst *argv);
    static JSValue nativeMenuKeys(JSContext *ctx, JSValueConst thisVal,
                                  int argc, JSValueConst *argv);
    static JSValue nativeStorageGetItem(JSContext *ctx, JSValueConst thisVal,
                                        int argc, JSValueConst *argv);
    static JSValue nativeStorageSetItem(JSContext *ctx, JSValueConst thisVal,
                                        int argc, JSValueConst *argv);
    static JSValue nativeStorageRemoveItem(JSContext *ctx,
                                           JSValueConst thisVal, int argc,
                                           JSValueConst *argv);
    static JSValue nativeStorageClear(JSContext *ctx, JSValueConst thisVal,
                                      int argc, JSValueConst *argv);
    static JSValue nativeStorageKeys(JSContext *ctx, JSValueConst thisVal,
                                     int argc, JSValueConst *argv);
    static JSValue nativeSetStorageListening(JSContext *ctx,
                                             JSValueConst thisVal, int argc,
                                             JSValueConst *argv);
    static JSValue nativeGetLanguages(JSContext *ctx, JSValueConst thisVal,
                                      int argc, JSValueConst *argv);
    static JSValue nativeReadEngineFile(JSContext *ctx, JSValueConst thisVal,
                                        int argc, JSValueConst *argv);
    static JSValue nativeUtf8Decode(JSContext *ctx, JSValueConst thisVal,
                                    int argc, JSValueConst *argv);
    // Segments a string via ICU (UAX #29) at grapheme/word/sentence
    // granularity, returning boundary offsets in UTF-16 code units (the
    // ECMA-402 index unit). Backs the hostglue Intl.Segmenter, which
    // JavaScriptCore provides natively on macOS but quickjs-ng lacks.
    static JSValue nativeIntlSegment(JSContext *ctx, JSValueConst thisVal,
                                     int argc, JSValueConst *argv);
    // Intl.DateTimeFormat, split into resolve (locale/calendar/timezone/
    // pattern negotiation) and per-value format/formatToParts. The shim
    // normalizes ECMA-402 options into a CLDR skeleton; ICU builds the pattern
    // and formats. quickjs-ng has no Intl; JavaScriptCore provides it on macOS.
    static JSValue nativeIntlDateTimeResolve(JSContext *ctx,
                                             JSValueConst thisVal, int argc,
                                             JSValueConst *argv);
    static JSValue nativeIntlDateTimeFormat(JSContext *ctx, JSValueConst thisVal,
                                            int argc, JSValueConst *argv);
    static JSValue nativeIntlDateTimeFormatToParts(JSContext *ctx,
                                                   JSValueConst thisVal,
                                                   int argc, JSValueConst *argv);
    // Locale negotiation shared by the number-oriented Intl objects: returns
    // the canonical BCP-47 locale and its numbering system for
    // resolvedOptions().
    static JSValue nativeIntlResolveLocale(JSContext *ctx, JSValueConst thisVal,
                                           int argc, JSValueConst *argv);
    // Intl.NumberFormat. The shim compiles ECMA-402 options into an ICU number
    // skeleton; ICU formats. Numbers cross as decimal strings to keep BigInt
    // and large-integer precision. quickjs-ng has no Intl; JavaScriptCore
    // provides it on macOS.
    static JSValue nativeIntlNumberFormat(JSContext *ctx, JSValueConst thisVal,
                                          int argc, JSValueConst *argv);
    static JSValue nativeIntlNumberFormatToParts(JSContext *ctx,
                                                 JSValueConst thisVal, int argc,
                                                 JSValueConst *argv);
    static JSValue nativeAction(JSContext *ctx, JSValueConst thisVal,
                                int argc, JSValueConst *argv);

    static int interruptHandler(JSRuntime *runtime, void *opaque);
    static void rejectionTracker(JSContext *ctx, JSValueConst promise,
                                 JSValueConst reason, bool isHandled,
                                 void *opaque);
    static char *moduleNormalize(JSContext *ctx, const char *baseName,
                                 const char *moduleName, void *opaque);
    static JSModuleDef *moduleLoad(JSContext *ctx, const char *moduleName,
                                   void *opaque);

    static JsEngineHost *hostOf(JSContext *ctx);

    // Lazily creates and returns this host's ICU handle cache.
    IntlCache &intlCache();

    // Members -----------------------------------------------------------

    std::string engineId_;
    std::filesystem::path engineRoot_;
    std::filesystem::path canonicalRoot_;
    std::filesystem::path storageRoot_;
    // Last values pushed as manifest.settings (the updateSettings dedup
    // gate).
    std::string settingsValuesJson_;
    std::set<std::string> loadedFilePaths_;
    std::map<std::string, StorageFileState> recentSelfWrites_;
    bool storageListening_ = false;
    std::function<void(bool)> storageListeningObserver_;
    // Leading character (UTF-8) → follow-up phrases; loaded on first query.
    std::map<std::string, std::vector<std::string>> associatedDictionary_;
    bool associatedDictionaryLoaded_ = false;
    bool associatedModeEnabled_ = false;
    bool layoutVertical_ = false;
    ManifestData manifest_;
    std::vector<std::string> languages_;
    std::string userAgent_;

    JSRuntime *runtime_ = nullptr;
    JSContext *ctx_ = nullptr;
    JSValue engineClass_ = JS_UNDEFINED;

    std::map<std::string, FieldValue> manifestCandidateWindow_;
    std::map<std::string, FieldValue> engineCandidateWindow_;
    std::map<std::string, bool> menuValues_;
    std::map<std::string, MenuDelegate> menuDelegates_;

    std::map<uint64_t, JSValue> instances_;
    uint64_t nextInstanceId_ = 1;

    int callDepth_ = 0;
    std::chrono::steady_clock::time_point deadline_{};
    std::map<void *, std::string> pendingRejections_;
    ActionHandler actionHandler_;

    // ICU-backed Intl handle cache; created lazily on the first Intl native
    // call, closed with this host. ICU types stay confined to intl.cpp.
    std::unique_ptr<IntlCache> intlCache_;
};

// Whether an associated-mode dictionary is bundled for `intendedLanguage`.
// Standalone (no host instance) so the addon can gate the settings toggle
// before any engine is loaded, mirroring macOS `isAvailable(for:)`.
bool associatedDictionaryAvailable(const std::string &intendedLanguage);

} // namespace macishtype
