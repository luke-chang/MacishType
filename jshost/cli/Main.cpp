// Headless jshost CLI: drives the core engine host without any platform
// input framework. Contract tests run against it on every platform; it is
// also the reference embedding of the host seams.
//
//   macishtype-jshost-cli [options] <engine-dir>
//     --runtime DIR     directory holding a shared runtime script; repeat
//                       once per source directory (required)
//     --tables DIR      per-language data table directory
//     --languages LIST  comma-separated BCP-47 preferences (default en-US)
//     --settings JSON   manifest.settings values pushed at load (default {})
//     --menu-store FILE menu-value persistence, one key=true|false per line
//                       (test-only format; rewritten on every change)
//     --activate        createInstance + incrementActive after load
//     --load-only       exit after load settles (0 = loaded, 1 = failed)
//
// Without --load-only, commands are read from stdin as JSON lines:
//   {"do":"key","key":"h","code":"KeyH","shift":false,"ctrl":false,
//    "alt":false,"meta":false}
//   {"do":"activate"} {"do":"deactivate"}
//   {"do":"menu"} {"do":"menu-flip","key":"..."}
//   {"do":"wait-quiescent"}
//   {"do":"quit"}
// Every output line on stdout is one JSON event:
//   {"event":"log","level":"info","text":"..."}
//   {"event":"loaded"} / {"event":"load-failed"}
//   {"event":"action","name":"commit","args":["哈囉"]}
//   {"event":"key-result","handled":true}
//   {"event":"menu","items":[...]} / {"event":"menu-flip","changed":true}
//   {"event":"quiescent"}

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <source_location>
#include <sstream>
#include <string>
#include <vector>

#include <quickjs.h>

#include "MacishType/EngineHost.h"
#include "MacishType/EventData.h"
#include "MacishType/HostEventLoop.h"
#include "MacishType/HostSeams.h"
#include "MacishType/Intl.h"
#include "MacishType/JsonUtil.h"
#include "MacishType/Logger.h"
#include "MacishType/Manifest.h"
#include "MacishType/QjsUtil.h"

namespace {

using namespace MacishType;

// Output ------------------------------------------------------------------

// Single writer (the loop thread), flushed per line so a test harness can
// stream-read events.
void emitLine(const std::string &line) {
    std::cout << line << "\n" << std::flush;
}

// Seam implementations ------------------------------------------------------

class CliLogger : public Logger {
public:
    void write(Level level, std::string_view message,
               const std::source_location &where) override {
        const char *name = "info";
        switch (level) {
        case Level::Debug:
            name = "debug";
            break;
        case Level::Info:
            name = "info";
            break;
        case Level::Notice:
            name = "notice";
            break;
        case Level::Error:
            name = "error";
            break;
        case Level::Fault:
            name = "fault";
            break;
        }
        emitLine(std::string("{\"event\":\"log\",\"level\":\"") + name +
                 "\",\"where\":\"" + jsonEscape(where.file_name()) + ":" +
                 std::to_string(where.line()) + "\",\"text\":\"" +
                 jsonEscape(message) + "\"}");
    }
};

class CliResourceLocator : public ResourceLocator {
public:
    // A search path, not one directory: the shared runtime scripts live
    // beside the libraries that own them, so they come from two places in
    // a source tree and from one after install.
    std::vector<std::filesystem::path> runtimeDirs;
    std::filesystem::path tablesDir;

    std::filesystem::path
    locateRuntimeScript(std::string_view fileName) override {
        for (const auto &dir : runtimeDirs) {
            auto found = existingOrEmpty(dir / fileName);
            if (!found.empty()) {
                return found;
            }
        }
        return {};
    }

    std::filesystem::path locateDataTable(std::string_view fileBase,
                                          std::string_view language) override {
        if (tablesDir.empty()) {
            return {};
        }
        return existingOrEmpty(tablesDir / (std::string(fileBase) + "." +
                                            std::string(language) + ".txt"));
    }

private:
    static std::filesystem::path
    existingOrEmpty(const std::filesystem::path &path) {
        std::error_code errorCode;
        return std::filesystem::is_regular_file(path, errorCode)
                   ? path
                   : std::filesystem::path{};
    }
};

class CliPlatformInfo : public PlatformInfo {
public:
    std::vector<std::string> languages{"en-US"};

    std::string userAgentPrefix() override {
#if defined(_WIN32)
        const char *platform = "Windows";
#elif defined(__APPLE__)
        const char *platform = "macOS";
#else
        const char *platform = "Linux";
#endif
        // The CLI is the contract-test host, not a release: no version.
        return std::string("MacishType/dev (") + platform +
               ") jshost-cli/dev";
    }

    std::vector<std::string> preferredLanguages() override {
        return languages;
    }
};

// Event loop ----------------------------------------------------------------

// Single-threaded task loop. Tasks only ever run inside drain(), so
// postDeferred's "never synchronous" contract holds by construction; post()
// is callable from any thread (the fetch worker).
class CliEventLoop : public HostEventLoop {
public:
    Handle postDelayed(std::chrono::microseconds delay,
                       std::function<void()> callback) override {
        return enqueue(std::chrono::steady_clock::now() + delay,
                       std::move(callback), true);
    }

    Handle postDeferred(std::function<void()> callback) override {
        return enqueue(std::chrono::steady_clock::now(), std::move(callback),
                       true);
    }

    void post(std::function<void()> callback) override {
        enqueue(std::chrono::steady_clock::now(), std::move(callback), false);
        cv_.notify_all();
    }

    // Runs due tasks until none arrive for `grace` (undue timers — the
    // reverse-lookup idle release — do not count as pending work).
    //
    // `busy` reports work the loop cannot see; see JsEngineHost::hasPendingWork.
    void drainUntilQuiescent(
        const std::function<bool()> &busy,
        std::chrono::milliseconds grace = std::chrono::milliseconds(60)) {
        int quietRounds = 0;
        while (quietRounds < 3 || busy()) {
            if (runDueTasks()) {
                quietRounds = 0;
                continue;
            }
            std::unique_lock<std::mutex> lock(mutex_);
            cv_.wait_for(lock, grace);
            lock.unlock();
            if (!runDueTasks()) {
                ++quietRounds;
            } else {
                quietRounds = 0;
            }
        }
    }

private:
    struct Task {
        std::chrono::steady_clock::time_point due;
        uint64_t sequence = 0;
        std::function<void()> callback;
        // Null for post() (not cancelable).
        std::shared_ptr<std::atomic<bool>> alive;
    };

    class TaskHandle : public Cancelable {
    public:
        explicit TaskHandle(std::shared_ptr<std::atomic<bool>> alive)
            : alive_(std::move(alive)) {}
        ~TaskHandle() override { alive_->store(false); }

    private:
        std::shared_ptr<std::atomic<bool>> alive_;
    };

    Handle enqueue(std::chrono::steady_clock::time_point due,
                   std::function<void()> callback, bool cancelable) {
        Task task;
        task.due = due;
        task.callback = std::move(callback);
        std::shared_ptr<std::atomic<bool>> alive;
        if (cancelable) {
            alive = std::make_shared<std::atomic<bool>>(true);
            task.alive = alive;
        }
        {
            std::lock_guard<std::mutex> lock(mutex_);
            task.sequence = nextSequence_++;
            tasks_.push_back(std::move(task));
        }
        return cancelable ? std::make_unique<TaskHandle>(std::move(alive))
                          : Handle{};
    }

    // Runs every task due by now, in (due, enqueue) order. True if any ran.
    bool runDueTasks() {
        bool ranAny = false;
        for (;;) {
            std::optional<Task> next;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                auto now = std::chrono::steady_clock::now();
                auto found = tasks_.end();
                for (auto it = tasks_.begin(); it != tasks_.end(); ++it) {
                    if (it->due > now) {
                        continue;
                    }
                    if (found == tasks_.end() ||
                        it->due < found->due ||
                        (it->due == found->due &&
                         it->sequence < found->sequence)) {
                        found = it;
                    }
                }
                if (found == tasks_.end()) {
                    break;
                }
                next = std::move(*found);
                tasks_.erase(found);
            }
            if (next->alive == nullptr || next->alive->load()) {
                next->callback();
                ranAny = true;
            }
        }
        return ranAny;
    }

    std::mutex mutex_;
    std::condition_variable cv_;
    std::vector<Task> tasks_;
    uint64_t nextSequence_ = 0;
};

// Session-less key driving --------------------------------------------------

// The CLI has no candidate-list state machine (that is the platform
// session's job); it keeps just enough staging for engines to observe a
// coherent event shape, mirroring the reference engines' Node test stubs.
struct CliStaging {
    std::string markedText;
    std::string message;
    bool candidatesVisible = false;
};

std::string serializeJsValue(JSContext *ctx, JSValueConst value) {
    std::string json = Qjs::jsonStringify(ctx, value);
    return json.empty() ? "null" : json;
}

bool dispatchKey(JsEngineHost &host, uint64_t instanceId, CliStaging &staging,
                 JSValueConst keyFields) {
    JSContext *ctx = host.context();
    // The stdin vocabulary: short modifier names, keyIgnoringModifiers
    // defaulting to key; repeat/numLock/location keep the struct defaults.
    auto stringProp = [&](const char *name, const std::string &fallback = {}) {
        Qjs::Value value(ctx, JS_GetPropertyStr(ctx, keyFields, name));
        return value.isUndefined() ? fallback
                                   : Qjs::toString(ctx, value.get());
    };
    auto boolProp = [&](const char *name) {
        Qjs::Value value(ctx, JS_GetPropertyStr(ctx, keyFields, name));
        return JS_ToBool(ctx, value.get()) == 1;
    };
    EventKeyFields keys;
    keys.key = stringProp("key");
    keys.code = stringProp("code");
    keys.keyIgnoringModifiers = stringProp("keyIgnoringModifiers", keys.key);
    keys.shiftKey = boolProp("shift");
    keys.ctrlKey = boolProp("ctrl");
    keys.altKey = boolProp("alt");
    keys.metaKey = boolProp("meta");
    keys.capsLock = boolProp("capsLock");

    static const std::string c_NoStagedText;
    EventStaging eventStaging{staging.markedText, c_NoStagedText,
                              staging.message, false,
                              staging.candidatesVisible, 0};

    Qjs::Value data(ctx,
                    buildEventData(ctx, eventStaging, &keys, nullptr, -1,
                                   resolvedCandidateWindowConfig(host)));
    Qjs::Value global(ctx, JS_GetGlobalObject(ctx));
    Qjs::Value maker(ctx,
                     JS_GetPropertyStr(ctx, global.get(), c_MakeEventHook));
    JSValue event;
    if (maker.isFunction()) {
        JSValue argument = data.get();
        event = JS_Call(ctx, maker.get(), JS_UNDEFINED, 1, &argument);
        if (JS_IsException(event)) {
            emitLine("{\"event\":\"error\",\"text\":\"makeEvent failed: " +
                     jsonEscape(Qjs::exceptionText(ctx)) + "\"}");
            return false;
        }
    } else {
        event = data.release();
    }

    // Dump every mutator call as an event, and track the minimal staging the
    // next event's shape depends on.
    JsEngineHost::ScopedActionHandler scoped(
        host, [&](const std::string &name, int argc, JSValueConst *argv) {
            std::string args;
            for (int i = 0; i < argc; i++) {
                if (i != 0) {
                    args += ",";
                }
                args += serializeJsValue(ctx, argv[i]);
            }
            emitLine("{\"event\":\"action\",\"name\":\"" + jsonEscape(name) +
                     "\",\"args\":[" + args + "]}");
            if (name == "updateMarkedText" && argc >= 1) {
                staging.markedText = JS_IsString(argv[0])
                                         ? Qjs::toString(ctx, argv[0])
                                         : std::string();
            } else if (name == "updateCandidates" && argc >= 1) {
                JSValue length = JS_GetPropertyStr(ctx, argv[0], "length");
                uint32_t count = 0;
                JS_ToUint32(ctx, &count, length);
                JS_FreeValue(ctx, length);
                staging.candidatesVisible = JS_IsArray(argv[0]) && count > 0;
                staging.message.clear();
            } else if (name == "updateMessage" && argc >= 1) {
                staging.message = JS_IsString(argv[0])
                                      ? Qjs::toString(ctx, argv[0])
                                      : std::string();
                if (!staging.message.empty()) {
                    staging.candidatesVisible = false;
                }
            } else if (name == "commit" || name == "resetContext") {
                staging.markedText.clear();
                staging.message.clear();
                staging.candidatesVisible = false;
            }
        });

    auto handled = host.invokeHook(instanceId, "handleKey", event);
    emitLine(std::string("{\"event\":\"key-result\",\"handled\":") +
             (handled.value_or(false) ? "true" : "false") + "}");
    return true;
}

struct CliOptions {
    std::filesystem::path engineDir;
    std::vector<std::filesystem::path> runtimeDirs;
    std::filesystem::path tablesDir;
    std::vector<std::string> languages{"en-US"};
    std::string settingsJson = "{}";
    std::filesystem::path menuStorePath;
    bool activate = false;
    bool loadOnly = false;
};

// Menu-value persistence for contract tests: one `key=true|false` line per
// declared toggle, whole file rewritten on every change.
std::map<std::string, bool> readMenuStore(const std::filesystem::path &path) {
    std::map<std::string, bool> values;
    std::ifstream stream(path);
    std::string line;
    while (std::getline(stream, line)) {
        auto separator = line.find('=');
        if (separator == std::string::npos) {
            continue;
        }
        values[line.substr(0, separator)] =
            line.substr(separator + 1) == "true";
    }
    return values;
}

void writeMenuStore(const std::filesystem::path &path,
                    const std::vector<std::pair<std::string, bool>> &values) {
    std::ofstream stream(path, std::ios::trunc);
    for (const auto &[key, value] : values) {
        stream << key << "=" << (value ? "true" : "false") << "\n";
    }
}

std::optional<CliOptions> parseArguments(int argc, char **argv) {
    CliOptions options;
    for (int i = 1; i < argc; i++) {
        std::string argument = argv[i];
        auto value = [&]() -> const char * {
            if (i + 1 >= argc) {
                std::cerr << argument << " needs a value\n";
                return nullptr;
            }
            return argv[++i];
        };
        if (argument == "--runtime") {
            const char *dir = value();
            if (dir == nullptr) {
                return std::nullopt;
            }
            options.runtimeDirs.emplace_back(dir);
        } else if (argument == "--tables") {
            const char *dir = value();
            if (dir == nullptr) {
                return std::nullopt;
            }
            options.tablesDir = dir;
        } else if (argument == "--languages") {
            const char *list = value();
            if (list == nullptr) {
                return std::nullopt;
            }
            options.languages.clear();
            std::stringstream stream(list);
            std::string item;
            while (std::getline(stream, item, ',')) {
                if (!item.empty()) {
                    options.languages.push_back(item);
                }
            }
        } else if (argument == "--settings") {
            const char *json = value();
            if (json == nullptr) {
                return std::nullopt;
            }
            options.settingsJson = json;
        } else if (argument == "--menu-store") {
            const char *path = value();
            if (path == nullptr) {
                return std::nullopt;
            }
            options.menuStorePath = path;
        } else if (argument == "--activate") {
            options.activate = true;
        } else if (argument == "--load-only") {
            options.loadOnly = true;
        } else if (!argument.empty() && argument[0] == '-') {
            std::cerr << "unknown option: " << argument << "\n";
            return std::nullopt;
        } else if (options.engineDir.empty()) {
            options.engineDir = argument;
        } else {
            std::cerr << "unexpected argument: " << argument << "\n";
            return std::nullopt;
        }
    }
    if (options.engineDir.empty() || options.runtimeDirs.empty()) {
        std::cerr << "usage: macishtype-jshost-cli --runtime DIR [--runtime DIR]"
                     " [--tables DIR]"
                     " [--languages LIST] [--settings JSON]"
                     " [--menu-store FILE] [--activate]"
                     " [--load-only] <engine-dir>\n";
        return std::nullopt;
    }
    return options;
}

} // namespace

int main(int argc, char **argv) {
    auto options = parseArguments(argc, argv);
    if (!options) {
        return 2;
    }

    static CliLogger logger;
    static CliResourceLocator resources;
    static CliPlatformInfo platform;
    resources.runtimeDirs = options->runtimeDirs;
    resources.tablesDir = options->tablesDir;
    platform.languages = options->languages;
    setLogger(&logger);
    HostServices services;
    services.resources = &resources;
    services.platform = &platform;
    setHostServices(services);

    CliEventLoop loop;

    std::string engineId = options->engineDir.filename().string();
    auto manifest = parseManifest(options->engineDir / "manifest.json",
                                  options->languages);
    if (!manifest) {
        emitLine("{\"event\":\"load-failed\",\"error\":\"manifest\"}");
        return 1;
    }
    JsEngineHost::MenuStore menuStore;
    if (!options->menuStorePath.empty()) {
        menuStore.initial = readMenuStore(options->menuStorePath);
        menuStore.onChange =
            [path = options->menuStorePath](
                const std::vector<std::pair<std::string, bool>> &values) {
                writeMenuStore(path, values);
            };
    }
    IntlCache intlCache;
    auto host = JsEngineHost::load({
        .engineId = engineId,
        .engineRoot = options->engineDir,
        .storageRoot = options->engineDir / "_storage",
        .settingsValuesJson = options->settingsJson,
        .manifest = *manifest,
        .languages = options->languages,
        .toggleDelegates = {},
        .menuStore = std::move(menuStore),
        .eventLoop = &loop,
        .intl = intlCache,
    });
    if (!host) {
        emitLine("{\"event\":\"load-failed\",\"error\":\"load\"}");
        return 1;
    }
    emitLine("{\"event\":\"loaded\",\"engine\":\"" + jsonEscape(engineId) +
             "\"}");

    auto drainLoop = [&]() {
        loop.drainUntilQuiescent([&]() { return host->hasPendingWork(); });
    };

    uint64_t instanceId = 0;
    CliStaging staging;
    auto activate = [&]() {
        if (instanceId != 0) {
            return;
        }
        instanceId = host->createInstance();
        if (instanceId != 0) {
            host->incrementActive();
        }
    };
    auto deactivate = [&]() {
        if (instanceId == 0) {
            return;
        }
        host->decrementActive();
        host->destroyInstance(instanceId);
        instanceId = 0;
    };

    if (options->activate) {
        activate();
    }
    drainLoop();
    emitLine("{\"event\":\"quiescent\"}");

    if (!options->loadOnly) {
        JSContext *ctx = host->context();
        std::string line;
        while (std::getline(std::cin, line)) {
            if (line.empty()) {
                continue;
            }
            Qjs::Value command(
                ctx, JS_ParseJSON(ctx, line.c_str(), line.size(), "<stdin>"));
            if (command.isException() || !JS_IsObject(command.get())) {
                emitLine("{\"event\":\"error\",\"text\":\"bad command\"}");
                continue;
            }
            Qjs::Value verb(ctx,
                            JS_GetPropertyStr(ctx, command.get(), "do"));
            std::string action =
                JS_IsString(verb.get()) ? Qjs::toString(ctx, verb.get()) : "";
            if (action == "quit") {
                break;
            }
            if (action == "activate") {
                activate();
            } else if (action == "deactivate") {
                deactivate();
            } else if (action == "key") {
                if (instanceId == 0) {
                    activate();
                }
                dispatchKey(*host, instanceId, staging, command.get());
            } else if (action == "menu") {
                std::string json = "{\"event\":\"menu\",\"items\":[";
                bool first = true;
                for (const auto &item : host->resolvedMenu()) {
                    if (!first) {
                        json += ",";
                    }
                    first = false;
                    if (item.divider) {
                        json += "{\"divider\":true}";
                    } else {
                        json += "{\"key\":\"" + jsonEscape(item.key) +
                                "\",\"label\":\"" + jsonEscape(item.label) +
                                "\",\"value\":" +
                                (item.value ? "true" : "false") +
                                ",\"disabled\":" +
                                (item.disabled ? "true" : "false") + "}";
                    }
                }
                json += "]}";
                emitLine(json);
                continue;
            } else if (action == "menu-flip") {
                Qjs::Value key(ctx,
                               JS_GetPropertyStr(ctx, command.get(), "key"));
                std::string keyText = JS_IsString(key.get())
                                          ? Qjs::toString(ctx, key.get())
                                          : "";
                bool changed = host->flipMenuValue(keyText);
                emitLine(std::string("{\"event\":\"menu-flip\",\"changed\":") +
                         (changed ? "true" : "false") + "}");
            } else if (action == "wait-quiescent") {
                drainLoop();
                emitLine("{\"event\":\"quiescent\"}");
                continue;
            } else {
                emitLine("{\"event\":\"error\",\"text\":\"unknown command: " +
                         jsonEscape(action) + "\"}");
                continue;
            }
            drainLoop();
        }
    }

    deactivate();
    host.reset();
    return 0;
}
