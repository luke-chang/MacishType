#pragma once

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <variant>
#include <vector>

#include <quickjs.h>

#include "manifest.h"

namespace macishtype {

// One fully loaded JS engine: its own QuickJS runtime/context, the shared
// runtime.js globals, and the evaluated entry module. Created lazily on the
// first activate of the corresponding input method.
class JsEngineHost {
public:
    static std::unique_ptr<JsEngineHost>
    load(const std::string &engineId, const std::filesystem::path &engineRoot,
         const ManifestData &manifest,
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

    using FieldValue = std::variant<bool, double, std::string>;
    // Bridge-visible candidate window field: engine write overlay first,
    // then the manifest declaration.
    std::optional<FieldValue>
    candidateWindowField(const std::string &field) const;

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
                 ManifestData manifest, std::vector<std::string> languages);

    bool initialize();
    bool evaluateScript(const std::filesystem::path &path,
                        const char *scriptName);
    bool evaluateEntryModule();
    bool pushSettings();
    bool injectModules();
    void loadFrequencyTable(JSValue table);
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

    // Members -----------------------------------------------------------

    std::string engineId_;
    std::filesystem::path engineRoot_;
    std::filesystem::path canonicalRoot_;
    ManifestData manifest_;
    std::vector<std::string> languages_;
    std::string userAgent_;

    JSRuntime *runtime_ = nullptr;
    JSContext *ctx_ = nullptr;
    JSValue engineClass_ = JS_UNDEFINED;

    std::map<std::string, FieldValue> manifestCandidateWindow_;
    std::map<std::string, FieldValue> engineCandidateWindow_;
    std::map<std::string, bool> menuValues_;

    std::map<uint64_t, JSValue> instances_;
    uint64_t nextInstanceId_ = 1;

    int callDepth_ = 0;
    std::chrono::steady_clock::time_point deadline_{};
    std::map<void *, std::string> pendingRejections_;
    ActionHandler actionHandler_;
};

} // namespace macishtype
