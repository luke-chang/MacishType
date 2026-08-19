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
#include <thread>
#include <variant>
#include <vector>

#include <quickjs.h>

#include "macishtype/hosteventloop.h"
#include "macishtype/intl.h"
#include "macishtype/manifest.h"

namespace macishtype {

// One fully loaded JS engine: its own QuickJS runtime/context, the shared
// runtime.js globals, and the evaluated entry module. Created lazily on the
// first activate of the corresponding input method.
class JsEngineHost {
public:
    // Backs one `manifest.toggle` key with host-side state (e.g. the shared
    // Chinese conversion toggle). The key set is host availability, not a
    // manifest declaration: a key exists exactly while a delegate is
    // installed.
    struct ToggleDelegate {
        std::function<bool()> get;
        std::function<void(bool)> set;
    };

    // `settingsValuesJson` is the sanitized settings object the engine
    // observes as manifest.settings; it must be final before load because
    // engines read it while their entry module evaluates. The same holds
    // for `toggleDelegates` (macOS exposes toggle availability from the
    // first evaluated statement).
    static std::unique_ptr<JsEngineHost>
    load(const std::string &engineId, const std::filesystem::path &engineRoot,
         const std::filesystem::path &storageRoot,
         const std::string &settingsValuesJson, const ManifestData &manifest,
         const std::vector<std::string> &languages,
         std::map<std::string, ToggleDelegate> toggleDelegates,
         HostEventLoop *eventLoop);

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
    bool instanceHasHook(uint64_t instanceId, const char *method);

    // Reverse lookup (capabilities.reverseLookup): calls the engine class's
    // static reverseLookup / prepareReverseLookup / endReverseLookup.
    struct ReverseCode {
        std::string code;
        std::string annotation;
    };
    // Calls static prepareReverseLookup(); returns a token for this lookup.
    // onReady(true) fires once when ready (synchronously if prepare is absent
    // or settles synchronously), onReady(false) on prepare failure. A newer
    // prepareReverseLookup or a cancelReverseLookupWait(token) invalidates a
    // still-pending callback (it never fires). Absent static => ready.
    uint64_t prepareReverseLookup(std::function<void(bool ready)> onReady);
    // Display dismissed: invalidate a still-pending prepare callback for
    // `token` (no-op if it isn't the current one). Does NOT call the static
    // endReverseLookup or release the engine's reverse index.
    void cancelReverseLookupWait(uint64_t token);
    // Calls static reverseLookup(character); marshals the returned
    // (string | {code, annotation})[] into ReverseCode. Empty on absence/throw.
    std::vector<ReverseCode> reverseLookup(const std::string &character);

    JSContext *context() const { return ctx_; }
    const std::string &engineId() const { return engineId_; }

    // Active-session refcount, driven by EngineSession's ctor/dtor. While
    // active (> 0) queued fetches are read on a worker thread right away and
    // settled on the main loop as soon as the bytes arrive, matching the
    // macOS host's timing. While inactive (module load, or the engine was
    // switched away from) items stay queued and completed reads are staged,
    // settling on the next activation without re-reading.
    void incrementActive();
    void decrementActive();

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
    // `candidateWindow.layoutDirection`. The platform host resolves its
    // orientation setting (fcitx5: per-input-method, optionally following
    // the fcitx global) to a concrete direction and pushes it here;
    // manifest/updateCandidates values still override per candidate window.
    void setLayoutVertical(bool vertical) { layoutVertical_ = vertical; }
    bool layoutVertical() const { return layoutVertical_; }
    // Follow-up phrases for held text, keyed on its last character, from
    // the locale dictionary (lazily loaded); empty when no entry.
    std::vector<std::string> associatedFollowups(const std::string &heldChar);

    using FieldValue = std::variant<bool, double, std::string>;
    // Bridge-visible candidate window field: engine write overlay first,
    // then the manifest declaration.
    std::optional<FieldValue>
    candidateWindowField(const std::string &field) const;

    // Fires the `togglechange` global event for a host-side flip of `key`.
    // JS self-writes must not come through here (no self-echo).
    void dispatchToggleChange(const std::string &key);

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
                 std::vector<std::string> languages,
                 std::map<std::string, ToggleDelegate> toggleDelegates,
                 HostEventLoop *eventLoop);

    // One queued fetch(): path resolved (and reload tracking recorded) at
    // fetch() time, disk read deferred to the worker, promise settled on the
    // main loop. `bytes` is the worker's result inside a completed batch
    // (nullopt there = read failed); in pendingFetches_ a nullopt means
    // not-read-yet while a present value is a staged result awaiting an
    // active session. resolve/reject hold dup'd refs freed exactly once when
    // the fetch settles (or wholesale by JS_FreeRuntime at teardown).
    struct PendingFetch {
        std::filesystem::path fileSystemPath;
        std::string url;
        JSValue resolve = JS_UNDEFINED;
        JSValue reject = JS_UNDEFINED;
        std::optional<std::string> bytes;
    };

    // Async-fetch pipeline (all on the main loop except the worker body).
    void dispatchToWorker();
    void completeWorkerBatch(std::vector<PendingFetch> batch);
    void settleFetches(std::vector<PendingFetch> batch);
    void scheduleDeferredSettle();
    // Synchronous fallback for entry modules that top-level-await a fetch:
    // reads and settles every queued fetch inline so the module promise can
    // fulfill during load, matching the old synchronous behavior.
    void flushPendingFetchesSync();

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
    void loadModuleTable(JSValue table, const std::string &fileBase,
                         bool numericValues);
    void ensureAssociatedDictionary();
    void registerBridgeGlobals();
    void drainJobs();
    void reportRejections();

    // Reverse-lookup async plumbing. settleReverseLookup fires the pending
    // onReady when `token` is still current; releaseReverseLookup calls the
    // static endReverseLookup on idle. reverseLookupReaction is the JS
    // resolve/reject reaction (magic encodes ready=1/fail=0; func_data[0] is
    // the token).
    void settleReverseLookup(uint64_t token, bool ready);
    void releaseReverseLookup();
    static JSValue reverseLookupReaction(JSContext *ctx, JSValueConst thisVal,
                                         int argc, JSValueConst *argv,
                                         int magic, JSValueConst *funcData);

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

    // Storage containment: localStorage files are regular files the host
    // writes directly inside storageRoot_. A symlink there (the root itself or
    // a key file) can only have been planted in the engine bundle, so refuse
    // to traverse one — extending the engine:/// path containment to storage.
    bool storageRootUsable() const;
    std::optional<std::filesystem::path>
    safeStoragePath(const std::string &key) const;

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
    static JSValue nativeGetToggleValue(JSContext *ctx, JSValueConst thisVal,
                                        int argc, JSValueConst *argv);
    static JSValue nativeSetToggleValue(JSContext *ctx, JSValueConst thisVal,
                                        int argc, JSValueConst *argv);
    static JSValue nativeToggleKeys(JSContext *ctx, JSValueConst thisVal,
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
    static JSValue nativeBeginFetch(JSContext *ctx, JSValueConst thisVal,
                                    int argc, JSValueConst *argv);
    static JSValue nativeRegisterMakeResponse(JSContext *ctx,
                                              JSValueConst thisVal, int argc,
                                              JSValueConst *argv);
    static JSValue nativeUtf8Decode(JSContext *ctx, JSValueConst thisVal,
                                    int argc, JSValueConst *argv);
    // Optional TextDecoder/TextEncoder fast paths consumed by runtime.js.
    // Decode is strict: invalid UTF-8 returns null so the runtime's state
    // machine keeps the WHATWG replacement/fatal semantics.
    static JSValue nativeDecodeUtf8(JSContext *ctx, JSValueConst thisVal,
                                    int argc, JSValueConst *argv);
    static JSValue nativeEncodeUtf8(JSContext *ctx, JSValueConst thisVal,
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
    // Intl.PluralRules. Selects the plural category for a formatted number
    // (respecting the shim's digit skeleton) and lists a locale's categories.
    static JSValue nativeIntlPluralSelect(JSContext *ctx, JSValueConst thisVal,
                                          int argc, JSValueConst *argv);
    static JSValue nativeIntlPluralCategories(JSContext *ctx,
                                              JSValueConst thisVal, int argc,
                                              JSValueConst *argv);
    // Intl.Collator. Compares two strings under a collator whose options are
    // encoded in a signature string (which also keys the collator cache).
    static JSValue nativeIntlCollatorCompare(JSContext *ctx,
                                             JSValueConst thisVal, int argc,
                                             JSValueConst *argv);
    static JSValue nativeAction(JSContext *ctx, JSValueConst thisVal,
                                int argc, JSValueConst *argv);

    static int interruptHandler(JSRuntime *runtime, void *opaque);
    static void rejectionTracker(JSContext *ctx, JSValueConst promise,
                                 JSValueConst reason, bool isHandled,
                                 void *opaque);
    // Marks the window where module resolution is legitimate. quickjs's
    // loader hooks carry no origin flag, but a module's static imports
    // resolve inside JS_Eval while dynamic import() resolves from a job, so
    // scoping that one call tells the two apart. Counted rather than a flag
    // so a nested scope cannot close an enclosing one.
    class StaticImportScope {
    public:
        explicit StaticImportScope(JsEngineHost &host) : host_(host) {
            ++host_.staticImportDepth_;
        }
        ~StaticImportScope() { --host_.staticImportDepth_; }
        StaticImportScope(const StaticImportScope &) = delete;
        StaticImportScope &operator=(const StaticImportScope &) = delete;

    private:
        JsEngineHost &host_;
    };

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
    std::map<std::string, ToggleDelegate> toggleDelegates_;

    std::map<uint64_t, JSValue> instances_;
    uint64_t nextInstanceId_ = 1;

    int callDepth_ = 0;
    int staticImportDepth_ = 0;
    std::chrono::steady_clock::time_point deadline_{};
    std::map<void *, std::string> pendingRejections_;
    ActionHandler actionHandler_;

    // ICU-backed Intl handle cache; created lazily on the first Intl native
    // call, closed with this host. ICU types stay confined to intl.cpp.
    std::unique_ptr<IntlCache> intlCache_;

    // Async-fetch pipeline state (owned by the main loop; the worker only
    // touches the batch moved into it).
    HostEventLoop *eventLoop_ = nullptr;
    std::vector<PendingFetch> pendingFetches_;
    HostEventLoop::Handle deferredSettle_;
    std::thread fetchWorker_;
    bool workerBusy_ = false;
    int activeCount_ = 0;
    // Liveness token for worker completion closures scheduled onto the main
    // loop: the closure holds a weak_ptr and becomes a pure drop (zero JS_*
    // calls) when the host died first.
    std::shared_ptr<char> aliveToken_ = std::make_shared<char>('\0');
    JSValue makeResponse_ = JS_UNDEFINED;

    // Reverse-lookup state (host-scoped; the reverse index lives on the engine
    // class, shared across sessions). token monotonic; onReady is the pending
    // callback; prepared tracks whether the static index was built; the timer
    // debounces the idle release of the index.
    uint64_t reverseLookupToken_ = 0;
    std::function<void(bool)> reverseLookupOnReady_;
    bool reverseLookupPrepared_ = false;
    HostEventLoop::Handle reverseLookupReleaseTimer_;
};

// Whether an associated-mode dictionary is bundled for `intendedLanguage`.
// Standalone (no host instance) so the addon can gate the settings toggle
// before any engine is loaded, mirroring macOS `isAvailable(for:)`.
bool associatedDictionaryAvailable(const std::string &intendedLanguage);

} // namespace macishtype
